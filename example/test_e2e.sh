#!/bin/bash
# End-to-end test for lclstream-api + lclstream-simple producer.
# Automates README.md Step 4: producer + forwarder + receiver in one shot.
#
# Prerequisites (one-time setup):
#   python3 -m venv ./venv && . ./venv/bin/activate
#   pip install certified psik lclstream
#   certified init --host localhost --host 127.0.0.1 'Test Developer'
#
# Usage (from this directory):
#   ./test_e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VIRTUAL_ENV="${VIRTUAL_ENV:-$SCRIPT_DIR/venv}"
TIMEOUT=${TIMEOUT:-60}

PRODUCER_CTR=""
API_CTR=""

cleanup() {
    local exit_code=$?
    [ -n "$PRODUCER_CTR" ] && { podman stop "$PRODUCER_CTR" 2>/dev/null; podman rm "$PRODUCER_CTR" 2>/dev/null; } || true
    [ -n "$API_CTR" ]      && { podman stop "$API_CTR"      2>/dev/null; podman rm "$API_CTR"      2>/dev/null; } || true
    exit $exit_code
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

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
    echo "Creating a virtual environment at $VIRTUAL_ENV."
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

  echo "Initializing a certified identity at $CERTIFIED_CONFIG"
  $PIP install certified
  certified init --host localhost --host 127.0.0.1 'Test Developer'
fi

command -v lclstream  >/dev/null || fail "'lclstream' not found in venv"
command -v podman     >/dev/null || fail "'podman' not found"

# ── Start containers ──────────────────────────────────────────────────────────
echo "=== Starting producer container ==="
PRODUCER_CTR=$(./producer.sh) || fail "producer.sh failed"
echo "  producer: $PRODUCER_CTR"
wait_for_port "psik_api" 4433

echo "=== Starting lclstream-api container ==="
API_CTR=$(./api.sh) || fail "api.sh failed"
echo "  api: $API_CTR"
wait_for_port "lclstream-api" 8000

# ── Step 4: request transfer, receive data ────────────────────────────────────
echo "=== Running lclstream get (Step 4) ==="
TAR_LISTING=$(lclstream get --mtls --server https://localhost:8000 \
    lclstreamer-internal.yaml | tar tf -) \
    || fail "lclstream get failed"

echo "$TAR_LISTING"

# Verify we received at least one HDF5 entry
entry_count=$(echo "$TAR_LISTING" | grep -c '\.' || true)
[ "$entry_count" -gt 0 ] || fail "tar output was empty — no data received"

pass "received $entry_count tar entries from transfer"
echo "=== All tests passed ==="
