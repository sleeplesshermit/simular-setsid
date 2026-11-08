# Adapting the external hooks

`supervisor-hook.sh` and `downtime-tripwire.sh` are production
scripts from a Muse hook runtime. They are included verbatim
(except the AGN value) as **reference implementations**. To reuse:

- Replace `<AGN>` with your tunnel hostname in both scripts.
- The supervisor drives the box through `box_mcp.py` (included), a
  small MCP client for `https://mcp.box.simular.ai/mcp`. It expects
  an `hsurr:` credential surrogate provided by the Muse runtime —
  outside that runtime, replace the credential plumbing with a
  bearer header carrying your own Simular personal key
  (`Authorization: Bearer cb_...`). Never commit the key.
- Scheduling: the supervisor script self-gates via a state file
  (60 s poll, ~14 min effective cycle); the tripwire is a plain
  ~120 s poll. Any scheduler (cron, systemd timer, a hook runtime)
  that runs them frequently works.
- Both append incidents to a downtime log; point `DTLOG` at your
  own file.
- `ALLOWED_TOOLS` in box_mcp.py is a deliberate allowlist
  (box_wake, box_status, box_list, shell, box_hibernate, usage,
  billing, script_run). Keep it that way.
