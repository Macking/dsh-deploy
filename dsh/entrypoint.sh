#!/bin/bash
set -e

# Build dsh web command from environment variables.
# DSH's --trusted-host flag admits the browser-visible authority through
# the /api host fence; --public-url advertises the external URL.
ARGS=("web" "--no-open")

if [ -n "$DSH_PUBLIC_URL" ]; then
    ARGS+=("--public-url" "$DSH_PUBLIC_URL")
fi

if [ -n "$DSH_TRUSTED_HOST" ]; then
    ARGS+=("--trusted-host" "$DSH_TRUSTED_HOST")
fi

echo "[entrypoint] Starting: dsh ${ARGS[*]}"
exec dsh "${ARGS[@]}"
