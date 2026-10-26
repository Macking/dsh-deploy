#!/usr/bin/env bash
#
# DSH 全栈部署脚本（bash 版）— 一键部署 vLLM + DeepSeek Harness 到全新远程服务器。
#
# 上传项目文件后，依次在远程执行三个脚本：
#   1. scripts/prepare.sh    — 写入 .env + 下载模型权重（hfd.sh，可断点续传）
#   2. scripts/start-vllm.sh — 构建并启动 vLLM 模型服务（qwen/docker-compose.yml）
#   3. scripts/start-ai.sh   — 构建并启动 DSH Agent + Nginx，输出带 token 的 WebUI URL
#
# 全新机器只需安装 Docker + Docker Compose；脚本自动处理其余一切。
#
# 用法：
#   ./scripts/deploy.sh
#   REMOTE_HOST=192.168.76.248 REMOTE_USER=test REMOTE_PASS=123456 ./scripts/deploy.sh
#   REMOTE_HOST=10.0.0.50 PUBLIC_HOST=dsh.example.com ./scripts/deploy.sh
#   MODEL_ID=Qwen/Qwen3-32B SERVED_NAME=my-qwen ./scripts/deploy.sh
#   DEEPSEEK_API_KEY=sk-xxx ./scripts/deploy.sh
#
# 依赖：sshpass（apt install sshpass / brew install sshpass）
#
set -euo pipefail

# ---- 参数（可通过环境变量覆盖）----
REMOTE_HOST="${REMOTE_HOST:-192.168.76.248}"
REMOTE_USER="${REMOTE_USER:-test}"
REMOTE_PASS="${REMOTE_PASS:-123456}"
REMOTE_PATH="${REMOTE_PATH:-/home/${REMOTE_USER}/dsh-deploy}"
PUBLIC_HOST="${PUBLIC_HOST:-$REMOTE_HOST}"
MODEL_ID="${MODEL_ID:-nvidia/Qwen3.8-Flash-Next-FP4-Local}"
SERVED_NAME="${SERVED_NAME:-qwen3.8-flash}"
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=120"
SSHPASS_CMD="sshpass -p ${REMOTE_PASS}"

# 颜色
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BOLD='\033[1m' CYAN='\033[0;36m' NC='\033[0m'

# ---- 预检：sshpass ----
if ! command -v sshpass >/dev/null 2>&1; then
  printf '%bERROR: sshpass 未安装。请执行：apt install sshpass / brew install sshpass%b\n' "$RED" "$NC" >&2
  exit 1
fi

# ---- 预检：本地文件 ----
for f in docker-compose.yml .env.example \
         dsh/Dockerfile dsh/entrypoint.sh \
         nginx/nginx.conf nginx/conf.d/default.conf \
         qwen/docker-compose.yml qwen/Dockerfile qwen/entrypoint.sh \
         scripts/prepare.sh scripts/hfd.sh scripts/start-vllm.sh scripts/start-ai.sh scripts/get-url.sh; do
  if [[ ! -f "$PROJECT_ROOT/$f" ]]; then
    printf '%bERROR: 缺少本地文件：%s/%s%b\n' "$RED" "$PROJECT_ROOT" "$f" "$NC" >&2
    exit 1
  fi
done

echo ""
printf "%b============================================%b\n" "$CYAN" "$NC"
printf "%b  DSH 全栈部署 — vLLM + DeepSeek Harness%b\n" "$CYAN" "$NC"
printf "%b============================================%b\n" "$CYAN" "$NC"
printf "  Remote : %s@%s\n" "$REMOTE_USER" "$REMOTE_HOST"
printf "  Public : %s\n" "$PUBLIC_HOST"
printf "  Path   : %s\n" "$REMOTE_PATH"
printf "  Model  : %s\n" "$MODEL_ID"
printf "  Served : %s\n" "$SERVED_NAME"
printf "  Source : %s\n" "$PROJECT_ROOT"
printf "%b============================================%b\n" "$CYAN" "$NC"
echo ""

# ---- 预检：远程连通性 + Docker ----
printf "%b预检：连接远程服务器 + 检查 Docker ...%b\n" "$YELLOW" "$NC"
$SSHPASS_CMD ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "echo '      connected.' && docker --version && docker compose version" || {
  printf '%bERROR: 无法连接远程服务器，或远程未安装 Docker/Docker Compose。%b\n' "$RED" "$NC" >&2
  printf '      安装 Docker：curl -fsSL https://get.docker.com | sh\n' >&2
  exit 1
}
echo ""

# ---- [1/5] 上传项目文件 ----
printf "%b[1/5] 上传项目文件到 %s:%s ...%b\n" "$YELLOW" "$REMOTE_HOST" "$REMOTE_PATH" "$NC"

# 创建远程目录结构
$SSHPASS_CMD ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "mkdir -p '$REMOTE_PATH/dsh' '$REMOTE_PATH/nginx/conf.d' '$REMOTE_PATH/qwen' '$REMOTE_PATH/scripts' '$REMOTE_PATH/models'"

# 按目标目录分组上传（scp 单次连接可传多个文件到同一目录）
$SSHPASS_CMD scp $SSH_OPTS \
    "$PROJECT_ROOT/docker-compose.yml" \
    "$PROJECT_ROOT/.env.example" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/"

$SSHPASS_CMD scp $SSH_OPTS \
    "$PROJECT_ROOT/dsh/Dockerfile" \
    "$PROJECT_ROOT/dsh/entrypoint.sh" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/dsh/"

$SSHPASS_CMD scp $SSH_OPTS \
    "$PROJECT_ROOT/nginx/nginx.conf" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/nginx/"

$SSHPASS_CMD scp $SSH_OPTS \
    "$PROJECT_ROOT/nginx/conf.d/default.conf" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/nginx/conf.d/"

$SSHPASS_CMD scp $SSH_OPTS \
    "$PROJECT_ROOT/qwen/docker-compose.yml" \
    "$PROJECT_ROOT/qwen/Dockerfile" \
    "$PROJECT_ROOT/qwen/entrypoint.sh" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/qwen/"

$SSHPASS_CMD scp $SSH_OPTS \
    "$PROJECT_ROOT/scripts/prepare.sh" \
    "$PROJECT_ROOT/scripts/hfd.sh" \
    "$PROJECT_ROOT/scripts/start-vllm.sh" \
    "$PROJECT_ROOT/scripts/start-ai.sh" \
    "$PROJECT_ROOT/scripts/get-url.sh" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/scripts/"

printf "      上传完成（14 个文件）。\n\n"

# ---- [2/5] 修复行尾 + 准备 .env ----
printf "%b[2/5] 修复行尾 + 准备 .env ...%b\n" "$YELLOW" "$NC"

# 通过环境变量传递参数到远程 bash；heredoc 用引号定界符防止本地展开。
$SSHPASS_CMD ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "REMOTE_PATH='$REMOTE_PATH' PUBLIC_HOST='$PUBLIC_HOST' DEEPSEEK_API_KEY='$DEEPSEEK_API_KEY' bash -s" <<'REMOTE_SETUP'
set -e
cd "$REMOTE_PATH"

# 修复所有 .sh 文件的 CRLF 行尾并添加执行权限
find . -name '*.sh' -exec sed -i 's/\r$//' {} +
find . -name '*.sh' -exec chmod +x {} +

# 从 .env.example 创建 .env（prepare.sh 稍后追加模型相关变量）
cp .env.example .env
sed -i "s|^DSH_PUBLIC_URL=.*|DSH_PUBLIC_URL=http://$PUBLIC_HOST/|" .env
sed -i "s|^DSH_TRUSTED_HOST=.*|DSH_TRUSTED_HOST=$PUBLIC_HOST|" .env
if [ -n "$DEEPSEEK_API_KEY" ]; then
  sed -i "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY|" .env
fi

echo "      .env ready."
REMOTE_SETUP

printf "      .env 已准备。\n\n"

# ---- [3/5] 下载模型（prepare.sh）----
printf "%b[3/5] 下载模型 %s（prepare.sh）...%b\n" "$YELLOW" "$MODEL_ID" "$NC"
printf "      模型较大，可能需要 20-60 分钟（支持断点续传，重跑即续传）。\n"

$SSHPASS_CMD ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "cd '$REMOTE_PATH' && bash scripts/prepare.sh -m '$MODEL_ID' -n '$SERVED_NAME'" 2>&1

printf "      模型准备完成。\n\n"

# ---- [4/5] 启动 vLLM 模型服务 ----
printf "%b[4/5] 启动 vLLM 模型服务（start-vllm.sh）...%b\n" "$YELLOW" "$NC"

$SSHPASS_CMD ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "cd '$REMOTE_PATH' && bash scripts/start-vllm.sh" 2>&1

printf "\n"

# ---- [5/5] 启动 DSH Agent + Nginx ----
printf "%b[5/5] 启动 DSH Agent + Nginx（start-ai.sh）...%b\n" "$YELLOW" "$NC"

$SSHPASS_CMD ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" \
  "cd '$REMOTE_PATH' && bash scripts/start-ai.sh" 2>&1

echo ""
printf "%b============================================%b\n" "$GREEN" "$NC"
printf "%b  部署完成！%b\n" "$GREEN" "$NC"
printf "%b============================================%b\n" "$GREEN" "$NC"
printf "  Web UI : http://%s/\n" "$PUBLIC_HOST"
printf "  模型   : %s（服务名 %s）\n" "$MODEL_ID" "$SERVED_NAME"
echo ""
printf "  提示：FP4 模型加载约需 20 分钟，健康检查通过后即可使用。\n"
printf "  vLLM 日志：ssh %s@%s 'docker compose -f %s/qwen/docker-compose.yml logs -f'\n" \
  "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PATH"
printf "  停止全部：ssh %s@%s 'cd %s && docker compose down && docker compose -f qwen/docker-compose.yml down'\n" \
  "$REMOTE_USER" "$REMOTE_HOST" "$REMOTE_PATH"
printf "%b============================================%b\n" "$GREEN" "$NC"
echo ""
