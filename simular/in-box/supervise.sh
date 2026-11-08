#!/bin/sh
# pico-net supervisor for the Simular Box pilot.
# Keeps four processes alive: dns53 (DNS on 127.0.0.1:53), relay (CONNECT
# relay on 127.0.0.2/.3:7844), xray (127.0.0.1:8001), cloudflared (tunnel
# your Cloudflare tunnel via the relay). Replaces pico.sh, whose cloudflared
# invocation has no DNS/protocol flags and cannot work in this box.
NET=/workspace/pico-net
CFD="$HOME/.tunnel-pico/bin/cloudflared"
XRAY="$HOME/.tunnel-pico/bin/xray"
CFG="$HOME/.tunnel-pico/config.json"
TOK=/workspace/agk-in.txt
log() { printf '%s [sup] %s\n' "$(date '+%F %T')" "$*" >> "$NET/supervise.log"; }
printf 'relay' > /tmp/dns53-mode
log "supervisor starting"
while :; do
  # systemd-resolved rewrites /etc/resolv.conf to its 127.0.0.53 stub after
  # wake/network flaps (2026-11-08 11:35 outage); the stub SERVFAILs SRV,
  # which kills cloudflared edge discovery. Re-assert our dns53.
  if ! grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 127.0.0.1\n' | sudo -n tee /etc/resolv.conf >/dev/null && log "resolv.conf re-asserted to 127.0.0.1"
  fi
  if ! pgrep -f 'pico-net/dns53.py' >/dev/null; then
    sudo -n nohup python3 "$NET/dns53.py" >> "$NET/dns53.log" 2>&1 &
    log "dns53 started"
  fi
  if ! pgrep -f 'pico-net/relay.py' >/dev/null; then
    nohup python3 "$NET/relay.py" >> "$NET/relay.log" 2>&1 &
    log "relay started"
  fi
  if ! pgrep -x xray >/dev/null; then
    nohup "$XRAY" run -config "$CFG" >> "$NET/xray.log" 2>&1 &
    log "xray started"
  fi
  if ! pgrep -f 'cloudflared tunnel' >/dev/null; then
    nohup "$CFD" tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --protocol http2 --token-file "$TOK" --dns-resolver-addrs 127.0.0.1:53 >> "$NET/cloudflared.log" 2>&1 &
    log "cloudflared started"
  fi
  sleep 5
done
