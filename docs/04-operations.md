# 04 — Operations runbook

## Liveness signatures (memorise these; they are counterintuitive)

- Tunnel hostname root returns **404** = healthy. The xray
  signature: the ingress catch-all and xray both answer 404 to a
  bare GET /. **404 is success.**
- WebSocket handshake to the node path returns **101**.
- **530** = tunnel not connected (no live cloudflared).
- **502** = tunnel connected, origin unreachable (stack down
  inside a running box, or origin resolution broken).
- cloudflared metrics inside the box: `127.0.0.1:20241/ready`
  should report `readyConnections: 2`.

## Bring-up (in the box)

1. Install `pico/` somewhere (e.g. `/workspace/tunnel-pico-bot`)
   and run it once with your env (`UUID`, `AGN`, `AGK` empty for
   this step) so it downloads the pinned binaries and renders
   `~/.tunnel-pico/config.json`; or render the config by hand
   (the template is in `pico.sh`).
2. Copy `simular/in-box/*` to `/workspace/pico-net/`.
3. `/etc/hosts`: add `127.0.0.1 localhost` and `::1 localhost` if
   missing (this box ships without them).
4. Put the tunnel token, byte-exact, at `/workspace/agk-in.txt`.
5. Launch the supervisor **detached**:
   `setsid nohup sh /workspace/pico-net/supervise.sh >/tmp/sup.log 2>&1 < /dev/null &`
   Verify: `ps -eo pid,ppid,sid,etime,comm` — supervisor's SID
   equals its PID, children share that SID.
6. Create the Cloudflare side (`simular/cloudflare/README.md`)
   if not already done.
7. Verify from outside: root 404, WS handshake 101, tunnel status
   healthy in the API.

## External supervision

- Supervisor hook every ~14 min: wake (capacity-retry up to 4×),
  outside probe, in-box presence check + relaunch if missing,
  75 s settle, re-probe. See
  `simular/external-hooks/README-adaptation.md`.
- Tripwire every ~120 s for measurement.
- Weekly: reconcile the downtime log — total downtime, incidents,
  longest incident, availability %, self-recovered vs
  intervention, and whether the 14-min rhythm is justified.

## Failure modes seen, and the fix for each

| Symptom | Cause | Fix |
|---|---|---|
| AGN 530, box `running`, only dns53 alive | Session teardown / sleep killed the stack | Relaunch `supervise.sh` **with setsid** (above). External supervisor does this automatically. |
| cloudflared crash-loop, log full of SRV `server misbehaving` | systemd-resolved rewrote `/etc/resolv.conf` to its 127.0.0.53 stub | `supervise.sh` re-asserts `nameserver 127.0.0.1` every 5 s; if stuck, write it once by hand via sudo. |
| AGN 502, cloudflared log: `lookup localhost … no such host` | Box `/etc/hosts` lacks localhost; dns53 didn't answer it yet | dns53 answers localhost locally (built in); also add the hosts entries. |
| `box_wake` returns "node at capacity" | Platform capacity | Retry with backoff (observed waits: ~2.5 min and ~25 min). Not an error in your stack. |
| Box state `failed` after hibernate | Wake raced capacity | Same retry path; the stack will need the relaunch check afterwards. |

## Credential hygiene

- Tunnel token: file-to-file only (`--token-file`), never in a
  command line, chat message or log. Transfer byte-exact and
  verify length + sha256 at each hop.
- Simular personal key: goes in your secret store, referenced by
  the MCP client — never in the repo.
- The VMess UUID is a credential too; keep it with the deployment,
  not in the repo.
