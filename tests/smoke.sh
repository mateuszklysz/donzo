#!/bin/sh
# Smoke test for a built Kanzo image.
#   tests/smoke.sh <image> [platform]
#   tests/smoke.sh kanzo:local linux/arm64
set -eu

IMAGE="${1:?usage: tests/smoke.sh <image> [platform]}"
PLATFORM="${2:-}"
PORT="${SMOKE_PORT:-4299}"
NAME="kanzo-smoke-$$"
VOL="kanzo-smoke-$$"
BASE="http://127.0.0.1:$PORT"
FAIL=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker volume rm "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAIL=1; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

run() {
  docker run -d --name "$NAME" ${PLATFORM:+--platform "$PLATFORM"} \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    -e KANZO_PORT="$PORT" -p "127.0.0.1:$PORT:$PORT" -v "$VOL:/data" "$IMAGE" >/dev/null
  i=0
  until curl -fs "$BASE/api/ping" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 60 ] || { docker logs "$NAME"; bad "board did not start"; exit 1; }
    sleep 0.5
  done
}

echo "smoke: $IMAGE ${PLATFORM:-(native)}"
run

expect "kanzo --version" "kanzo" "$(docker exec "$NAME" kanzo --version | cut -d' ' -f1)"
expect "runs as uid 10001" "10001" "$(docker exec "$NAME" id -u)"
expect "no curl (self-update disabled)" "" "$(docker exec "$NAME" sh -c 'command -v curl || true')"
expect "config listens on 0.0.0.0" "1" "$(docker exec "$NAME" grep -c '^listen = "0.0.0.0"' /data/config.toml)"
expect "GET /api/ping" "kanzo" "$(curl -s "$BASE/api/ping")"
expect "GET / (UI)" "200" "$(code "$BASE/")"
expect "Host with foreign name rejected" "403" "$(code -H 'Host: evil.example' "$BASE/api/board")"
expect "Host with other port rejected" "403" "$(code -H 'Host: localhost:1' "$BASE/api/board")"
expect "cross-site Origin rejected" "403" "$(code -X POST -H 'Content-Type: application/json' \
  -H 'Origin: http://evil.example' "$BASE/api/projects" -d '{"slug":"x","name":"x"}')"
expect "create project" "200" "$(code -X POST -H 'Content-Type: application/json' \
  -H "Origin: http://127.0.0.1:$PORT" "$BASE/api/projects" -d '{"slug":"smoke","name":"Smoke"}')"
expect "MCP initialize" "1" "$(curl -s -X POST "$BASE/mcp" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  | grep -c '"serverInfo":{"name":"kanzo"')"

start=$(date +%s)
docker stop -t 10 "$NAME" >/dev/null
took=$(( $(date +%s) - start ))
if [ "$took" -lt 5 ]; then ok "graceful stop on SIGTERM (${took}s)"; else bad "stop took ${took}s"; fi
expect "exit code 0" "0" "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")"

docker rm "$NAME" >/dev/null
run
expect "data persists across restart" "1" "$(docker exec "$NAME" kanzo export -f json | grep -c '"slug": "smoke"')"

if [ "$FAIL" -ne 0 ]; then echo "smoke: FAILED"; exit 1; fi
echo "smoke: passed"
