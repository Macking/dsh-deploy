#!/usr/bin/env bash
#
# get-url.sh — Fetch the DSH WebUI launch URL (with token) from container logs.
#
# DSH prints a one-time launch URL in its startup logs:
#   dsh web: http://<host>/?token=<TOKEN>
# The token is required for first access — DSH exchanges it for a session
# cookie.  Subsequent requests use the cookie, not the token.
#
# Usage:
#   # Run directly on the server (docker available locally)
#   ./scripts/get-url.sh
#
#   # Run from local machine via SSH (same params as deploy.sh)
#   REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh
#   REMOTE_HOST=10.0.0.50 REMOTE_USER=myuser REMOTE_PASS=mypass ./scripts/get-url.sh
#
#   # Wait for the URL to appear (useful right after deployment)
#   REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --wait
#
#   # Print only the URL (for piping to curl / xdg-open)
#   REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --raw
#
# Options:
#   --wait            Poll until the URL appears (default timeout: 60s)
#   --raw             Print only the URL, no decorative output
#   -h, --help        Show this help
#
# Environment:
#   REMOTE_HOST     Server IP (empty = run locally on the server)
#   REMOTE_USER     SSH user (default: macking)
#   REMOTE_PASS     SSH password (default: 12345678)
#   WAIT_TIMEOUT    Max seconds to wait with --wait (default: 60)
#
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-macking}"
REMOTE_PASS="${REMOTE_PASS:-12345678}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"

# --- Parse arguments ---
DO_WAIT=false
RAW=false
for arg in "$@"; do
    case "$arg" in
        --wait) DO_WAIT=true ;;
        --raw)  RAW=true ;;
        -h|--help)
            cat <<'HELP'
get-url.sh — Fetch the DSH WebUI launch URL (with token) from container logs.

Usage:
  # Run directly on the server
  ./scripts/get-url.sh

  # Run from local machine via SSH
  REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh
  REMOTE_HOST=10.0.0.50 REMOTE_USER=myuser REMOTE_PASS=mypass ./scripts/get-url.sh

  # Wait for the URL to appear (right after deployment)
  REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --wait

  # Print only the URL (for piping)
  REMOTE_HOST=192.168.76.12 ./scripts/get-url.sh --raw

Options:
  --wait          Poll until the URL appears (timeout: WAIT_TIMEOUT, default 60s)
  --raw           Print only the URL, no decorative output
  -h, --help      Show this help

Environment:
  REMOTE_HOST     Server IP (empty = run locally on the server)
  REMOTE_USER     SSH user (default: macking)
  REMOTE_PASS     SSH password (default: 12345678)
  WAIT_TIMEOUT    Max wait seconds with --wait (default: 60)
HELP
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

# --- Docker command to extract the URL from container logs ---
#   sed strips ANSI color codes (dsh may emit colored output)
#   grep "dsh web: http" matches the URL line (not the entrypoint's
#     "Starting: dsh web --no-open" line, which lacks the colon)
#   tail -1 takes the most recent URL (each restart issues a new token)
#   final sed strips everything before the URL (including the -t timestamp)
GET_URL_CMD='docker logs -t dsh-harness 2>&1 | sed "s/\x1b\[[0-9;]*m//g" | grep "dsh web: http" | tail -1 | sed "s/.*dsh web: //"'

# --- Command runner: SSH (remote) or bash (local) ---
if [ -n "$REMOTE_HOST" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "ERROR: sshpass is required for remote mode." >&2
        echo "  Install: apt install sshpass" >&2
        echo "  Or run this script directly on the server (omit REMOTE_HOST)." >&2
        exit 1
    fi
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"
    SSHPASS_CMD="sshpass -p ${REMOTE_PASS}"
    run_cmd() { ${SSHPASS_CMD} ssh ${SSH_OPTS} ${REMOTE_USER}@${REMOTE_HOST} "$1"; }
    TARGET="${REMOTE_USER}@${REMOTE_HOST}"
else
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found on this machine." >&2
        echo "If running from your local machine, set REMOTE_HOST:" >&2
        echo "  REMOTE_HOST=<server-ip> $0" >&2
        exit 1
    fi
    run_cmd() { bash -c "$1"; }
    TARGET="localhost"
fi

# --- Fetch the URL ---
fetch_url() {
    local url
    url=$(run_cmd "$GET_URL_CMD" 2>/dev/null) || true
    # Validate: must start with http and contain a token parameter
    if [ -n "$url" ] && echo "$url" | grep -q '^http.*token='; then
        echo "$url"
        return 0
    fi
    return 1
}

print_result() {
    local url="$1"
    if [ "$RAW" = true ]; then
        echo "$url"
        return
    fi
    echo ""
    echo "============================================"
    echo "  DSH WebUI Launch URL"
    echo "============================================"
    echo "  Server : ${TARGET}"
    echo "  URL    : ${url}"
    echo "============================================"
    echo ""
    echo "  Open this URL in your browser to authenticate."
    echo "  DSH exchanges the token for a session cookie —"
    echo "  after that, you can visit the URL without the token."
    echo ""
}

# --- Main ---
if [ "$DO_WAIT" = true ]; then
    if [ "$RAW" != true ]; then
        echo "Waiting for DSH WebUI URL on ${TARGET} (timeout: ${WAIT_TIMEOUT}s)..."
    fi
    elapsed=0
    while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
        if url=$(fetch_url); then
            print_result "$url"
            exit 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        if [ "$RAW" != true ]; then
            printf "  ... waiting (%ds / %ds)\n" "$elapsed" "$WAIT_TIMEOUT"
        fi
    done
    echo "ERROR: Timed out after ${WAIT_TIMEOUT}s — URL not found in logs." >&2
    echo "Check the container manually:" >&2
    echo "  docker ps | grep dsh-harness" >&2
    echo "  docker logs dsh-harness" >&2
    exit 1
else
    if url=$(fetch_url); then
        print_result "$url"
    else
        echo "ERROR: Could not find 'dsh web: http...' in dsh-harness logs on ${TARGET}." >&2
        echo "" >&2
        echo "Possible causes:" >&2
        echo "  - Container not running: docker ps | grep dsh-harness" >&2
        echo "  - Still initializing:    $0 --wait" >&2
        echo "  - Logs rotated:          docker logs dsh-harness" >&2
        exit 1
    fi
fi
