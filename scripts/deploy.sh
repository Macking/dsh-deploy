#!/usr/bin/env bash
#
# DSH (DeepSeek Harness) deployment script — bash version.
# Deploys nginx + deepseek-harness containers to a remote Ubuntu server.
#
# Architecture:
#   Container 1 (dsh-harness): Node.js + official `dsh web` CLI, binds 127.0.0.1:3080
#   Container 2 (dsh-nginx):   Nginx reverse proxy, port 80 → 127.0.0.1:3080
#   Both containers use network_mode: host.
#
# Usage:
#   ./scripts/deploy.sh
#   REMOTE_HOST=192.168.76.12 REMOTE_USER=macking REMOTE_PASS=12345678 ./scripts/deploy.sh
#   REMOTE_HOST=10.0.0.50 PUBLIC_HOST=dsh.example.com ./scripts/deploy.sh
#
# Requires: sshpass (install with: apt install sshpass / brew install sshpass)
#
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-192.168.76.12}"
REMOTE_USER="${REMOTE_USER:-macking}"
REMOTE_PASS="${REMOTE_PASS:-12345678}"
REMOTE_PATH="${REMOTE_PATH:-/home/${REMOTE_USER}/dsh}"
# PUBLIC_HOST defaults to REMOTE_HOST (the common case: SSH IP == browser IP).
# Set PUBLIC_HOST when the public URL differs from the SSH host
# (e.g., a domain name or load balancer IP).
PUBLIC_HOST="${PUBLIC_HOST:-$REMOTE_HOST}"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ""
echo "============================================"
echo "  DSH Deployment — DeepSeek Harness + Nginx"
echo "============================================"
echo "  Remote : ${REMOTE_USER}@${REMOTE_HOST}"
echo "  Public : ${PUBLIC_HOST}"
echo "  Path   : ${REMOTE_PATH}"
echo "  Source : ${PROJECT_ROOT}"
echo "============================================"
echo ""

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"
SSHPASS_CMD="sshpass -p ${REMOTE_PASS}"

# --- [1/6] Check connectivity ---
echo "[1/6] Connecting to ${REMOTE_HOST} ..."
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "echo connected" || {
    echo "ERROR: cannot connect. Is sshpass installed? (apt install sshpass)"
    exit 1
}

# --- [2/6] Prepare remote directory ---
echo "[2/6] Preparing remote directory ..."
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "mkdir -p ${REMOTE_PATH}/nginx/conf.d ${REMOTE_PATH}/dsh"

# --- [3/6] Upload project files ---
echo "[3/6] Uploading project files ..."
${SSHPASS_CMD} scp ${SSH_OPTS} \
    "${PROJECT_ROOT}/docker-compose.yml" \
    "${PROJECT_ROOT}/.env" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"

${SSHPASS_CMD} scp ${SSH_OPTS} \
    "${PROJECT_ROOT}/nginx/nginx.conf" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/nginx/"

${SSHPASS_CMD} scp ${SSH_OPTS} \
    "${PROJECT_ROOT}/nginx/conf.d/default.conf" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/nginx/conf.d/"

${SSHPASS_CMD} scp ${SSH_OPTS} \
    "${PROJECT_ROOT}/dsh/Dockerfile" \
    "${PROJECT_ROOT}/dsh/entrypoint.sh" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/dsh/"

# Fix CRLF line endings on entrypoint.sh (uploaded from Windows) and make executable
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "sed -i 's/\r$//' ${REMOTE_PATH}/dsh/entrypoint.sh && chmod +x ${REMOTE_PATH}/dsh/entrypoint.sh"

# Update .env with the target host's IP so DSH_PUBLIC_URL and DSH_TRUSTED_HOST
# match the server being deployed to (not the default IP in the repo .env).
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "sed -i 's|^DSH_PUBLIC_URL=.*|DSH_PUBLIC_URL=http://${PUBLIC_HOST}/|; s|^DSH_TRUSTED_HOST=.*|DSH_TRUSTED_HOST=${PUBLIC_HOST}|' ${REMOTE_PATH}/.env"

# --- [4/6] Build Docker image ---
echo "[4/6] Building dsh Docker image (may take a few minutes) ..."
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "cd ${REMOTE_PATH} && docker compose build" 2>&1

# --- [5/6] Start containers ---
echo "[5/6] Starting containers ..."
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "cd ${REMOTE_PATH} && docker compose down 2>/dev/null; docker compose up -d" 2>&1

echo "      waiting for dsh to initialize (30s) ..."
sleep 30

${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "cd ${REMOTE_PATH} && docker compose ps"

# --- [6/6] Verify deployment ---
echo "[6/6] Verifying deployment ..."
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "ss -tlnp | grep ':3080' || echo 'dsh not yet listening on 3080'"
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "ss -tlnp | grep ':80 ' || echo 'nginx not yet listening on 80'"
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || echo 'proxy not ready'"
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "docker logs dsh-harness --tail 15 2>&1"
${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "docker logs dsh-nginx --tail 10 2>&1"

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "============================================"
echo "  Web UI         : http://${PUBLIC_HOST}/"
echo "  Direct dsh     : http://127.0.0.1:3080 (host only)"
echo ""
echo "  Note: dsh binds to 127.0.0.1:3080 (loopback only)."
echo "  Access via nginx at http://${PUBLIC_HOST}/ on port 80."
echo "============================================"
echo ""
