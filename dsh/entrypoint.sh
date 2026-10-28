#!/bin/bash
set -e

# Build dsh web command from environment variables.
# DSH's --trusted-host flag admits the browser-visible authority through
# the /api host fence; --public-url advertises the external URL.
ARGS=("web" "--no-open")

# ---------------------------------------------------------------------------
# Auto-detect the host's primary LAN IP when DSH_PUBLIC_URL is not explicitly
# set (empty, localhost, or 127.0.0.1).  This makes `docker compose up -d`
# work out-of-the-box on any machine without editing .env.
#
# The container uses network_mode: host, so it shares the host's network
# namespace and can see the host's actual IP addresses.
# ---------------------------------------------------------------------------
detect_host_ip() {
    local ip=""
    # Primary: source IP of the default route (most reliable — always the
    # primary NIC address, never docker bridge or link-local).
    ip=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    # Fallback: hostname -I, filtering out loopback / docker bridge / link-local.
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
            | grep -E '^[0-9]+\.' \
            | grep -v -E '^127\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^169\.254\.' \
            | head -1)
    fi
    echo "$ip"
}

# Treat empty / localhost / 127.0.0.1 as "not configured" -> auto-detect.
needs_autodetect() {
    local url="$1"
    [ -z "$url" ] && return 0
    case "$url" in
        *localhost*|*127.0.0.1*) return 0 ;;
    esac
    return 1
}

if needs_autodetect "$DSH_PUBLIC_URL"; then
    DETECTED_IP=$(detect_host_ip)
    if [ -n "$DETECTED_IP" ]; then
        DSH_PUBLIC_URL="http://${DETECTED_IP}/"
        DSH_TRUSTED_HOST="$DETECTED_IP"
        echo "[entrypoint] Auto-detected host IP: ${DETECTED_IP}"
    else
        echo "[entrypoint] WARNING: could not auto-detect host IP; falling back to DSH_PUBLIC_URL='${DSH_PUBLIC_URL:-<unset>}'"
    fi
fi

if [ -n "$DSH_PUBLIC_URL" ]; then
    ARGS+=("--public-url" "$DSH_PUBLIC_URL")
fi

if [ -n "$DSH_TRUSTED_HOST" ]; then
    ARGS+=("--trusted-host" "$DSH_TRUSTED_HOST")
fi

echo "[entrypoint] Starting: dsh ${ARGS[*]}"
exec dsh "${ARGS[@]}"
