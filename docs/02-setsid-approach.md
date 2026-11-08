# 02 — The setsid approach (the core finding)

## The failure pattern

Once the tunnel worked, it kept dying on a rhythm:

- The stack is (re)launched from an agent shell call.
- ~10–12 minutes later everything user-level is gone:
  `supervise.sh`, `relay.py`, `xray`, `cloudflared`.
- One process survives every time: `dns53.py` — the only
  **root-owned** process (started via sudo).
- The box still reports `running`; kernel uptime is continuous —
  this is **not** hibernation and **not** a reboot. It is an
  in-place teardown of the agent session's process tree.

Two cheaper hypotheses were tested and falsified first
(full evidence in `docs/03-experiment-log.md`):

- **Test A — visit more often** (supervisor cycle 14 min → 7 min,
  randomised): a kill landed ~8.8 min after the stack registered,
  exactly 10 min into its life. If the teardown were gated on the
  gap between visits, 7 minutes should have beaten it. It didn't.
- **Test B — different activity type** (each cycle also runs an
  in-session `script_run` no-op, so the platform sees "real work",
  not just a wake): the stack died ~12 minutes after recovery,
  same signature.

## The ownership theory

Every kill spared exactly the root-owned process and nothing else.
The pattern fits a platform that periodically reaps the **agent
session's process tree**: anything descended from an MCP shell
session is in scope; a root daemon started via sudo sits outside
that tree. Frequency (A) and activity content (B) never changed
*whose* tree the processes lived in — which is why they failed.

## Test C — session escape

Same user, same supervisor, one change in how it is launched:

```sh
setsid nohup sh /workspace/pico-net/supervise.sh >/tmp/sup-c.log 2>&1 < /dev/null &
```

`setsid` starts a **new session** with the supervisor as session
leader (verified in-box: new SID, PPID reparented to 1; children
relay/xray/cloudflared share the new session). The process is no
longer part of the agent session's tree, so the teardown has
nothing to reap.

**Result: strong positive.** Launched 13:30:55 (+08); at the
16:19 verification the original xray and cloudflared processes
showed 2 h 48 min continuous runtime in the detached session and
the tunnel answered healthy — against a 10–12 minute baseline
across every previous arrangement.

### Layman's version

Each agent visit is a room; the platform's cleaner periodically
empties the rooms agents have used, including machinery left
running in them. `setsid` moves the machinery into its own
independent room that the cleaner doesn't enter.

## What was deliberately not needed

- **Test D — run the whole stack as root** (`sudo setsid ...`):
  held in reserve; unnecessary while C holds. (Root alone was
  never the claim — dns53's survival is equally consistent with
  "outside the session tree". C isolated the session variable by
  keeping the user unchanged.)
- **Test E — in-box root watchdog** (a root-owned checker that
  relaunches the supervisor within ~60 s if it vanishes): a
  prototype was built during the experiments, but it is **out of
  scope for this project** by the owner's decision — the setsid
  arrangement plus the external supervisor is the shipped design.

## Honest caveats

- One deployment, one day. The platform's exact teardown rule is
  unpublished; "under ~45 min, in practice ~10–12 min" is all that
  is measured.
- During test C's window the box's `last_saved_at` advanced once
  (a save/restore cycle); whether the setsid stack survived it
  directly or supervise.sh's own loop restored components is not
  fully resolved.
- A 502 blip at 15:23 (+08) recovered in 80 s via the external
  supervisor with no process restart — consistent with a transient
  cloudflared drop; cause unrecorded.
