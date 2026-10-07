#!/bin/bash
# Start the Dex OIDC provider for local testing.
# Dex issues JWTs for test users alice@test.local and bob@test.local.
# Passwords: alicepass / bobpass

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

podman run --network host \
           -v "$SCRIPT_DIR/dex/config.yaml:/etc/dex/config.docker.yaml:ro" \
           -d docker.io/dexidp/dex:v2.41.1
