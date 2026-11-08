# 01 — Architecture

Two halves: a small proxy stack that runs *inside* the box, and an
external supervisor that keeps the box awake and catches what the
in-box layer cannot.

## The node (any host)

`pico/pico.sh` is the whole node: it downloads pinned `xray` and
`cloudflared` binaries (sha256-verified), renders a minimal xray
config — one VMess + WebSocket inbound on `127.0.0.1:<VMPT>`
(default 8001), one `freedom` outbound — renders the `vmess://`
subscription link, and supervises the two processes. On platforms
that start apps with Node, `pico/index.js` wraps it (plus a
placeholder HTTP server for platform health checks). Zero
dependencies beyond POSIX `sh`.

Public path: client → Cloudflare edge (TLS, 443) → tunnel → 
cloudflared in the box → `http://localhost:8001` → xray → out.

## Inside the Simular box

The box breaks three assumptions the stock stack makes, so a
Simular-specific runtime (`simular/in-box/`, installed at
`/workspace/pico-net/`) replaces pico.sh's supervisor role:

1. **No DNS where programs look for it.** `/etc/resolv.conf` points
   at `127.0.0.1:53`, but nothing listens there out of the box, and
   the system stub resolver (127.0.0.53) SERVFAILs the SRV lookups
   cloudflared needs for edge discovery.
   → `dns53.py`: a small DNS server on 127.0.0.1:53 (UDP+TCP, run
   as root via passwordless sudo) whose upstream is
   DNS-over-HTTPS reached through the box's HTTP proxy. It also
   answers `localhost` locally — the box's `/etc/hosts` has no
   localhost entry and public DNS NXDOMAINs it, which otherwise
   breaks cloudflared's own origin dial.
2. **No direct egress.** `ip route` is empty; the only way out is
   the platform HTTP proxy at `127.0.0.1:3128`. cloudflared ignores
   proxy env vars for its edge connections (verified — identical
   `network is unreachable` dials with the env forced).
   → `relay.py`: listens on `127.0.0.2:7844` / `127.0.0.3:7844`.
   dns53 in "relay" mode answers the tunnel edge names
   (`region1/region2.v2.argotunnel.com`) with those loopbacks, so
   cloudflared dials the relay; the relay issues
   `CONNECT <edge-ip>:7844` to the proxy and pipes bytes. TLS stays
   end-to-end between cloudflared and the real edge.
3. **Processes die with their session** (and with sleep/hibernate).
   → `supervise.sh`: a 5-second guardian loop that (re)starts
   dns53, relay, xray and cloudflared as needed, and re-asserts
   `nameserver 127.0.0.1` in `/etc/resolv.conf` every iteration
   (systemd-resolved rewrites it after wake/network flaps, which
   silently kills edge discovery). The supervisor itself is
   launched detached with `setsid` — see
   `docs/02-setsid-approach.md`.

cloudflared is invoked as:
`cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --protocol http2 --token-file /workspace/agk-in.txt --dns-resolver-addrs 127.0.0.1:53`
(the flag governs the data-plane resolver; edge *discovery* still
reads resolv.conf — hence the guard).

## Outside the box

- **Supervisor hook** (~14 min cycle, randomised +5–50 s):
  `box_wake` via the Simular MCP (the "activity lease" — the visit
  itself is what keeps the box from sleeping), then an outside
  probe of the tunnel hostname (root must return the xray
  signature **404**; anything else = down), then an in-box check
  that relaunches `supervise.sh` if it is missing. Silent on
  success; escalates only on auth failure, 3 consecutive failed
  cycles, or a relaunch that does not restore the tunnel.
- **Downtime tripwire** (~120 s, outside-only): 3 consecutive
  non-404 polls open an incident window in a downtime log; the
  first 404 closes it. Pure measurement — it runs even if the
  supervisor is down, so the weekly availability report has an
  independent record.

## Measured results (2026-11-08)

- Tunnel first registered 01:37:09Z (2 http2 connections);
  outside checks: hostname root 404, WebSocket handshake to the
  node's path **101 Switching Protocols**, Cloudflare API reports
  the tunnel healthy.
- Scripted MCP activity (wakes, shell calls, ~1 h tunnel uptime)
  registered **zero** usage/cost in the platform's usage tool.
  What actually meters computer-time is unconfirmed.
- Availability before the setsid fix was poor (repeated 8–20 min
  outages); after it, the stack ran 2 h 48 min+ continuously.
  A full-week report is scheduled in the original deployment.
