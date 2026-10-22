# Agent Notes — LCLStream development

Operational notes for automated agents and developers running the containerized test stack.

## Repos and images

| Repo | Containerfile | Image name |
| :--- | :--- | :--- |
| [github:lclstream/lclstream_api](https://github.com/lclstream/lclstream_api) | `container/Containerfile` | `lclstream-api` |
| [github:lclstream/developerdocs](https://github.com/lclstream/developerdocs) | `example/Containerfile.simple` | `lclstream-simple` |
| `docker.io/dexidp/dex` | pulled, not built | `v2.41.1` (pin this; `latest` has breaking config changes) |
| `quay.io/oauth2-proxy/oauth2-proxy` | pulled, not built | `latest` (v7.x; check `--help` if flags change) |

## Building containers

### lclstream-api

```bash
cd src/lclstream_api
podman build -f container/Containerfile -t lclstream-api:latest .
```

**Always use `--no-cache` after source changes.**
The builder stage (`uv sync --no-editable`) is cached by layer hash.
If only Python source files changed (not `pyproject.toml` or `uv.lock`), podman may reuse
the builder layer and the new code will not be in the image.

```bash
podman build --no-cache -f container/Containerfile -t lclstream-api:latest .
```

### lclstream-simple (producer stub)

```bash
cd src/developerdocs/example
podman build --network host -f Containerfile.simple -t lclstream-simple:latest .
```

## Running the oauth2 test suite

```bash
cd src/developerdocs/oauth2
bash test_e2e.sh
```

### Stale containers are the most common failure mode

`test_e2e.sh` starts fresh containers and cleans them up on exit. If a previous run was killed
(Ctrl-C before the trap fired, OOM, reboot), containers may still occupy ports 4433, 5556, 4180,
and 8000. The `wait_for_port` check will pass immediately against the old container, and the new
one silently fails to bind. Tests then run against stale code, producing confusing results
(e.g. `user='none'` on transfer responses when `CurrentUser` was already wired in).

Before running tests, check for and remove stale containers:

```bash
podman ps --format "{{.ID}} {{.Image}}" \
  | grep -E "lclstream|dexidp|oauth2-proxy" \
  | awk '{print $1}' \
  | xargs -r podman stop
podman ps -a --format "{{.ID}} {{.Image}}" \
  | grep -E "lclstream|dexidp|oauth2-proxy" \
  | awk '{print $1}' \
  | xargs -r podman rm
```

### api.sh mounts serve.py from the local directory

`api.sh` does **not** use the image's default `CMD`. It mounts
`developerdocs/oauth2/serve.py` into the container and runs it directly.
This means changes to `serve.py` take effect immediately without a rebuild,
but changes to any other Python source in `lclstream_api` still require a rebuild.

### Cookie secret length

`proxy.sh` generates the oauth2-proxy cookie secret with `openssl rand -hex 16`,
which produces 32 hex characters = 32 raw bytes. oauth2-proxy requires exactly 16, 24, or 32
raw bytes. `openssl rand -base64 32` gives 44 ASCII characters and will be rejected
with a "must be 16, 24, or 32 bytes" error.

### Dex uses in-memory storage

`dex/config.yaml` uses `storage: {type: memory}`. Dex runs as uid 1001 so would require a uid-mapped host bind-mounted directory.
In-memory storage is fine for the test stack; state is lost on
container restart (no issue since Dex is stateless from the test's perspective).

### Dex image version

Pin `docker.io/dexidp/dex:v2.41.1`. The `latest` tag has changed the format of its login form
action URL and the PKCE state parameter format. `get_token.py` is written against v2.41.1
behavior (HTML-encoded `&amp;` in form actions, `?back=&state=STATE` query format).

### oauth2-proxy and X-Auth-Request-User

With `--skip-jwt-bearer-tokens=true`, oauth2-proxy validates Bearer JWTs inline but does **not**
inject `X-Auth-Request-User` / `X-Auth-Request-Email` headers — those only appear in the
session-cookie code path. The `Authorization: Bearer <jwt>` header is forwarded as-is
(via `--pass-authorization-header=true`). `auth_proxy.py` decodes the email claim from the
JWT payload directly; no re-verification is needed since the proxy already checked the signature.

### certified addr: fallback

`certified.fast.get_clientname(request)` returns `"addr:X.X.X.X"` when no mTLS client cert
is presented. This is truthy and will be accepted as a user identity unless explicitly filtered.
`auth_proxy.py` rejects identities starting with `"addr:"` so that unauthenticated direct
requests to `:8000` correctly return 401.

### load_config() is cached

`lclstream_api.config.load_config` is decorated with `@functools.cache`. Config is read once
per process lifetime. If you change `lclstream_api.yaml` without restarting the container,
the running API will not pick up the change.

### Dependency pinning

`lclstream_api` uses `uv.lock` with `--locked` sync. If `certified`, `psik`, or other
git-sourced dependencies are updated upstream, `uv.lock` must be regenerated:

```bash
cd src/lclstream_api
uv lock
podman build --no-cache -f container/Containerfile -t lclstream-api:latest .
```

Failing to regenerate after an upstream update can cause the build to succeed (cached venv)
while the running container uses an older version of the dependency.
