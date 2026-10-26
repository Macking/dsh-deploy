#!/usr/bin/env bash
#
# start-vllm.sh — 启动 Qwen vLLM 模型服务（qwen/docker-compose.yml）。
#
# 作用：
#   构建并启动 qwen 目录下的 docker compose 编排，拉起 spark-vllm-b12x
#   模型服务容器（vllm-serve）。模型路径与服务名由 qwen/.env 提供
#   （由 prepare.sh 写入），无需手动编辑 compose 文件。
#
# 前置条件：
#   1. 已 git clone 项目到 $HOME/dsh-deploy（或自定义路径）。
#   2. 已执行 bash scripts/prepare.sh -m <模型ID> -n <服务名> 下载模型
#      并写入 .env。本脚本会 source prepare.sh 以同步 .env 并获取
#      DSH_DEPLOY_HOME / MODEL_ID / SERVED_MODEL_NAME，但不会重复下载。
#
# 用法（在服务器上执行）：
#   bash scripts/start-vllm.sh
#
# 启动后：
#   跟随日志：  docker compose -f qwen/docker-compose.yml logs -f
#   查看状态：  docker compose -f qwen/docker-compose.yml ps
#   健康检查：  curl -f http://127.0.0.1:8000/health
#   停止服务：  docker compose -f qwen/docker-compose.yml down
#

# ---- 解析本脚本真实路径（兼容符号链接，与 prepare.sh 同样的方式）----
__start_self="${BASH_SOURCE[0]:-$0}"
__start_real="$(readlink -f "$__start_self" 2>/dev/null || echo "$__start_self")"
__start_scripts_dir="$(cd "$(dirname "$__start_real")" && pwd)"

# ---- source prepare.sh：导出 DSH_DEPLOY_HOME / MODEL_ID / SERVED_MODEL_NAME 并同步 .env ----
# prepare.sh 设计为可 source（不启用 set -e/-u），故本脚本延后启用严格模式。
__start_prepare="$__start_scripts_dir/prepare.sh"
if [[ ! -f "$__start_prepare" ]]; then
  printf 'ERROR: 未找到 prepare.sh（期望路径：%s/prepare.sh）\n' "$__start_scripts_dir" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$__start_prepare"

# ---- 启用严格模式（prepare.sh 已执行完毕，其内部不依赖这些标志）----
set -euo pipefail

# 颜色
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BOLD='\033[1m' NC='\033[0m'

COMPOSE_FILE="$DSH_DEPLOY_HOME/qwen/docker-compose.yml"
MODEL_DIR="$DSH_DEPLOY_HOME/models/$MODEL_ID"

# ---- 校验 compose 文件 ----
if [[ ! -f "$COMPOSE_FILE" ]]; then
  printf '%bERROR: 未找到 docker compose 文件：%s%b\n' "$RED" "$COMPOSE_FILE" "$NC" >&2
  exit 1
fi

# ---- 校验模型已下载（避免容器启动后因找不到模型而失败）----
if [[ ! -d "$MODEL_DIR" ]] || [[ -z "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]]; then
  printf '%bERROR: 模型目录为空或不存在：%s%b\n' "$RED" "$MODEL_DIR" "$NC" >&2
  printf '      请先下载模型：bash %s/prepare.sh -m %s -n %s\n' \
    "$__start_scripts_dir" "$MODEL_ID" "$SERVED_MODEL_NAME" >&2
  exit 1
fi

echo ""
printf "%b============================================%b\n" "$BOLD" "$NC"
printf "%b  启动 VLLM 模型服务%b\n" "$BOLD" "$NC"
printf "%b============================================%b\n" "$BOLD" "$NC"
printf "  Compose  : %s\n" "$COMPOSE_FILE"
printf "  模型 ID  : %s\n" "$MODEL_ID"
printf "  服务名   : %s\n" "$SERVED_MODEL_NAME"
printf "  模型路径 : %s\n" "$MODEL_DIR"
printf "%b============================================%b\n" "$BOLD" "$NC"
echo ""

# ---- 构建并启动 ----
printf "%b[start-vllm] 执行：docker compose -f %s up -d --build%b\n" "$BOLD" "$COMPOSE_FILE" "$NC"
docker compose -f "$COMPOSE_FILE" up -d --build

# ---- 显示状态 ----
echo ""
printf "%b[start-vllm] 容器状态：%b\n" "$BOLD" "$NC"
docker compose -f "$COMPOSE_FILE" ps

echo ""
printf "%b============================================%b\n" "$GREEN" "$NC"
printf "%b  VLLM 模型服务已启动%b\n" "$GREEN" "$NC"
printf "%b============================================%b\n" "$GREEN" "$NC"
printf "  服务名   : %s\n" "$SERVED_MODEL_NAME"
printf "  API 端点 : http://127.0.0.1:8000\n"
printf "  健康检查 : curl -f http://127.0.0.1:8000/health\n"
echo ""
printf "  FP4 模型加载约需 20 分钟，请耐心等待健康检查通过。\n"
printf "  跟随日志：docker compose -f %s logs -f\n" "$COMPOSE_FILE"
printf "  停止服务：docker compose -f %s down\n" "$COMPOSE_FILE"
printf "%b============================================%b\n" "$GREEN" "$NC"
echo ""
