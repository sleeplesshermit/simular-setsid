# Simular Box pico pilot — log

Box: the account's single box. One Cloudflare tunnel, AGN =
<tunnel-hostname> → http://localhost:8001. The tunnel token is never
recorded in this log; it lives only in a token file inside the box
and in a local file on the operator's machine. (Identifiers from the
original log — box id, tunnel id, hostname, home paths — are
replaced with placeholders in this public copy; everything else is
verbatim.)

## Round 1 (2026-11-08, condensed from the round-1 report)

- Pico stack installed in /workspace/tunnel-pico-bot; xray fine
  (127.0.0.1:8001, supervisor sh pico.sh). uid 1000 `user` with working
  passwordless sudo.
- cloudflared (2026.10.7) crash-looped: DNS to 8.8.8.8/8.8.4.4 and direct
  TCP/UDP by IP all fail "network is unreachable"; ordinary HTTPS works
  only through the box's configured proxy.
- A first hibernate/wake cycle during diagnosis: box went to state
  `failed`, wake returned "node at capacity" for ~25 min before
  succeeding. Post-wake, the pico stack processes were gone (no
  auto-restart); a small DoH bridge script on TCP 127.0.0.1:2253 survived
  (later found to have a str/bytes bug — it never actually answered).

## Round 2 (2026-11-08) — network diagnosis and fix

### Usage readings (MCP `usage` tool)

- Start of round 2 and end of round 2, identical:
  today requests 0, prompt_tokens 0, completion_tokens 0, cost_micros 0;
  month all zero; daily_cap_micros 0, default_cap true,
  remaining_today_micros -1.
- Interpretation: all scripted MCP activity so far (dozens of shell calls,
  wakes, hibernates, status polls across both rounds, plus ~1 h of tunnel
  uptime) registers **zero** usage/cost in this tool. Whatever the daily
  credit cap meters, scripted MCP calls do not appear in it.

### Step 1 — network map

- Proxy env: `http_proxy=https_proxy=HTTP_PROXY=HTTPS_PROXY=
  http://127.0.0.1:3128`, `no_proxy=localhost,127.0.0.1,::1`,
  NODE_USE_ENV_PROXY=1. (Round-1 notes said 18080; the live value is
  3128.) Listeners include the proxy on 127.0.0.1:3128 and a SOCKS-like
  127.0.0.1:1080.
- /etc/resolv.conf: `nameserver 127.0.0.1` + a nonstandard `port 2253`
  line. systemd-resolved listens on 127.0.0.53:53 and 127.0.0.54:53 —
  **nothing listens on 127.0.0.1:53**, which is the exact address Go's
  resolver derives from resolv.conf (the `port` line is ignored). That
  mismatch caused every earlier "connection refused" DNS failure.
- `ip route` is empty; interfaces are only `lo` and `cbonline`
  (169.254.1.1/32 link-local). No default route — no direct egress.
- (a) System resolver: A records for region1/region2 answered from
  /etc/hosts; SRV via systemd-resolved returns SERVFAIL (rcode=2).
  No nslookup/dig in the box.
- (b) DoH via the proxy works (cloudflare-dns.com and dns.google):
  SRV `_v2-origintunneld._tcp.argotunnel.com` →
  `1 1 7844 region1.v2.argotunnel.com`, `2 1 7844 region2.v2.argotunnel.com`;
  region A pools are 10 IPs each in 198.41.192.0/24 and 198.41.200.0/24;
  the round-1 /etc/hosts entries are inside those pools.
- (c) **Proxy CONNECT test (raw socket): the proxy ACCEPTS CONNECT to
  port 7844** — `HTTP/1.1 200 Connection Established` for
  198.41.192.67:7844, 198.41.200.73:7844 and region1 hostname:7844
  (control github.com:443 also 200). Attempt C's feared blocker does
  not exist.

### DNS fix built

- New `/workspace/pico-net/dns53.py` (master copy in
  this repo, simular/in-box/): a small DNS server on 127.0.0.1:53
  UDP+TCP (run as root via sudo), upstream = DoH JSON via the proxy
  (proxy hardcoded; the process must not depend on inherited env).
  Answers SRV/A/AAAA/CNAME/etc. from DoH; region A answers switchable
  via /tmp/dns53-mode ("real" = DoH pools, "relay" = loopback, below);
  AAAA for region names is NODATA; "localhost" is answered locally
  (A 127.0.0.1, AAAA ::1) — added after the 502 diagnosis below.
- Verified: SRV and A queries to 127.0.0.1:53 (UDP+TCP) return the
  correct records; cloudflared's edge discovery then resolves both
  regions.

### Attempt A — http2 + fixed DNS, direct dial

Command form (the one that parses on 2026.10.7):
`cloudflared tunnel --no-autoupdate --loglevel debug --metrics
127.0.0.1:20241 run --protocol http2 --token-file /workspace/agk-in.txt
--dns-resolver-addrs 127.0.0.1:53`, run in the foreground (log
/tmp/cfdA-r2.log in the box).
Result: DNS fully solved (edge discovery resolved
["198.41.192.67","198.41.192.27"] and ["198.41.200.73","198.41.200.113"]),
failure isolated to the edge dial:
`ERR Unable to establish connection with Cloudflare edge error=
"DialContext error: dial tcp 198.41.200.73:7844: connect: network is
unreachable"` (same for the other IPs); precheck "TCP Connectivity
region1/region2 FAIL — HTTP/2 connection is blocked or unreachable".
cloudflared stayed alive retrying. (The features-fetch error changed
from connection-refused to "cannot unmarshal string into Go value of
type features.featuresRecord" — non-fatal; it suggests cloudflared's
HTTPS control calls do use the proxy env even though the edge dial
does not.)

### Attempt B — cloudflared with proxy env forced

Same command with `HTTPS_PROXY/https_proxy/ALL_PROXY/all_proxy=
http://127.0.0.1:3128` set explicitly on the process (log
/tmp/cfdB-r2.log). Result: **identical direct dials and identical
"network is unreachable" errors** — cloudflared 2026.10.7 ignores
proxy environment variables for edge connections. Evidence is the
DialContext errors naming the raw edge IPs while the proxy env was
set.

### Working arrangement — local CONNECT relay (built on C)

cloudflared cannot speak HTTP proxy, so its edge TCP is carried by a
small relay (`/workspace/pico-net/relay.py`, master in
this repo, simular/in-box/):

- dns53 in "relay" mode + /etc/hosts map region1 → 127.0.0.2,
  region2 → 127.0.0.3 (backup /etc/hosts.bak-r2; cfd-features line
  kept).
- relay.py listens on 127.0.0.2:7844 (region1 IP pool) and
  127.0.0.3:7844 (region2 pool); per connection it issues
  `CONNECT <edge-ip>:7844` to 127.0.0.1:3128 and pipes bytes. TLS
  stays end-to-end (cloudflared ↔ real edge); the relay sees only
  ciphertext.
- All four processes are kept alive by
  `/workspace/pico-net/supervise.sh` (dns53, relay, xray,
  cloudflared), launched detached with nohup. **Change vs. stock
  pico:** pico.sh is not used — its cloudflared invocation
  (`tunnel run --token`, no DNS/protocol flags) cannot work in this
  box; supervise.sh replaces it and runs xray directly from the
  existing ~/.tunnel-pico/config.json and cloudflared with
  `--protocol http2 --token-file /workspace/agk-in.txt
  --dns-resolver-addrs 127.0.0.1:53 --metrics 127.0.0.1:20241`.

First success 2026-11-08T01:37:09Z:
`INF Registered tunnel connection connIndex=0 … ip=127.0.0.2
location=ord10 protocol=http2` and connIndex=1 via 127.0.0.3
(ord11); metrics /ready = {"status":200,"readyConnections":2}.

### 502 diagnosis (origin localhost)

First outside check returned CF 502, not 404. cloudflared log:
`Unable to reach the origin service … dial tcp: lookup localhost on
127.0.0.1:53: no such host … originService=http://localhost:8001`.
The box's /etc/hosts had **no localhost entry at all**, and public DNS
NXDOMAINs "localhost", so cloudflared (which resolves via 127.0.0.1:53)
could not resolve its own origin. Fixes: dns53 answers localhost
locally (above) and `127.0.0.1 localhost` / `::1 localhost` were added
to /etc/hosts.

### Outside verification (from the VM, after the fix)

- AGN root: **HTTP 404** (xray signature) ✓
- WS handshake to /pico: **HTTP/1.1 101 Switching Protocols** with a
  valid Sec-Websocket-Accept ✓
- Cloudflare API: tunnel <tunnel-name> status **healthy**,
  connections_summary has 2 live connections (ord10, ord11, opened
  2026-11-08T01:37:09Z, client 2026.10.7) ✓

### Hibernation test (tunnel up)

- 01:40:19Z box_hibernate → state `hibernated` immediately.
- Wake from ~01:42Z: state flipped to `failed`; box_wake returned
  "Ensure failed: node at capacity, try again shortly" twice;
  succeeded on retry 3 at ~01:46:34Z (state running). Capacity delay
  this cycle ≈ 2.5 min (vs ~25 min in the earlier cycle — variable).
- Post-wake process check: **dns53 (root, sudo-started) survived**;
  relay, xray, cloudflared and supervise.sh were all dead. All files
  persisted (/workspace/pico-net/*, /workspace/agk-in.txt intact).
  While down, AGN returned 502.
- Restart once: relaunched supervise.sh via shell → it adopted the
  surviving dns53 and restarted relay/xray/cloudflared; tunnel
  re-registered at 01:48:47Z (both connections); outside re-check:
  AGN 404 ✓, WS /pico 101 ✓.
- **Conclusion: the supervisor hook needs restart-duty** — after every
  wake it must (1) box_wake with capacity retries, then (2) shell-run
  `pgrep -f pico-net/supervise.sh || nohup sh
  /workspace/pico-net/supervise.sh …`. Process survival across
  hibernation is partial and unreliable (only the root dns53 made it
  this time; the round-1 bridge made it last time) — do not rely on
  any process surviving.

### State left running in the box

- supervise.sh (pid-recorded in /workspace/pico-net/supervise.log)
  supervising: dns53.py on 127.0.0.1:53 (root), relay.py on
  127.0.0.2/.3:7844, xray on 127.0.0.1:8001, cloudflared (2 registered
  http2 connections via the relay). Tunnel healthy; AGN 404; WS 101.
- /etc/hosts: region1/region2 → loopback relay, localhost lines added,
  cfd-features kept; backup at /etc/hosts.bak-r2.
- /tmp/dns53-mode contains "relay" (supervise.sh rewrites it at
  start). dns53/relay/supervise masters also kept in
  this repo, simular/in-box/ on the VM.
- The round-1 DoH bridge (TCP 127.0.0.1:2253, buggy) is still running
  but unused by this arrangement.
- Operational wart: one SRV lookup timed out once during the first
  registration (dns53 DoH latency); cloudflared retried and
  registered seconds later. dns53 answers are only as fast as the
  DoH RTT through the proxy (~1–3 s typical).

### Addendum (2026-11-08 ~02:34Z) — idle sleep also kills the stack

- At a status check ~45 min after the hibernation test, the box was
  `running` but the stack was down again: only dns53 (pid 4749)
  alive; supervise.sh, relay, xray, cloudflared all gone; AGN
  returned 530. No hibernate was issued — this was ordinary idle
  sleep/session teardown sometime after 01:48Z. Same survival
  pattern as hibernation: the root dns53 persists, everything
  user-level dies.
- Recovery was the same one-step relaunch: `nohup sh
  /workspace/pico-net/supervise.sh` → tunnel re-registered 02:35:02Z
  (ord11 + ord06), /ready = 2 connections; outside re-check AGN 404
  ✓, WS /pico 101 ✓.
- Strengthened conclusion for the supervisor hook: its ~14-min
  cycle cannot rely on box_wake alone — the box may report
  `running` while the stack is dead. Every cycle must also
  shell-check `pgrep -f pico-net/supervise.sh` (and/or probe the
  AGN handshake from outside) and relaunch supervise.sh if absent.

### Addendum (2026-11-08 ~03:35–03:49Z) — resolv.conf rewrite killed cloudflared edge discovery

- Third outage of the morning (11:35:44 +08, tripwire window 839 s) was a
  NEW failure mode, not sleep-kills-stack: supervise.sh was alive and
  relaunched cloudflared every 5 s, but every launch died in edge
  discovery: `lookup _v2-origintunneld._tcp.argotunnel.com on
  127.0.0.53:53: server misbehaving`.
- Root cause: systemd-resolved rewrote /etc/resolv.conf (mtime 03:34Z)
  from `nameserver 127.0.0.1` to `nameserver 127.0.0.53`. The 127.0.0.53
  stub SERVFAILs SRV (verified: rcode=2 instantly) and even A queries.
  cloudflared's Go resolver reads resolv.conf — the
  `--dns-resolver-addrs 127.0.0.1:53` flag (confirmed passed, shown in
  the Settings log line) does NOT govern edge-discovery lookups. dns53
  on 127.0.0.1:53 was healthy the whole time (SRV rcode=0, 2 answers,
  0.55 s).
- Fix: `printf 'nameserver 127.0.0.1\n' | sudo -n tee /etc/resolv.conf`;
  supervise.sh relaunched cloudflared, DNS prechecks passed both
  regions, tunnel re-registered 03:48:06Z (2 conns), AGN 404 + WS
  /pico 101 verified from outside.
- Hardening (same day): supervise.sh now re-asserts `nameserver
  127.0.0.1` in /etc/resolv.conf on every 5 s loop iteration (via sudo
  -n tee); live-tested by deliberately breaking resolv.conf — restored
  in <8 s with cloudflared unaffected. Master copy in
  this repo, simular/in-box/supervise.sh synced.
- Supervisor-hook implication (for the hook owner, not changed here):
  the hook's relaunch-only logic cannot fix this class — it needs a
  resolv.conf/dns53-health guard, or at minimum to detect the
  cloudflared crash-loop signature (repeated `cloudflared started` in
  supervise.log with no registration) and escalate instead of waiting
  for 3 failed cycles. The in-box guard now covers it; a hook change
  is optional.

### Addendum (2026-11-08 ~04:22–04:32Z) — fourth outage: in-place session teardown, supervise.sh killed too

- New failure mode again, distinct from both sleep-kills-stack and the
  resolv.conf rewrite. Tripwire window tw-1794111823: down 04:23:43Z,
  recovered ~04:31:43Z (~480 s). The 04:22:47Z supervisor cycle found
  AGN=502, supervise.sh PRESENT (relaunched=0), still 530 after the
  75 s settle — and woke the escalation.
- Diagnosis: kernel uptime continuous 1d 17h51m (boot Fri Nov 6
  10:35:59); `last_saved_at` 02:54:39Z (10:54 +08), ~88 min before the
  kill — **no hibernate/restore happened**. dns53 (root, pid 4749,
  alive since 01:38:54Z) survived; supervise.sh, relay, xray,
  cloudflared all died within ~04:22:00–04:22:50Z (xray last served
  04:21:58, cloudflared lost both edge connections 04:22:48,
  "Connection terminated" 04:22:50, log ends). supervise.sh was alive
  at the cycle's shell check and gone by 04:27:41 — the teardown swept
  the supervisor itself, so no crash-loop and no self-recovery were
  possible. resolv.conf was NOT rewritten again (`nameserver
  127.0.0.1`, mtime 03:50:17Z; the 5 s guard is intact and logged a
  re-assert at 03:50:17Z). dns53 healthy (SRV rcode=0, 2 answers).
- **Verdict: partial in-place kill, not hibernation.** The platform
  tears down the user session/process group while the kernel keeps
  running; only root-owned dns53 survives. The kill landed ~1 s after
  the supervisor cycle's AGN probe and during its cycle.
- A/B datum: the stack registered 04:12:48Z and died 04:22:48Z —
  exactly 10 min of life — despite the 7-min supervisor cadence (prior
  cycle ended 04:13:58Z, kill ~8.8 min later). Shortening the interval
  did not prevent this kill; the teardown is not gated on the gap
  between visits, or the threshold is below 7 min.
- Fix: relaunched supervise.sh 04:30:09Z; cloudflared re-registered
  04:30:15Z (2 conns, ord06+ord08); /ready = 2; outside AGN 404 + WS
  /pico 101 verified ~04:31:40Z; all 5 processes alive at 04:32:15Z.

## Test C/D/E — ownership experiments (2026-11-08, from 13:27 +08)

Baseline: the 13:19 manual relaunch (plain user-session arrangement)
died ~13:30:44 (AGN 530 confirmed after retries; last 404 at 13:29:46).
Lifetime ≈11 min — in family with the 10–12 min pattern. Pre-check at
13:28: the doomed stack (supervise.sh pid 14259) shared session 836
with root dns53 (pid 4749) — so session-sharing alone does not protect
user processes; dns53 sits in an older process group of that session.
(In-box PID 1 = systemd; systemctl + setsid present; no crontab binary.)

### Test C — setsid, user-owned (13:30:55 +08)
Relaunched via `setsid nohup sh /workspace/pico-net/supervise.sh
>/tmp/sup-c.log 2>&1 < /dev/null &`. Verified: supervise.sh pid 14847,
PPID 14843, SID 14847 (own session, session leader; PPID is the
transient setsid parent — expect reparent to 1). Children relay/xray/
cloudflared in session 14847. BEFORE snapshot confirmed the old stack
was fully gone except root dns53. Observation in progress.

### Test C/D/E progress check (2026-11-08 16:19 +08, main-agent verification)
- The C/D/E runner subagent never filed its report (45-min deadline
  ~14:12 passed silently) and is no longer in the agent list — the
  supervision rule was breached; main agent verified state directly.
- Test C (setsid, user-owned; supervise.sh pid 14847, own session,
  started 13:30:55): **SURVIVED.** At 16:19 the xray + cloudflared
  children (pids 14856/14859, session 14847) show etime 02:48:14 —
  continuous since ~13:31, vs the 10–12 min kill baseline. AGN 404.
  Verdict: **Test C is a strong POSITIVE — session escape defeats the
  teardown.** (supervise.sh/relay/dns53 lines didn't match the ps grep
  this run; children in C's session + AGN 404 confirm the stack.)
- One incident during C's window: supervisor cycle 15:23:18 +08 found
  AGN=502, relaunched/recovered in 80 s (downtime-log). Cause
  unrecorded; consistent with a transient cloudflared drop, since C's
  children show no restart (etime continuous). Noted, not diagnosed.
- last_saved_at updated (16:18 +08) — a save/hibernate cycle occurred
  at some point; stack survived it under setsid or was restored by
  supervise.sh's own loop. Exact mechanism unconfirmed.
- Test D (root stack): NOT run — unnecessary while C holds.
- Test E (in-box root watchdog): NOT yet built. Still the right
  hardening: if the platform ever kills C's detached session, only an
  in-box root watchdog relaunches without waiting for the 14-min hook.
- Formal verdict still lands in the 2026-11-15 weekly downtime report.
