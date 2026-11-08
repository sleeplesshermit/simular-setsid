#!/bin/sh
# tunnel-pico-bot — launcher + supervisor (POSIX sh, zero dependencies)
#
# Does exactly three things:
#   1. Stage the vendored pinned binaries (vendored/ next to this script)
#      into $PICO_HOME/bin — the repo ships them; there are NO runtime
#      downloads anywhere in this launcher.
#   2. Render the xray config (single VMess-WS inbound) and sub.txt.
#   3. Supervise the two processes, restarting either if it exits.
#
# Env: UUID (required), AGN (required), AGK (tunnel token; empty = no tunnel,
# local test mode), VMPT (default 8001), SUB_PATH (default "sub", only used
# for the file name sub-<SUB_PATH>.txt copy), PICO_HOME (default ~/.tunnel-pico)
set -u

PICO_HOME="${PICO_HOME:-$HOME/.tunnel-pico}"
BIN="$PICO_HOME/bin"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo .)
VMPT="${VMPT:-8001}"
SUB_PATH="${SUB_PATH:-sub}"
XRAY_VER="v26.10.31"
CF_VER="2026.10.7"

log() { printf '%s [pico] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "${UUID:-}" ] || die "UUID is not set"
[ -n "${AGN:-}" ] || die "AGN is not set"
mkdir -p "$BIN" "$PICO_HOME"

case "$(uname -m)" in
  x86_64|amd64)  XZIP="Xray-linux-64.zip";        CFBIN="cloudflared-linux-amd64"
                 XZIP_SHA="e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214";   CF_SHA="1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872" ;;
  aarch64|arm64) XZIP="Xray-linux-arm64-v8a.zip"; CFBIN="cloudflared-linux-arm64"
                 XZIP_SHA="1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d";   CF_SHA="3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775" ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac

verify() { # file sha256 — best effort: skip when no tool or no hash pinned
  [ -n "$2" ] || return 0
  case "$2" in *__*) return 0 ;; esac
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$2  $1" | sha256sum -c - >/dev/null 2>&1
  else return 0; fi
}

ensure_xray() {
  [ -x "$BIN/xray" ] && return 0
  # Vendored only: the pinned release zip ships in this repo (vendored/).
  # No runtime downloads — if the file is missing or its hash does not
  # match the pin, the launcher stops loudly instead of fetching anything.
  vend="$SELF_DIR/vendored/$XZIP"
  [ -f "$vend" ] || die "vendored xray zip missing: vendored/$XZIP (populate the repo with tools/fetch-binaries.sh)"
  verify "$vend" "$XZIP_SHA" || die "vendored xray zip sha256 mismatch"
  if command -v unzip >/dev/null 2>&1; then
    unzip -p "$vend" xray > "$BIN/xray" || die "xray extract failed (unzip)"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read("xray"))' \
      "$vend" > "$BIN/xray" || die "xray extract failed (python3)"
  elif command -v node >/dev/null 2>&1; then
    node "$SELF_DIR/unzip.js" "$vend" xray "$BIN/xray" || die "xray extract failed (node)"
  else die "need unzip, python3 or node to extract xray"; fi
  chmod +x "$BIN/xray"
  log "xray staged from vendored zip"
}

ensure_cloudflared() {
  [ -x "$BIN/cloudflared" ] && return 0
  # Vendored only, same rule as xray: ship it in the repo or stop loudly.
  vend="$SELF_DIR/vendored/$CFBIN"
  [ -f "$vend" ] || die "vendored cloudflared missing: vendored/$CFBIN (populate the repo with tools/fetch-binaries.sh)"
  verify "$vend" "$CF_SHA" || { rm -f "$BIN/cloudflared"; die "vendored cloudflared sha256 mismatch"; }
  cp "$vend" "$BIN/cloudflared" || die "cloudflared stage failed"
  chmod +x "$BIN/cloudflared"
  log "cloudflared staged from vendored binary"
}

ensure_xray
ensure_cloudflared

# --- render xray config -------------------------------------------------
cat > "$PICO_HOME/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "in",
      "listen": "127.0.0.1",
      "port": $VMPT,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$UUID", "alterId": 0 } ] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/pico" }
      }
    }
  ],
  "outbounds": [ { "tag": "out", "protocol": "freedom" } ]
}
EOF

# --- render subscription -------------------------------------------------
VMESS_JSON="{\"v\":\"2\",\"ps\":\"pico\",\"add\":\"$AGN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$AGN\",\"path\":\"/pico\",\"tls\":\"tls\",\"sni\":\"$AGN\"}"
LINK="vmess://$(printf '%s' "$VMESS_JSON" | base64 | tr -d '\n')"
printf '%s' "$LINK" | base64 | tr -d '\n' > "$PICO_HOME/sub.txt"
cp "$PICO_HOME/sub.txt" "./sub.txt" 2>/dev/null || true
{ "$BIN/xray" version 2>/dev/null | head -1;
  [ -n "${AGK:-}" ] && "$BIN/cloudflared" --version 2>/dev/null;
  echo "started $(date '+%Y-%m-%d %H:%M:%S') vmpt=$VMPT agn=$AGN";
} > "$PICO_HOME/status.txt" 2>/dev/null || true
log "config + subscription rendered (vmpt=$VMPT agn=$AGN)"

# --- supervise ------------------------------------------------------------
XPID=""; CPID=""
start_xray() { "$BIN/xray" run -config "$PICO_HOME/config.json" & XPID=$!; log "xray up (pid $XPID)"; }
start_cf()   { [ -n "${AGK:-}" ] || return 0; "$BIN/cloudflared" tunnel --no-autoupdate run --token "$AGK" & CPID=$!; log "cloudflared up (pid $CPID)"; }

cleanup() {
  [ -n "$XPID" ] && kill "$XPID" 2>/dev/null
  [ -n "$CPID" ] && kill "$CPID" 2>/dev/null
  exit 0
}
trap cleanup TERM INT

start_xray
start_cf
while :; do
  sleep 5
  if [ -n "$XPID" ] && ! kill -0 "$XPID" 2>/dev/null; then log "xray exited, restarting"; start_xray; fi
  if [ -n "$CPID" ] && ! kill -0 "$CPID" 2>/dev/null; then log "cloudflared exited, restarting"; start_cf; fi
done
