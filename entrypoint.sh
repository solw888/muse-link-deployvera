#!/bin/bash
# Entrypoint for the Muse Link bridge on DeployVera (free plan test).
#
# Order of operations:
#   1. Validate MUSE_LINK_API_TOKEN (required; set in the DeployVera panel).
#      A fresh random token for THIS test bridge only — do NOT reuse the local
#      bridge's token. The parent agent generates it and keeps it.
#   2. Create/patch the bridge config (init defaults, then override the token,
#      state_dir and media_roots). The bridge listen host stays 127.0.0.1
#      (its config validation rejects anything else); the proxy is the public
#      front door on 0.0.0.0:$PORT.
#   3. Start the proxy (background) so /qr is available during login.
#   4. If not logged in to WeChat, run `muse-link login` in a retry loop.
#      The QR PNG is written to $QR_DIR and served by the proxy at /qr.
#      The user scans it with WeChat. Each attempt lasts up to 10 minutes;
#      a fresh QR is generated every few minutes inside an attempt.
#   5. Start the bridge daemon (`muse-link run`) and wait for /healthz.
#   6. Wait for the first child to exit; if the daemon dies, exit so the
#      container restarts. Forward SIGTERM/SIGINT to both children.
#
# State (WeChat login + SQLite) lives in $STATE_DIR inside the writable
# container layer. DeployVera documents NO persistent volume for a Dockerfile
# app on the free plan, so a container replacement (redeploy/restart) MAY wipe
# the login. That is expected for this test; re-login via /qr is the recovery.
# Do NOT copy the local bridge's state/config into this container.

set -u

BRIDGE_DIR="${MUSE_LINK_HOME:-/app/muse-link}"
CONFIG="${MUSE_LINK_CONFIG:-/data/config/config.json}"
STATE_DIR="${MUSE_LINK_STATE_DIR:-/data/state}"
QR_DIR="${MUSE_LINK_QR_DIR:-/data/qr}"
MEDIA_ROOT="${MUSE_LINK_MEDIA_ROOT:-/data/workspace}"
PORT="${PORT:-3000}"
TOKEN="${MUSE_LINK_API_TOKEN:-}"
CLI="node $BRIDGE_DIR/src/cli.mjs"

log() { printf '[%s] [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# --- 1. token -------------------------------------------------------------
# Trim any whitespace the platform may have added when injecting the variable
# (e.g. a trailing newline). A valid token has no whitespace at all.
# Log only the length, never the value.
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
log "MUSE_LINK_API_TOKEN length after trim: ${#TOKEN}"
if [ -z "$TOKEN" ]; then
  die "MUSE_LINK_API_TOKEN is not set. Generate a random token (32-256 printable ASCII chars, no spaces) and set it as an environment variable in the DeployVera panel. Do NOT commit it to the repo."
fi
if [ "${#TOKEN}" -lt 32 ] || [ "${#TOKEN}" -gt 256 ]; then
  die "MUSE_LINK_API_TOKEN must be 32-256 characters (got ${#TOKEN})."
fi
if ! [[ "$TOKEN" =~ ^[!-~]+$ ]]; then
  die "MUSE_LINK_API_TOKEN must be printable ASCII without spaces (length ${#TOKEN})."
fi

# --- 2. runtime dirs + config ----------------------------------------------
mkdir -p "$STATE_DIR" "$QR_DIR" "$MEDIA_ROOT" "$(dirname "$CONFIG")"
chmod 0700 "$STATE_DIR" "$QR_DIR" "$(dirname "$CONFIG")" 2>/dev/null || true

if [ ! -f "$CONFIG" ]; then
  log "creating bridge config at $CONFIG"
  $CLI init --config "$CONFIG" >/dev/null || die "muse-link init failed"
fi

# Override token / state_dir / media_roots on top of the init defaults.
# (Keeps the bridge's own default timeouts and operations block intact.)
MUSE_LINK_CONFIG="$CONFIG" \
MUSE_LINK_API_TOKEN="$TOKEN" \
MUSE_LINK_STATE_DIR="$STATE_DIR" \
MUSE_LINK_MEDIA_ROOT="$MEDIA_ROOT" \
node -e '
  const fs = require("fs");
  const p = process.env.MUSE_LINK_CONFIG;
  const c = JSON.parse(fs.readFileSync(p, "utf8"));
  c.api_token = process.env.MUSE_LINK_API_TOKEN;
  c.state_dir = process.env.MUSE_LINK_STATE_DIR;
  c.media_roots = [process.env.MUSE_LINK_MEDIA_ROOT];
  // listen must stay loopback; the proxy is the public front door.
  c.listen = { host: "127.0.0.1", port: 18791 };
  fs.writeFileSync(p, JSON.stringify(c, null, 2) + "\n", { mode: 0o600 });
' || die "failed to write bridge config"
chmod 0600 "$CONFIG"
log "bridge config ready at $CONFIG"

# --- 3. proxy (background) -------------------------------------------------
log "starting proxy on 0.0.0.0:$PORT (bridge API at 127.0.0.1:18791)"
PORT="$PORT" MUSE_LINK_QR_DIR="$QR_DIR" MUSE_LINK_API_TOKEN="$TOKEN" node /app/proxy.mjs &
PROXY_PID=$!

# --- helpers ---------------------------------------------------------------
is_logged_in() {
  # `status` prints one compact JSON line; logged_in is a top-level boolean.
  # A failed status call (no store yet) counts as "not logged in".
  $CLI status --config "$CONFIG" 2>/dev/null | grep -q '"logged_in": *true'
}

# --- 4. login loop (only when not already logged in) -----------------------
attempt=1
max_attempts=6
while ! is_logged_in; do
  if [ "$attempt" -gt "$max_attempts" ]; then
    log "login did not succeed after $max_attempts attempts; exiting so the container restarts with a fresh QR"
    kill "$PROXY_PID" 2>/dev/null
    exit 1
  fi
  log "not logged in to WeChat (attempt $attempt/$max_attempts) — open the app URL + /qr in a browser and scan the code with WeChat"
  # Blocks until scanned, expired, or --timeout (10m). A fresh QR is written
  # every few minutes inside one attempt; the proxy always serves the latest.
  if $CLI login --config "$CONFIG" --qr-dir "$QR_DIR" --timeout 10m; then
    log "login command finished; re-checking login status"
  else
    log "login attempt $attempt ended without a confirmed login (timeout or error); will retry"
  fi
  attempt=$((attempt + 1))
  sleep 3
done
log "logged in to WeChat"

# --- 5. bridge daemon (background) ------------------------------------------
log "starting bridge daemon (node src/cli.mjs run)"
$CLI run --config "$CONFIG" &
DAEMON_PID=$!

# Wait for the daemon's unauthenticated liveness endpoint.
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:18791/healthz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    log "bridge daemon exited during startup; see its logs above"
    kill "$PROXY_PID" 2>/dev/null
    exit 1
  fi
  sleep 2
done
if [ "$healthy" -ne 1 ]; then
  log "bridge daemon did not become healthy within ~2 minutes"
  kill "$PROXY_PID" "$DAEMON_PID" 2>/dev/null
  exit 1
fi
log "bridge daemon is up; public URL is the DeployVera app address (proxy :$PORT), QR at /qr, health at /healthz, API under /v1/* (Bearer token required)"

# --- 6. supervise -----------------------------------------------------------
shutdown() {
  log "shutting down (signal received)"
  kill -TERM "$DAEMON_PID" "$PROXY_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  wait "$PROXY_PID" 2>/dev/null
  exit 0
}
trap shutdown TERM INT

# Wait for the first child to exit. If the daemon dies, exit so the container
# restarts; if the proxy dies, the public front door is gone, so exit too.
wait -n "$DAEMON_PID" "$PROXY_PID"
code=$?
log "a child process exited (code $code); shutting down the other and exiting"
kill "$DAEMON_PID" "$PROXY_PID" 2>/dev/null
wait 2>/dev/null
exit "$code"
