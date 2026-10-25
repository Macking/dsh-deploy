#!/usr/bin/env bash
#
# prepare.sh — 新机器部署前的环境准备脚本。
#
# 作用：
#   1. 确定项目根目录并导出 DSH_DEPLOY_HOME 环境变量，供后续部署脚本
#      （deploy.sh 等）与命令依赖使用。
#   2. 被【直接执行】时（如 `bash scripts/prepare.sh`），额外调用 scripts/hfd.sh
#      下载模型到 $DSH_DEPLOY_HOME/models/<模型ID> 下；被【source】时只导出变量，不阻塞当前 shell。
#
# 用法：
#   # 仅获取环境变量（即时，不下载）——后续 shell 依赖此变量时使用：
#   source scripts/prepare.sh
#
#   # 下载模型（可断点续传、幂等；已下载完整则秒退）：
#   bash scripts/prepare.sh                                 # 默认模型 nvidia/Qwen3.8-27B-NVFP4
#   bash scripts/prepare.sh --model nvidia/Qwen3.8-27B-NVFP4
#   bash scripts/prepare.sh -m Qwen/Qwen3-32B
#   # 下载工具可用环境变量覆盖（默认 wget；gated 仓库需 HF_TOKEN + HF_USERNAME）：
#   DOWNLOAD_TOOL=wget HF_TOKEN=xxx HF_USERNAME=yyy \
#   bash scripts/prepare.sh -m nvidia/Qwen3.8-27B-NVFP4
#
# 参数：
#   --model <ID>, -m <ID>   HuggingFace 模型 ID（如 nvidia/Qwen3.8-27B-NVFP4）。
#                           该值同时作为 hfd.sh 的仓库 ID（第一个位置参数），
#                           并拼接到本地下载目录 $DSH_DEPLOY_HOME/models/<ID>。
#                           默认 nvidia/Qwen3.8-27B-NVFP4。
#
# 环境变量（可选覆盖）：
#   DOWNLOAD_TOOL   下载工具，wget 或 aria2c（hfd.sh 默认 aria2c，本脚本默认 wget）。
#   HF_TOKEN        HuggingFace 访问令牌（gated 仓库需要）。
#   HF_USERNAME     HuggingFace 用户名（gated 仓库需要）。
#
# 新机器完整流程：
#   git clone https://github.com/Macking/dsh-deploy.git "$HOME/dsh-deploy"
#   cd "$HOME/dsh-deploy"
#   bash   scripts/prepare.sh -m nvidia/Qwen3.8-27B-NVFP4   # 下载模型（重活，可重跑续传）
#   source scripts/prepare.sh                               # 导出 DSH_DEPLOY_HOME 供后续脚本使用（即时）
#
# DSH_DEPLOY_HOME 判定逻辑：
#   1. 解析本脚本自身的真实路径（跟随符号链接）。
#   2. 若该路径为 $HOME/dsh-deploy/scripts/prepare.sh，
#      则 DSH_DEPLOY_HOME=$HOME/dsh-deploy（取标准字面值）。
#   3. 否则取本脚本所在目录的上一级目录作为 DSH_DEPLOY_HOME。
#   4. 无论 DSH_DEPLOY_HOME 是否已存在，都按上述规则覆盖赋值并 export。
#
# 注意：本脚本设计为可被 source，故不启用 `set -e`/`set -u`——
#       否则 errexit/nounset 会泄漏到父 shell，影响后续命令执行。
#       参数解析只在【直接执行】分支内进行，且置于函数内，
#       shift 仅影响函数局部位置参数，不会泄漏到 source 时的父 shell；
#       解析失败时 exit 也只作用于直接执行的子进程，不会杀掉 source 的父 shell。

# ---- 解析本脚本真实路径（兼容 source 与直接执行；跟随符号链接）----
# 被 source 时 $0 指向父 shell，而 ${BASH_SOURCE[0]} 仍指向本脚本，更可靠。
__prepare_self="${BASH_SOURCE[0]:-$0}"
if command -v readlink >/dev/null 2>&1; then
  __prepare_real="$(readlink -f "$__prepare_self" 2>/dev/null || echo "$__prepare_self")"
else
  __prepare_real="$__prepare_self"
fi

# ---- 本脚本所在目录及其上一级（scripts/ 的父目录即项目根）----
__prepare_scripts_dir="$(cd "$(dirname "$__prepare_real")" && pwd)"
__prepare_parent_dir="$(dirname "$__prepare_scripts_dir")"

# ---- 期望路径（用于判定；两侧均规范化以容忍 $HOME 本身是符号链接）----
# 赋值用字面值，判定用规范化值。
__prepare_expected_root_raw="$HOME/dsh-deploy"
__prepare_expected_path_canon="$(readlink -f "$__prepare_expected_root_raw/scripts/prepare.sh" 2>/dev/null || echo "$__prepare_expected_root_raw/scripts/prepare.sh")"

# ---- 计算并覆盖 DSH_DEPLOY_HOME（直接赋值即无条件覆盖既有值）----
if [[ "$__prepare_real" == "$__prepare_expected_path_canon" ]]; then
  # 路径符合预期：使用标准的 $HOME/dsh-deploy
  DSH_DEPLOY_HOME="$__prepare_expected_root_raw"
else
  # 路径不符合预期：以本脚本所在目录的上一级作为项目根
  DSH_DEPLOY_HOME="$__prepare_parent_dir"
fi
export DSH_DEPLOY_HOME

# ---- 清理路径判定用的内部临时变量，避免污染调用方环境 ----
unset __prepare_self __prepare_real __prepare_scripts_dir \
      __prepare_parent_dir __prepare_expected_root_raw __prepare_expected_path_canon

# ---- 模型下载（仅在被直接执行时运行；source 模式只导出环境变量）----
# hfd.sh 可断点续传、幂等：已下载完整则秒退，中断后重跑即续传。
# 模型 ID 由 --model/-m 提供（默认 nvidia/Qwen3.8-27B-NVFP4），同时作为
# hfd.sh 的仓库 ID 与本地子目录 $DSH_DEPLOY_HOME/models/<ID>。
# DOWNLOAD_TOOL/HF_TOKEN/HF_USERNAME 为可选环境变量覆盖；全部局部于函数内。
run_model_download() {
  local RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BOLD='\033[1m' NC='\033[0m'
  local repo="$__prepare_model"
  local dir="$DSH_DEPLOY_HOME/models/$repo"
  local tool="${DOWNLOAD_TOOL:-wget}"
  local hfd="$DSH_DEPLOY_HOME/scripts/hfd.sh"

  # 模型 ID 同时用作本地子目录名，拒绝绝对路径与路径越界（防止 .. 跳出 models/）
  if [[ "$repo" == /* || "$repo" == *..* ]]; then
    printf "%b[prepare.sh] 非法的模型 ID：%s（不允许绝对路径或包含 ..）%b\n" \
      "$RED" "$repo" "$NC" >&2
    return 1
  fi

  if [[ ! -f "$hfd" ]]; then
    printf "%b[prepare.sh] 未找到下载脚本：%s%b\n" "$RED" "$hfd" "$NC" >&2
    return 1
  fi

  printf "%b[prepare.sh] 开始下载模型 %s -> %s（工具 %s）%b\n" \
    "$BOLD" "$repo" "$dir" "$tool" "$NC"

  # 透传 HF 凭证（仅在已设置时附加；gated 仓库需要）
  local -a args=("$repo" --local-dir "$dir" --tool "$tool")
  [[ -n "${HF_TOKEN:-}" ]] && args+=(--hf_token "$HF_TOKEN")
  [[ -n "${HF_USERNAME:-}" ]] && args+=(--hf_username "$HF_USERNAME")

  # 以子进程方式调用，hfd.sh 内部的 exit/trap 不会影响本脚本（及 source 时的父 shell）
  bash "$hfd" "${args[@]}"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    printf "%b[prepare.sh] 模型下载完成：%s%b\n" "$GREEN" "$dir" "$NC"
  else
    printf "%b[prepare.sh] 模型下载未完成（退出码 %s）。可重新执行本脚本续传，或直接：%b\n" "$YELLOW" "$rc" "$NC" >&2
    printf "%b            bash %s %s%b\n" "$YELLOW" "$hfd" "${args[*]}" "$NC" >&2
  fi
  return $rc
}

# ---- 按调用方式分流 ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # ===== 直接执行模式：解析参数 + 下载模型 =====
  # __prepare_model 仅在此子进程内存在，退出后不残留到调用方 shell。
  __prepare_model="nvidia/Qwen3.8-27B-NVFP4"

  # 参数解析置于函数内，shift 仅影响函数局部位置参数，不会泄漏到父 shell。
  __prepare_parse_args() {
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model|-m)
          if [[ -z "${2:-}" ]]; then
            printf "[prepare.sh] 错误：%s 需要一个参数值\n" "$1" >&2
            return 1
          fi
          __prepare_model="$2"; shift 2 ;;
        --model=*) __prepare_model="${1#--model=}"; shift ;;
        -m=*)      __prepare_model="${1#-m=}"; shift ;;
        --) shift; break ;;
        *) printf "[prepare.sh] 忽略未知参数：%s\n" "$1" >&2; shift ;;
      esac
    done
  }
  __prepare_parse_args "$@" || { unset -f __prepare_parse_args __prepare_model 2>/dev/null; exit 1; }
  unset -f __prepare_parse_args

  run_model_download
  __prepare_dl_rc=$?
  unset __prepare_model
  cat >&2 <<EOF
[prepare.sh] 提示：本脚本是直接执行的，DSH_DEPLOY_HOME 仅存在于本子进程，退出后当前 shell 不会保留。
            下载已完成（或已尝试）。要让当前 shell 获得 DSH_DEPLOY_HOME，请执行：
            source scripts/prepare.sh
EOF
  exit "$__prepare_dl_rc"
else
  # ===== source 模式：仅导出环境变量，不触发下载（避免阻塞当前 shell）=====
  # 此处不解析 --model：source 模式不下载，参数无意义；
  # 亦避免解析失败时 exit 杀掉父 shell。
  printf '[prepare.sh] DSH_DEPLOY_HOME=%s\n' "$DSH_DEPLOY_HOME"
  printf '[prepare.sh] (source 模式：仅导出变量。如需下载模型，请执行：bash %s/scripts/prepare.sh -m <模型ID>)\n' \
    "$DSH_DEPLOY_HOME"
fi
