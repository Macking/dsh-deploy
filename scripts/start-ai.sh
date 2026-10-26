#!/usr/bin/env bash
#
# start-ai.sh — 启动 DSH Agent 服务（根目录 docker-compose.yml）并获取 WebUI URL。
#
# 作用：
#   构建并启动根目录下的 docker compose 编排，拉起两个容器：
#     - dsh-harness : DeepSeek Harness agent（监听 127.0.0.1:3080）
#     - dsh-nginx   : Nginx 反向代理（80 → 3080，对外暴露 WebUI）
#   启动后调用 scripts/get-url.sh --wait，从 dsh-harness 容器日志中
#   提取带 token 的 WebUI 启动 URL。
#
# 前置条件：
#   1. 已 git clone 项目到 $HOME/dsh-deploy（或自定义路径）。
#   2. 已执行 bash scripts/prepare.sh（写入 .env，含 DSH_PUBLIC_URL 等）。
#   3. （推荐）已执行 bash scripts/start-vllm.sh 启动模型服务，
#      DSH Agent 通过 http://127.0.0.1:8000 连接 vllm。
#      若模型服务未启动，Agent 仍可启动，但模型调用会失败（可在 UI 中配置）。
#
# 用法（在服务器上执行）：
#   bash scripts/start-ai.sh
#

# ---- 解析本脚本真实路径（兼容符号链接，与 prepare.sh 同样的方式）----
__start_self="${BASH_SOURCE[0]:-$0}"
__start_real="$(readlink -f "$__start_self" 2>/dev/null || echo "$__start_self")"
__start_scripts_dir="$(cd "$(dirname "$__start_real")" && pwd)"

# ---- source prepare.sh：导出 DSH_DEPLOY_HOME 并同步 .env ----
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

COMPOSE_FILE="$DSH_DEPLOY_HOME/docker-compose.yml"
GET_URL="$__start_scripts_dir/get-url.sh"

# ---- 校验文件 ----
if [[ ! -f "$COMPOSE_FILE" ]]; then
  printf '%bERROR: 未找到 docker compose 文件：%s%b\n' "$RED" "$COMPOSE_FILE" "$NC" >&2
  exit 1
fi
if [[ ! -f "$GET_URL" ]]; then
  printf '%bERROR: 未找到 get-url.sh（期望路径：%s）%b\n' "$RED" "$GET_URL" "$NC" >&2
  exit 1
fi

echo ""
printf "%b============================================%b\n" "$BOLD" "$NC"
printf "%b  启动 DSH Agent 服务%b\n" "$BOLD" "$NC"
printf "%b============================================%b\n" "$BOLD" "$NC"
printf "  Compose  : %s\n" "$COMPOSE_FILE"
printf "  部署根   : %s\n" "$DSH_DEPLOY_HOME"
printf "%b============================================%b\n" "$BOLD" "$NC"
echo ""

# ---- 构建并启动 ----
printf "%b[start-ai] 执行：docker compose -f %s up -d --build%b\n" "$BOLD" "$COMPOSE_FILE" "$NC"
docker compose -f "$COMPOSE_FILE" up -d --build

# ---- 显示状态 ----
echo ""
printf "%b[start-ai] 容器状态：%b\n" "$BOLD" "$NC"
docker compose -f "$COMPOSE_FILE" ps

# ---- 等待并获取 WebUI URL（带 token）----
# 强制 REMOTE_HOST 为空 → get-url.sh 走本地模式（本脚本在服务器上执行，
# docker 与容器均在本地，无需 SSH）。
echo ""
printf "%b[start-ai] 等待 DSH WebUI 就绪并获取启动 URL ...%b\n" "$BOLD" "$NC"
if ! REMOTE_HOST= bash "$GET_URL" --wait; then
  printf '%b[start-ai] 未能自动获取 WebUI URL。%b\n' "$YELLOW" "$NC" >&2
  printf '  请稍后手动执行：bash %s --wait\n' "$GET_URL" >&2
  printf '  或查看容器日志：docker logs dsh-harness\n' >&2
  exit 1
fi
