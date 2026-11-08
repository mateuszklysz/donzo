#!/bin/sh
# Prepares the Kanzo data folder for a container, then runs kanzo.
#
# Kanzo only listens on 127.0.0.1 unless config.toml says otherwise, and has no
# environment variable for it, so the first start writes a config.toml that
# listens on all interfaces. An existing config.toml is never overwritten.
set -eu
# The board's database, images and config are readable by the kanzo user only.
umask 077

KANZO_HOME="${KANZO_HOME:-/data}"
KANZO_PORT="${KANZO_PORT:-4242}"
KANZO_MCP_HTTP="${KANZO_MCP_HTTP:-true}"
CONFIG="$KANZO_HOME/config.toml"

log() { echo "docker-entrypoint: $*" >&2; }

case "$KANZO_PORT" in
  ''|*[!0-9]*) log "KANZO_PORT must be a number, got '$KANZO_PORT'"; exit 64 ;;
esac
case "$KANZO_MCP_HTTP" in
  true|false) ;;
  *) log "KANZO_MCP_HTTP must be true or false, got '$KANZO_MCP_HTTP'"; exit 64 ;;
esac

if [ ! -w "$KANZO_HOME" ]; then
  log "$KANZO_HOME is not writable by uid $(id -u); chown the volume to $(id -u):$(id -g)"
  exit 73
fi

if [ ! -e "$CONFIG" ]; then
  log "creating $CONFIG (listen 0.0.0.0, port $KANZO_PORT)"
  cat > "$CONFIG" <<EOF
# Kanzo settings, written by the container on first start.
# There are no logins: anyone who reaches this port can read and change the board.
# Keep it behind the reverse proxy with authentication; never publish it directly.
port = $KANZO_PORT
listen = "0.0.0.0"
mcp_http = $KANZO_MCP_HTTP
EOF
elif grep -Eq '^[[:space:]]*listen[[:space:]]*=[[:space:]]*"(127\.0\.0\.1|::1)"' "$CONFIG"; then
  log "WARNING: $CONFIG has listen on loopback; the board is unreachable from outside the container"
fi

# `docker run image --flag` → kanzo --flag
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
  set -- kanzo "$@"
fi

# The board in a container never opens a browser, and always uses KANZO_PORT.
if [ "$1" = "kanzo" ] && { [ "$#" -eq 1 ] || [ "${2#-}" != "$2" ]; }; then
  shift
  set -- kanzo --no-open --port "$KANZO_PORT" "$@"
fi

exec "$@"
