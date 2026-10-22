#!/usr/bin/env python3
"""Headless OIDC token acquisition from Dex.

Automates the authorization code + PKCE flow by simulating a browser:
  1. GET /dex/auth → login form
  2. POST credentials → Dex redirects to callback with code
  3. POST /dex/token → id_token

Usage:
  python3 get_token.py                               # alice's id_token
  python3 get_token.py --username bob@test.local --password bobpass
  python3 get_token.py --format json                 # all token fields
"""

import argparse
import base64
import hashlib
import html
import json
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

DEX_ISSUER = "http://127.0.0.1:5556/dex"
CLIENT_ID = "oauth2-proxy"
CLIENT_SECRET = "proxy-client-secret"
REDIRECT_URI = "http://127.0.0.1:18855/callback"


def pkce_pair():
    verifier = secrets.token_urlsafe(43)
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


class _StopAtCallback(urllib.request.HTTPRedirectHandler):
    """Follow Dex-internal redirects; raise HTTPError when we hit REDIRECT_URI."""
    def http_error_302(self, req, fp, code, msg, headers):
        loc = headers.get("Location", "")
        if loc.startswith(REDIRECT_URI):
            raise urllib.error.HTTPError(loc, code, msg, headers, fp)
        return super().http_error_302(req, fp, code, msg, headers)
    http_error_303 = http_error_302
    http_error_301 = http_error_302


def get_token(username: str, password: str, dex_issuer: str = DEX_ISSUER) -> dict:
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(16)

    auth_url = dex_issuer + "/auth?" + urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": "openid email profile",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    })

    jar = urllib.request.HTTPCookieProcessor()
    opener = urllib.request.build_opener(jar, _StopAtCallback())

    # Step 1: load login form
    resp = opener.open(auth_url)
    login_html = resp.read().decode()

    m = re.search(r'<form[^>]+action="([^"]+)"', login_html)
    if not m:
        raise RuntimeError(f"No login form found in Dex response:\n{login_html[:400]}")
    # HTML-decode the action URL (Dex encodes '&' as '&amp;' in attributes)
    action = html.unescape(m.group(1))
    if action.startswith("/"):
        base = dex_issuer.rsplit("/dex", 1)[0]
        action = base + action

    # Step 2: submit credentials; catch redirect to callback
    login_data = urllib.parse.urlencode({"login": username, "password": password}).encode()
    code = None
    try:
        opener.open(action, login_data)
        raise RuntimeError("Expected redirect to callback, got 200 — check credentials")
    except urllib.error.HTTPError as e:
        loc = e.url if hasattr(e, "url") else e.headers.get("Location", "")
        if not loc.startswith(REDIRECT_URI):
            # Unexpected redirect — re-raise
            raise RuntimeError(f"Unexpected redirect to: {loc}") from e
        params = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
        if "error" in params:
            raise RuntimeError(f"Dex error: {params['error'][0]}: {params.get('error_description', [''])[0]}")
        code = params.get("code", [None])[0]

    if not code:
        raise RuntimeError("Authorization code not found in Dex callback redirect")

    # Step 3: exchange code for tokens
    token_data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "code_verifier": verifier,
    }).encode()
    req = urllib.request.Request(
        dex_issuer + "/token",
        token_data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    resp = urllib.request.urlopen(req)
    return json.loads(resp.read())


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--username", default="alice@test.local")
    ap.add_argument("--password", default="alicepass")
    ap.add_argument("--dex", default=DEX_ISSUER)
    ap.add_argument("--format", choices=["id_token", "access_token", "json"],
                    default="id_token")
    args = ap.parse_args()

    tokens = get_token(args.username, args.password, args.dex)

    if args.format == "json":
        print(json.dumps(tokens, indent=2))
    elif args.format == "access_token":
        print(tokens.get("access_token", ""))
    else:
        tok = tokens.get("id_token", "")
        if not tok:
            print(json.dumps(tokens, indent=2), file=sys.stderr)
            sys.exit(1)
        print(tok)


if __name__ == "__main__":
    main()
