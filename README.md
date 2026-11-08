# simular-setsid

**A VMess + WebSocket node that survives inside a Simular Box** — an
AI-agent cloud desktop that sleeps when idle, kills its agent
sessions' process trees, and has no direct internet egress.

Built and measured on 2026-11-08 through a full day of controlled
experiments (see `docs/03-experiment-log.md`).

## TL;DR — the three discoveries

1. **The egress problem.** The box has no default route; all traffic
   must use its HTTP proxy. `cloudflared` ignores proxy env vars for
   its edge dials, so the tunnel can never connect directly. Solved
   with a local DNS server + a CONNECT relay that carries
   cloudflared's edge TCP through the proxy
   (`simular/in-box/dns53.py`, `simular/in-box/relay.py`).
2. **The kill problem.** Every ~10–12 minutes the platform tears
   down the agent session's process tree *in place* (kernel keeps
   running); anything started from an agent shell dies, supervisor
   included. Visit frequency (test A) and in-session activity type
   (test B) do **not** prevent it.
3. **The fix — session escape.** Launch the supervisor detached in
   its **own session**:
   `setsid nohup sh /workspace/pico-net/supervise.sh >/tmp/sup-c.log 2>&1 < /dev/null &`
   The platform's teardown then has nothing to reap. Measured:
   baseline lifetime 10–12 min → **2 h 48 min continuous and counting**
   at verification time, tunnel healthy throughout
   (`docs/03-experiment-log.md`, test C).

An external supervisor + downtime tripwire
(`simular/external-hooks/`) measure availability and recover the
stack when the box itself sleeps or hibernates. (A root-owned
in-box watchdog was also prototyped during the experiments; it is
**out of scope for this project** — the setsid result stands on its
own, and the external supervisor covers recovery.)

## Layout

| Path | What |
|---|---|
| `pico/` | The node stack itself — `pico.sh` (POSIX sh supervisor: pinned xray + cloudflared, renders the VMess-WS config and the `vmess://` subscription), `index.js` (Node flavor for egg panels), `unzip.js`, `start.sh`, `package.json`. Works on any host; on a normal host you need nothing else. |
| `simular/in-box/` | The Simular-specific runtime: `supervise.sh` (5-second guardian loop for the four processes + resolv.conf guard), `dns53.py` (local DNS-over-HTTPS server on 127.0.0.1:53), `relay.py` (CONNECT relay to the Cloudflare edge). |
| `simular/external-hooks/` | Outside-the-box keep-alive: `supervisor-hook.sh` (~14 min wake + probe + relaunch), `downtime-tripwire.sh` (pure measurement), `box_mcp.py` (Simular MCP client), `README-adaptation.md`. |
| `simular/cloudflare/` | What to create on the Cloudflare side (tunnel, ingress, CNAME, token handling). |
| `docs/` | `01-architecture`, `02-setsid-approach` (the core write-up), `03-experiment-log` (full evidence), `04-operations` (runbook), `05-known-limitations`. |

## Status and known limits

Experimental, single deployment, one day of data so far. Setsid
survival is verified; behaviour across box image saves/restores is
only partly understood. Tunnel control-plane health is verified
end-to-end (handshake 101); per-destination **data-plane egress
through the Simular box is still being characterised** and may
vary by destination — see `docs/05-known-limitations.md`. (On a
host with ordinary egress — e.g. the InstaBox deployment of this
same stack — that caveat does not apply.)

Secrets: none in this repo. The tunnel token, the VMess UUID and all
hostnames are deployment values and live outside the repo.

## License

MIT — see `LICENSE`.
