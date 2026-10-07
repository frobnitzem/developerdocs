#!/bin/bash
# Start oauth2-proxy fronting lclstream-api.
#
# Routes:
#   :4180/v1/*  → JWT-validated → lclstream-api:8000  (external, authenticated)
#   :8000/v1/callbacks  → lclstream-api:8000 direct   (mTLS, internal only)
#
# Requires Dex running on :5556 (see dex.sh).
#
# Note: proxy.sh uses `--set-xauthrequest=true` so oauth2-proxy injects
# X-Auth-Request-User for session-based auth (bearer-token bypass
# path decodes the JWT directly in auth_proxy.py instead).


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 16 random bytes as 32 hex chars (valid AES-128 key length for cookie encryption)
COOKIE_SECRET=$(openssl rand -hex 16)

podman run --network host \
    -d quay.io/oauth2-proxy/oauth2-proxy:latest \
    --provider=oidc \
    --oidc-issuer-url=http://127.0.0.1:5556/dex \
    --client-id=oauth2-proxy \
    --client-secret=proxy-client-secret \
    --redirect-url=http://127.0.0.1:4180/oauth2/callback \
    --upstream=https://127.0.0.1:8000 \
    --ssl-upstream-insecure-skip-verify=true \
    --skip-jwt-bearer-tokens=true \
    --http-address=0.0.0.0:4180 \
    --email-domain='*' \
    --cookie-secret="$COOKIE_SECRET" \
    --insecure-oidc-allow-unverified-email=true \
    --pass-authorization-header=true \
    --pass-access-token=true \
    --set-xauthrequest=true \
    --api-route='^/v1/'
