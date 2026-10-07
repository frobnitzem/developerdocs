#!/bin/bash
# Start the Dex OIDC provider for local testing.
# Dex issues JWTs for test users alice@test.local and bob@test.local.
# Passwords: alicepass / bobpass

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
# shellcheck source=.env
source "$SCRIPT_DIR/.env"
set +a

envsubst '${LCLSTREAM_CLIENT_SECRET}' < "$SCRIPT_DIR/dex/config.yaml" > "$SCRIPT_DIR/dex/config.live.yaml"

podman run --network host \
           -v "$SCRIPT_DIR/dex/config.live.yaml:/etc/dex/config.docker.yaml:ro" \
           -d docker.io/dexidp/dex:v2.41.1
