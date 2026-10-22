#!/bin/bash
# Bootstrap the lclstream oauth2 dev stack via podman kube play.
#
# Steps:
#   1. Bring the existing pod down (if running).
#   2. Optionally delete managed secrets+volumes (-d flag)
#   3. Re-create any managed secrets+volumes
#   4. bring the pod back up.
#
# Manages three podman secrets and one named volume:
#   lclstream-cookie-secret   oauth2-proxy AES cookie key  (32 hex chars)
#   lclstream-client-secret   OIDC client secret shared by Dex and oauth2-proxy
#   lclstream-dex-config      rendered dex/config.yaml with client secret embedded
#   lclstream-certified       certified TLS identity (shared by producer and api)
#
# The three secrets are treated as an atomic set: if any is missing, all three
# are regenerated together so lclstream-dex-config stays in sync with
# lclstream-client-secret.
#
# Usage:
#   ./bootstrap.sh        restart the stack; create any missing secrets/volume
#   ./bootstrap.sh -d     delete all secrets and the certified volume, then restart
#
# Requires: podman, openssl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OAUTH2_DIR="$(cd "$SCRIPT_DIR/../oauth2" && pwd)"
POD_NAME="lclstream-oauth2"
cd "$SCRIPT_DIR"

DELETE_VOLUMES=false
while getopts "d" opt; do
    case $opt in
        d) DELETE_VOLUMES=true ;;
        *) echo "Usage: $0 [-d]" >&2; exit 1 ;;
    esac
done

# ── 1. Bring the pod down ──────────────────────────────────────────────────
if podman pod inspect "$POD_NAME" &>/dev/null; then
    echo "Stopping pod $POD_NAME..."
    podman pod stop "$POD_NAME" 2>/dev/null || true
    podman pod rm   "$POD_NAME" 2>/dev/null || true
fi

# ── 2. Optionally delete secrets and volume ────────────────────────────────
if $DELETE_VOLUMES; then
    echo "Deleting secrets and certified volume..."
    podman secret rm \
        lclstream-cookie-secret lclstream-client-secret lclstream-dex-config \
        2>/dev/null || true
    podman volume rm lclstream-certified 2>/dev/null || true
fi

# ── 3. Create secrets (atomic: all-or-nothing) ────────────────────────────
echo "=== Secrets ==="
_all_exist=true
for _s in lclstream-cookie-secret lclstream-client-secret lclstream-dex-config; do
    podman secret inspect "$_s" &>/dev/null || { _all_exist=false; break; }
done

if $_all_exist; then
    echo "  All secrets present."
else
    # Remove any partial set before regenerating so the trio stays in sync.
    podman secret rm \
        lclstream-cookie-secret lclstream-client-secret lclstream-dex-config \
        2>/dev/null || true

    COOKIE_SECRET=$(openssl rand -hex 16)
    CLIENT_SECRET=$(openssl rand -hex 16)

    # podman kube play requires secrets referenced via secretKeyRef to be stored
    # as Kubernetes v1.Secret JSON, with each value base64-encoded under "data:".
    # Raw strings are rejected with "not valid JSON/YAML".
    _cookie_b64=$(printf '%s' "$COOKIE_SECRET" | base64 -w0)
    _client_b64=$(printf '%s' "$CLIENT_SECRET" | base64 -w0)

    printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"lclstream-cookie-secret"},"data":{"lclstream-cookie-secret":"%s"}}\n' \
        "$_cookie_b64" | podman secret create lclstream-cookie-secret -
    printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"lclstream-client-secret"},"data":{"lclstream-client-secret":"%s"}}\n' \
        "$_client_b64" | podman secret create lclstream-client-secret -

    # Render the dex config template: only ${LCLSTREAM_CLIENT_SECRET} is substituted;
    # the bcrypt password hashes in the file also contain $ but are not ${...} patterns.
    _dex_b64=$(LCLSTREAM_CLIENT_SECRET="$CLIENT_SECRET" \
        envsubst '${LCLSTREAM_CLIENT_SECRET}' \
        < "$OAUTH2_DIR/dex/config.yaml" | base64 -w0)
    printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"lclstream-dex-config"},"data":{"lclstream-dex-config":"%s"}}\n' \
        "$_dex_b64" | podman secret create lclstream-dex-config -

    echo "  Created: lclstream-cookie-secret, lclstream-client-secret, lclstream-dex-config"
fi

# ── 4. Create and initialise the certified volume ─────────────────────────
echo "=== Certified volume ==="
podman volume inspect lclstream-certified &>/dev/null \
    || podman volume create lclstream-certified

if podman run --rm \
        -v lclstream-certified:/etc/certified:ro \
        localhost/lclstream-api:latest \
        test -f /etc/certified/CA.crt 2>/dev/null; then
    echo "  lclstream-certified: identity exists"
else
    echo "  Initialising certified identity..."
    podman run --rm \
        -v lclstream-certified:/etc/certified \
        localhost/lclstream-api:latest \
        /app/.venv/bin/certified init \
            --config /etc/certified \
            --host localhost --host 127.0.0.1 \
            'LCLStream Test'
    echo "  Certified identity initialised."
fi

# ── 5. Ensure serve.py is present and start the pod ───────────────────────
# podman-kube.yaml uses ./serve.py as a static hostPath; podman resolves it
# relative to $PWD at play time, which is $SCRIPT_DIR (set above).
ln -sf ../oauth2/serve.py "$SCRIPT_DIR/serve.py"

echo "Starting pod $POD_NAME..."
podman kube play podman-kube.yaml

cat <<'EOF'

Stack is up:
  :4433  lclstream-simple  (producer, mTLS)
  :8000  lclstream-api     (TLS)
  :5556  dex               (OIDC)
  :4180  oauth2-proxy      (JWT auth, upstream → :8000)
EOF
