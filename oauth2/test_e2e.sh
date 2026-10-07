#!/bin/bash
# End-to-end test for lclstream-api with oauth2-proxy + Dex JWT validation.
#
# Port layout:
#   :4433  psik_api (producer, mTLS)
#   :5556  Dex OIDC provider
#   :4180  oauth2-proxy  (/v1/* JWT-protected, upstream → :8000)
#   :8000  lclstream-api (no client cert required; direct for /v1/callbacks)
#
# Tests:
#   1. Unauthed request to proxy → 401
#   2. Acquire alice's JWT from Dex
#   3. Authed request through proxy with alice's JWT → not 401
#   4. Direct request to :8000 without credentials → 401
#   5. mTLS direct request to :8000 with client cert → not 401
#   6. Transfer creation + data pull through proxy (alice)
#   7. Acquire bob's JWT; cross-user isolation check (skipped until API reads X-Auth-Request-Email)
#
# Prerequisites (one-time):
#   podman pull docker.io/dexidp/dex:v2.41.1
#   podman pull quay.io/oauth2-proxy/oauth2-proxy:latest
#
# Usage: ./test_e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VIRTUAL_ENV="${VIRTUAL_ENV:-$SCRIPT_DIR/venv}"
TIMEOUT=${TIMEOUT:-90}

PRODUCER_CTR=""
API_CTR=""
DEX_CTR=""
PROXY_CTR=""

cleanup() {
    local exit_code=$?
    for ctr in "$PROXY_CTR" "$DEX_CTR" "$API_CTR" "$PRODUCER_CTR"; do
        [ -n "$ctr" ] && { podman stop "$ctr" 2>/dev/null; podman rm "$ctr" 2>/dev/null; } || true
    done
    exit $exit_code
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }

wait_for_port() {
    local label=$1 port=$2 i=0
    echo "  waiting for $label on :$port..."
    while ! (echo > /dev/tcp/localhost/"$port") 2>/dev/null; do
        sleep 1
        i=$((i+1))
        [ $i -lt $TIMEOUT ] || fail "$label did not open :$port within ${TIMEOUT}s"
    done
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! [ -x "$VIRTUAL_ENV/bin/python" ]; then
    echo "Creating virtual environment at $VIRTUAL_ENV."
    python3 -m venv "$VIRTUAL_ENV"
fi
export PATH="$VIRTUAL_ENV/bin:$PATH"

CERTIFIED_CONFIG="${CERTIFIED_CONFIG:-$VIRTUAL_ENV/etc/certified}"

if ! [ -d "$CERTIFIED_CONFIG" ]; then
    if [ -x "$VIRTUAL_ENV/bin/uv" ]; then
        PIP="$VIRTUAL_ENV/bin/uv pip"
    else
        PIP="$VIRTUAL_ENV/bin/pip"
        [ -x "$PIP" ] || fail "\$VIRTUAL_ENV does not contain uv or pip"
    fi
    echo "Initializing certified identity at $CERTIFIED_CONFIG"
    $PIP install certified lclstream
    certified init --host localhost --host 127.0.0.1 'Test Developer'
fi

command -v curl      >/dev/null || fail "'curl' not found"
command -v podman    >/dev/null || fail "'podman' not found"
command -v lclstream >/dev/null || fail "'lclstream' not in PATH or venv; run: pip install lclstream"

# Helper: convert a YAML file to a JSON string (requires pyyaml, installed with lclstream)
yaml_to_json() { python3 -c "import sys,yaml,json; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))" "$1"; }

# ── Start containers ──────────────────────────────────────────────────────────
echo "=== Starting producer container ==="
PRODUCER_CTR=$(./producer.sh) || fail "producer.sh failed"
echo "  producer: $PRODUCER_CTR"
wait_for_port "psik_api" 4433

echo "=== Starting lclstream-api container ==="
API_CTR=$(./api.sh) || fail "api.sh failed"
echo "  api: $API_CTR"
wait_for_port "lclstream-api" 8000

echo "=== Starting Dex OIDC provider ==="
DEX_CTR=$(./dex.sh) || fail "dex.sh failed"
echo "  dex: $DEX_CTR"
wait_for_port "dex" 5556

echo "=== Starting oauth2-proxy ==="
PROXY_CTR=$(./proxy.sh) || fail "proxy.sh failed"
echo "  proxy: $PROXY_CTR"
wait_for_port "oauth2-proxy" 4180

# Give oauth2-proxy a moment to fetch Dex's JWKS (OIDC discovery)
sleep 3

# ── Test 1: unauthed request to proxy returns 401 ─────────────────────────────
echo "=== Test 1: unauthenticated request to proxy ==="
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" http://localhost:4180/v1/transfers)
[ "$HTTP_CODE" = "401" ] \
    || fail "expected 401 from proxy for unauthenticated request, got $HTTP_CODE"
pass "unauthenticated /v1/transfers → 401 from oauth2-proxy"

# ── Test 2: acquire JWT for alice ─────────────────────────────────────────────
echo "=== Test 2: acquire JWT for alice from Dex ==="
ALICE_TOKEN=$(python3 get_token.py --username alice@test.local --password alicepass) \
    || fail "get_token.py failed for alice"
[ -n "$ALICE_TOKEN" ] || fail "empty token for alice"
pass "acquired JWT for alice (${#ALICE_TOKEN} bytes)"

# ── Test 3: authed GET through proxy with alice's JWT ────────────────────────
echo "=== Test 3: alice's JWT accepted by proxy ==="
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ALICE_TOKEN" \
    http://localhost:4180/v1/transfers)
[ "$HTTP_CODE" != "401" ] \
    || fail "proxy rejected alice's valid JWT (got 401)"
[ "$HTTP_CODE" != "000" ] \
    || fail "no response from proxy for alice's request"
pass "alice's JWT passed proxy validation → HTTP $HTTP_CODE from upstream"

# ── Test 4: direct access to :8000 without credentials → 401 ─────────────────
echo "=== Test 4: direct access to lclstream-api:8000 without credentials → 401 ==="
# Auth is enforced at both :4180 (JWT via proxy) and :8000 (JWT or mTLS directly).
# A request with no credentials must be rejected.
HTTP_CODE_DIRECT=$(curl -sk -o /dev/null -w "%{http_code}" \
    https://localhost:8000/v1/transfers)
[ "$HTTP_CODE_DIRECT" != "000" ] \
    || fail "no response from :8000 direct access"
[ "$HTTP_CODE_DIRECT" = "401" ] \
    || fail "expected 401 from :8000 for unauthenticated request, got $HTTP_CODE_DIRECT"
pass "direct :8000 without credentials → 401 (auth enforced at API layer)"
echo "  NOTE: in production, :8000 must not be exposed externally — use :4180 only"

# ── Test 5: mTLS client cert direct to :8000 ─────────────────────────────────
echo "=== Test 5: mTLS client cert accepted directly by :8000 ==="
CLIENT_CERT="$CERTIFIED_CONFIG/id.crt"
CLIENT_KEY="$CERTIFIED_CONFIG/id.key"
CA_CERT="$CERTIFIED_CONFIG/CA.crt"
if [ -f "$CLIENT_CERT" ] && [ -f "$CLIENT_KEY" ]; then
    HTTP_CODE=$(curl -s \
        --cacert "$CA_CERT" \
        --cert "$CLIENT_CERT" \
        --key "$CLIENT_KEY" \
        -o /dev/null -w "%{http_code}" \
        https://localhost:8000/v1/transfers)
    [ "$HTTP_CODE" != "000" ] || fail "no response from :8000 with client cert"
    [ "$HTTP_CODE" != "401" ] || fail "mTLS client cert rejected by :8000 (got 401); check certified identity and trusted_proxy fallthrough"
    pass "mTLS client cert accepted by :8000 → HTTP $HTTP_CODE"
else
    skip "client cert not found at $CLIENT_CERT"
fi

# ── Test 6: transfer creation + data pull through proxy ──────────────────────
echo "=== Test 6: create transfer and pull data through proxy ==="
XFER_JSON=$(yaml_to_json lclstreamer-internal.yaml)
ALICE_RESP=$(curl -sk \
    -X POST http://localhost:4180/v1/transfers \
    -H "Authorization: Bearer $ALICE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$XFER_JSON")
echo "  response: $ALICE_RESP"

XFER_ID=$(echo "$ALICE_RESP" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['id'])" 2>/dev/null || true)
XFER_URL=$(echo "$ALICE_RESP" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['url'])" 2>/dev/null || true)
[ -n "$XFER_ID" ]  || fail "transfer creation returned no 'id' field; response: $ALICE_RESP"
[ -n "$XFER_URL" ] || fail "transfer creation returned no 'url' field"
pass "transfer created: id=$XFER_ID url=$XFER_URL"

ENTRY_COUNT=$(lclstream pull -d "$XFER_URL" | tar tf - | wc -l)
[ "$ENTRY_COUNT" -gt 0 ] || fail "lclstream pull returned empty tar from $XFER_URL"
pass "pulled $ENTRY_COUNT HDF5 entries from $XFER_URL"

# ── Test 7: cross-user isolation ─────────────────────────────────────────────
echo "=== Test 7: cross-user isolation ==="
BOB_TOKEN=$(python3 get_token.py --username bob@test.local --password bobpass) \
    || fail "get_token.py failed for bob"
[ -n "$BOB_TOKEN" ] || fail "empty token for bob"
pass "acquired JWT for bob"

[ "$ALICE_TOKEN" != "$BOB_TOKEN" ] \
    || fail "alice and bob received identical JWTs"
pass "alice and bob have distinct JWTs"

# Check whether the API is scoping transfers by user identity.
# The proxy forwards X-Auth-Request-Email; lclstream_api must read it to scope transfers.
# Until that is wired up, "user" in the transfer response is "none" and isolation is absent.
BOB_RESP=$(curl -sk -H "Authorization: Bearer $BOB_TOKEN" \
    "http://localhost:4180/v1/transfers/$XFER_ID")
XFER_USER=$(echo "$ALICE_RESP" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('user','none'))" 2>/dev/null || true)

[ "$XFER_USER" != "none" ] \
    || fail "transfer user is 'none' — API not reading X-Auth-Request-User from oauth2-proxy; check trusted_proxy config and CurrentUser dependency"

BOB_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $BOB_TOKEN" \
    "http://localhost:4180/v1/transfers/$XFER_ID")
[ "$BOB_CODE" = "403" ] || [ "$BOB_CODE" = "404" ] \
    || fail "expected 403/404 when bob accesses alice's transfer, got $BOB_CODE"
pass "cross-user isolation enforced: bob cannot access alice's transfer ($BOB_CODE)"

echo "=== All tests passed ==="
