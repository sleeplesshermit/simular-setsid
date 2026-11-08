# In-box runtime (installs at /workspace/pico-net/)

- `supervise.sh` — 5-second guardian: keeps dns53 / relay / xray /
  cloudflared alive, re-asserts resolv.conf. **Launch it with
  setsid** (docs/02-setsid-approach.md):
  `setsid nohup sh /workspace/pico-net/supervise.sh >/tmp/sup.log 2>&1 < /dev/null &`
- `dns53.py` — DNS server on 127.0.0.1:53 (UDP+TCP), upstream
  DNS-over-HTTPS via the box proxy (127.0.0.1:3128, hardcoded —
  it runs under sudo and must not depend on inherited env).
  Mode file `/tmp/dns53-mode`: `relay` (region names → loopback
  relay) or anything else (real DoH answers). supervise.sh
  writes `relay` at start.
- `relay.py` — CONNECT relay: 127.0.0.2/.3:7844 → box proxy →
  Cloudflare edge IPs :7844 (pools in the file; they are
  Cloudflare's published argotunnel edge addresses).

Paths inside the scripts (binary locations, token file) match the
original deployment: binaries at `~/.tunnel-pico/bin/`, xray
config at `~/.tunnel-pico/config.json`, token file at
`/workspace/agk-in.txt`. Adjust consistently if you move them.
