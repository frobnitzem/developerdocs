# OAuth2 / JWT Auth Setup

This directory tests lclstream-api behind an oauth2-proxy + Dex OIDC provider.

**Port layout:**

| Port | Service | Auth |
|------|---------|------|
| 4433 | psik_api (producer) | mTLS |
| 5556 | Dex OIDC provider | — |
| 4180 | oauth2-proxy | JWT Bearer token |
| 8000 | lclstream-api | none (proxy is the boundary) |

In production, only `:4180` should be externally reachable.
Requests to `/v1/callbacks` go directly to `:8000` (psik_api callback path, trusted internal network).

**Helper Scripts:**

- dex/config.yaml: Dex OIDC provider (in-memory, 2 static users)
- dex.sh: start Dex on :5556
- proxy.sh: start oauth2-proxy on :4180, upstream to lclstream-api:8000
- get_token.py: headless OIDC authorization code + PKCE flow (stdlib only)
- serve.py: lclstream-api entry point with require_client_cert=False
- api.sh: start lclstream-api container with serve.py volume-mounted
- test_e2e.sh: 6-test suite (unauthed→401, JWT→200, direct bypass, mTLS)

## Prerequisites

Pull the required images once:

```
podman pull docker.io/dexidp/dex:v2.41.1
podman pull quay.io/oauth2-proxy/oauth2-proxy:latest
```

Build or pull the application images:

```
# from the lclstream_api repo root:
podman build --network host -t lclstream-api .

# from the example/ directory:
podman build --network host -f Containerfile.simple -t lclstream-simple .
```

## Walkthrough

All commands run from this directory.

### Step 1: Start the producer

```
./producer.sh
```

Prints a container ID. psik_api is listening on `:4433` over mTLS.

**Successful completion:** `podman logs <id>` shows `certified serve ... listening`.

### Step 2: Start lclstream-api (no client cert required)

```
./api.sh
```

Prints a container ID. lclstream-api is listening on `:8000` over TLS (no client cert enforced — JWT auth is handled by the proxy in front of it).

**Successful completion:** `curl -sk https://localhost:8000/v1/transfers` returns JSON, not a connection error.

### Step 3: Start Dex

```
./dex.sh
```

Prints a container ID. Dex OIDC provider is listening on `:5556`.

**Successful completion:**

```
curl -s http://localhost:5556/dex/.well-known/openid-configuration | python3 -m json.tool
```

Returns a JSON document with `"issuer": "http://127.0.0.1:5556/dex"`.

### Step 4: Start oauth2-proxy

```
./proxy.sh
```

Prints a container ID. oauth2-proxy is listening on `:4180` and forwarding authenticated requests to lclstream-api at `:8000`.

**Successful completion:** `curl -s http://localhost:4180/v1/transfers` returns `401 Unauthorized` (not a connection error).

### Step 5: Acquire a JWT for a test user

```
python3 get_token.py --username alice@test.local --password alicepass
```

Runs the OIDC authorization code + PKCE flow against Dex and prints an `id_token` JWT to stdout.

**Successful completion:** A long dot-separated base64 string is printed. You can inspect the claims with:

```
python3 get_token.py | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Expect `"email": "alice@test.local"` and `"aud": "oauth2-proxy"`.

### Step 6: Make an authenticated request through the proxy

```
TOKEN=$(python3 get_token.py --username alice@test.local --password alicepass)
curl -sk -H "Authorization: Bearer $TOKEN" http://localhost:4180/v1/transfers
```

**Successful completion:** The proxy validates the JWT and forwards the request. The response comes from lclstream-api — typically `{"transfers": [...]}` or similar JSON, **not** `HTTP 401`.

### Step 7: Request a data transfer

```
# requires pyyaml
yaml_to_json() { python3 -c "import sys,yaml,json; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))" "$1"; }

XFER_JSON=$(yaml_to_json lclstreamer-internal.yaml)

TOKEN=$(python3 get_token.py --username alice@test.local --password alicepass)
curl -sk -X POST http://localhost:4180/v1/transfers \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/yaml" \
     -d "$XFER_JSON"
```

**Successful completion:** JSON response with a transfer `id` field and a `url` pointing to a ZMQ endpoint (e.g. `tcp://127.0.0.1:42100`). Pull the data with:

```
lclstream pull -v -d tcp://127.0.0.1:42100 | tar tf -
```

## Test users

| Email | Password | Username |
|-------|----------|----------|
| alice@test.local | alicepass | alice |
| bob@test.local | bobpass | bob |

Hashes are bcrypt ($2b$12$) in `dex/config.yaml`. To regenerate:

```
python3 -m venv /tmp/bv && /tmp/bv/bin/pip install -q bcrypt && \
  /tmp/bv/bin/python3 -c "import bcrypt; print(bcrypt.hashpw(b'newpass', bcrypt.gensalt(12)).decode())"
```

## Running the automated test suite

```
./test_e2e.sh
```

Starts all four containers, runs seven checks, then tears everything down.
Expected output ends with `=== All tests passed ===`.

**Before running:** check for stale containers from a prior run occupying ports
4433, 5556, 4180, or 8000 — see `src/AGENTS.md` for the cleanup one-liner.
The `wait_for_port` check will pass against a stale container, causing the new
container to silently fail to bind and tests to run against old code.
