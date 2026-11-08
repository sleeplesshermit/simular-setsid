#!/bin/sh
# fetch-binaries.sh — populate pico/vendored/ with the pinned upstream
# binaries and verify them against the pins in pico/pico.sh.
#
# This is the ONLY network step in the project, and it is a deliberate,
# manual, pre-deployment action: run it once when preparing a deployment
# (or when bumping the pinned versions), commit the results, and every
# deployment after that is fully self-contained — the launcher never
# downloads anything at runtime.
#
# Usage:  sh tools/fetch-binaries.sh [x86_64|arm64|all]     (default: all)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/pico/vendored"
mkdir -p "$DEST"

XRAY_VER="v26.10.31"
CF_VER="2026.10.7"

dl() { # url out
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1";
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1";
  else echo "need curl or wget" >&2; exit 1; fi
}

check() { # file sha256
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$2  $1" | sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    echo "$2  $1" | shasum -a 256 -c -
  else
    echo "need sha256sum or shasum to verify pins" >&2; exit 1
  fi
}

one_arch() { # arch xzip cfbin xzip_sha cf_sha
  echo "== $1 =="
  dl "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/$2" "$DEST/$2"
  check "$DEST/$2" "$4"
  dl "https://github.com/cloudflare/cloudflared/releases/download/$CF_VER/$3" "$DEST/$3"
  check "$DEST/$3" "$5"
}

case "${1:-all}" in
  x86_64|amd64) one_arch x86_64 Xray-linux-64.zip cloudflared-linux-amd64 \
    e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214 \
    1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872 ;;
  arm64|aarch64) one_arch arm64 Xray-linux-arm64-v8a.zip cloudflared-linux-arm64 \
    1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d \
    3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775 ;;
  all)
    one_arch x86_64 Xray-linux-64.zip cloudflared-linux-amd64 \
      e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214 \
      1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872
    one_arch arm64 Xray-linux-arm64-v8a.zip cloudflared-linux-arm64 \
      1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d \
      3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775
    ;;
  *) echo "usage: $0 [x86_64|arm64|all]" >&2; exit 2 ;;
esac

echo
echo "Vendored set complete in pico/vendored/ — commit it, and deployments"
echo "from this repo need no network at install or runtime."
