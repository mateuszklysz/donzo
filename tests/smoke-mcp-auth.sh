#!/bin/sh
# Smoke test for the mcp-auth image (mcp-auth/Dockerfile).
#   tests/smoke-mcp-auth.sh <image> [platform]
set -eu

IMAGE="${1:?usage: tests/smoke-mcp-auth.sh <image> [platform]}"
PLATFORM="${2:-}"
PORT="${SMOKE_PORT:-8099}"
NAME="mcp-auth-smoke-$$"
VOL="mcp-auth-smoke-$$"
BASE="http://127.0.0.1:$PORT"
SITE="https://kanzo.example.com"
FAIL=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAIL=1; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi
}
contains() { # name needle haystack
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in: $3)" ;; esac
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "mcp-auth smoke test: $IMAGE ${PLATFORM:+($PLATFORM)}"
docker run -d --name "$NAME" ${PLATFORM:+--platform "$PLATFORM"} \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e EXTERNAL_URL="$SITE" -e GITHUB_CLIENT_ID=smoke -e GITHUB_CLIENT_SECRET=smoke \
  -e GITHUB_ALLOWED_USERS=octocat \
  -p "127.0.0.1:$PORT:8080" -v "$VOL:/data" "$IMAGE" http://upstream.invalid:4242 >/dev/null
i=0
until curl -fs "$BASE/healthz" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then docker logs "$NAME"; echo "  FAIL did not start"; exit 1; fi
  sleep 1
done
ok "starts read-only, without capabilities"

expect "runs as non-root" "65532:65532" "$(docker inspect -f '{{.Config.User}}' "$NAME")"
contains "protected resource metadata" "\"authorization_servers\":[\"$SITE/\"]" \
  "$(curl -s "$BASE/.well-known/oauth-protected-resource")"
as="$(curl -s "$BASE/.well-known/oauth-authorization-server")"
contains "authorization server: client registration" "\"registration_endpoint\":\"$SITE/.idp/register\"" "$as"
contains "authorization server: PKCE S256" '"code_challenge_methods_supported":["S256"]' "$as"
expect "client registration" 201 "$(code -X POST "$BASE/.idp/register" -H 'content-type: application/json' \
  -d '{"client_name":"smoke","redirect_uris":["https://claude.ai/api/mcp/auth_callback"],"token_endpoint_auth_method":"none"}')"
expect "/mcp without a token" 401 "$(code -X POST "$BASE/mcp")"
expect "/mcp with a forged token" 401 "$(code -X POST "$BASE/mcp" -H 'Authorization: Bearer eyJhbGciOiJub25lIn0.e30.')"
# GitHub sign-in asks for no scopes at all when only logins are allowed.
loc="$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/.auth/github")"
contains "GitHub sign-in" "https://github.com/login/oauth/authorize?client_id=smoke&" "$loc"
case "$loc" in *scope=*) bad "GitHub sign-in asks for scopes: $loc" ;; *) ok "GitHub sign-in asks for no scopes" ;; esac

# The signing key survives a restart (it lives in the volume).
jwks="$(curl -s "$BASE/.well-known/jwks.json")"
docker restart "$NAME" >/dev/null
i=0
until curl -fs "$BASE/healthz" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { bad "did not restart"; break; }; sleep 1
done
expect "signing key kept across restarts" "$jwks" "$(curl -s "$BASE/.well-known/jwks.json")"

[ "$FAIL" = 0 ] && echo "all ok" || { docker logs "$NAME" 2>&1 | tail -20; exit 1; }
