#!/bin/bash
# Start the lclstream-api container using serve.py (no mTLS client cert required).
# serve.py is mounted from this directory so no image rebuild is needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIRTUAL_ENV="${VIRTUAL_ENV:-$SCRIPT_DIR/venv}"
CERTIFIED_CONFIG="${CERTIFIED_CONFIG:-$VIRTUAL_ENV/etc/certified}"

if ! [ -d "$CERTIFIED_CONFIG" ]; then
    echo "You must setup an identity via 'certified init',"
    echo "either in \$VIRTUAL_ENV/etc/certified (default) or by setting \$CERTIFIED_CONFIG"
    exit 1
fi

image="localhost/lclstream-api"

podman run --network host \
           -v "$CERTIFIED_CONFIG:/etc/certified" \
           -v "$SCRIPT_DIR/serve.py:/app/serve.py:ro" \
           -d "$image" \
           /app/.venv/bin/python /app/serve.py
