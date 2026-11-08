#!/usr/bin/env bash
# Simular Box supervisor: keep Jerry's pico node on box "main" alive.
# The box sleeps when idle, and both hibernation and idle sleep kill the
# user-level pico stack (relay/xray/cloudflared under
# /workspace/pico-net/supervise.sh) while the box may still report
# "running". This hook runs a cycle every ~14 min: box_wake (the
# activity lease) -> outside AGN probe (root 404 = xray alive) -> in-box
# supervise.sh check, relaunching it if missing.
#
# Timing is gated here via a state file (hook polls every 60 s): each
# completed cycle schedules the next at now + BASE_INTERVAL s + a fresh
# random offset of 5-50 s (Jerry's spec; BASE_INTERVAL set below).
# Silent on success, including routine
# recoveries; wakes an agent only on MCP auth failure, 3 consecutive
# failed cycles, or a relaunch that does not restore the tunnel.
# Incidents (AGN not 404 at cycle time) are appended to
# ~/workspace/box-simular/downtime-log.md for the weekly report.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

MCP="$HOME/workspace/custom-connectors/custom.simular-box/bin/box_mcp.py"
AGN="https://<AGN>/"  # your tunnel hostname, e.g. https://cf-tunnel-example.example.org/
STATE_DIR="$HOME/hooks/state"
STATE_FILE="$STATE_DIR/simular-box-supervisor.state"
DTLOG="$HOME/workspace/box-simular/downtime-log.md"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
mkdir -p "$STATE_DIR"

now=$(date +%s)

# --- state: one line "next_due_epoch consecutive_fails"
next_due=0
fails=0
if [ -f "$STATE_FILE" ]; then
  read -r next_due fails < "$STATE_FILE" || true
  case "${next_due:-}" in ''|*[!0-9]*) next_due=0 ;; esac
  case "${fails:-}" in ''|*[!0-9]*) fails=0 ;; esac
fi

save_state() { # $1=next_due $2=fails
  [ "$DRY" = "1" ] && return 0
  printf '%s %s' "$1" "$2" > "$STATE_FILE"
}

BASE_INTERVAL=840  # Test B from 2026-11-08 (Jerry-approved): standing 14-min cycles + per-cycle script_run activity call (see phase 1b)
schedule_next() { # prints epoch: now + BASE_INTERVAL + random 5..50
  echo $(( $(date +%s) + BASE_INTERVAL + 5 + RANDOM % 46 ))
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

probe_agn() { # prints HTTP code of AGN root (000 on transport failure)
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$AGN" 2>/dev/null || echo 000
}

ARGS_DIR=$(mktemp -d)
trap 'rm -rf "$ARGS_DIR"' EXIT
printf '{}' > "$ARGS_DIR/wake.json"
python3 - "$ARGS_DIR/shell.json" <<'PYEOF'
import json, sys
cmd = (
    "if pgrep -f 'pico-net/supervise.sh' >/dev/null 2>&1; then "
    "echo SUPERVISOR_PRESENT; "
    "else nohup sh /workspace/pico-net/supervise.sh >/dev/null 2>&1 & "
    "echo SUPERVISOR_RELAUNCHED; fi; "
    "sleep 2; "
    "echo SUP_COUNT=$(pgrep -fc 'pico-net/supervise[.]sh' || true); "
    "echo CFD_COUNT=$(pgrep -fc '[c]loudflared' || true); "
    "echo RELAY_COUNT=$(pgrep -fc 'pico-net/relay[.]py' || true); "
    "echo XRAY_COUNT=$(pgrep -fc '[x]ray' || true)"
)
with open(sys.argv[1], "w") as fh:
    json.dump({"command": cmd, "timeout_s": 120}, fh)
PYEOF

mcp() { # $1=tool $2=argsfile ; echoes combined output; rc in $MCP_RC
  MCP_RC=0
  MCP_OUT=$(python3 "$MCP" call-tool --name "$1" --arguments-file "$2" 2>&1) || MCP_RC=$?
}

record_incident() { # $1=down_epoch $2=recovered_epoch|OPEN $3=note
  [ "$DRY" = "1" ] && return 0
  local down_iso rec_iso dur
  down_iso=$(iso "$1")
  if [ "$2" = "OPEN" ]; then
    rec_iso="OPEN"; dur="-"
  else
    rec_iso=$(iso "$2"); dur=$(( $2 - $1 ))
  fi
  printf -- '- [supervisor] down_detected: %s | recovered: %s | duration_s: %s | note: %s\n' \
    "$down_iso" "$rec_iso" "$dur" "$3" >> "$DTLOG"
}

# --- gate
if [ "$now" -lt "$next_due" ]; then
  silent "not due (next cycle at $(iso "$next_due"))" '{}'
  exit 0
fi

# --- dry run: read-only decision path only (no wake, no relaunch,
#     no state writes, no downtime-log writes)
if [ "$DRY" = "1" ]; then
  code=$(probe_agn)
  mcp box_status "$ARGS_DIR/wake.json"
  log "observation" "{\"dryRun\":true,\"agnHttp\":$code,\"boxStatusRc\":$MCP_RC}"
  silent "dry run: cycle due; AGN=$code; box_status rc=$MCP_RC (read-only, nothing woken or relaunched)" '{}'
  exit 0
fi

# --- phase 1: wake the box (activity lease), retrying on capacity
wake_ok=0
capacity_seen=0
attempt=0
while [ "$attempt" -lt 4 ]; do
  attempt=$((attempt + 1))
  mcp box_wake "$ARGS_DIR/wake.json"
  if printf '%s' "$MCP_OUT" | grep -qi 'HTTP 401\|HTTP 403'; then
    log "observation" '{"wake":"auth_failed"}'
    save_state "$(schedule_next)" "$fails"
    wake "simular_supervisor_auth_failed" '{"detail":"box_wake returned HTTP 401/403; MCP credential likely rejected"}'
    exit 0
  fi
  if [ "$MCP_RC" = "0" ]; then
    wake_ok=1
    break
  fi
  if printf '%s' "$MCP_OUT" | grep -qi 'capacity'; then
    capacity_seen=1
  fi
  [ "$attempt" -lt 4 ] && sleep 15
done

if [ "$wake_ok" != "1" ]; then
  fails=$((fails + 1))
  save_state "$(schedule_next)" "$fails"
  log "observation" "{\"wake\":\"failed\",\"attempts\":$attempt,\"capacity\":$capacity_seen,\"consecutiveFailures\":$fails}"
  if [ "$fails" -ge 3 ]; then
    wake "simular_supervisor_failing" "{\"consecutiveFailures\":$fails,\"phase\":\"box_wake\",\"capacity\":$capacity_seen}"
  else
    silent "box_wake failed ($fails in a row), watching" '{}'
  fi
  exit 0
fi

# --- phase 1b (test B): one best-effort in-session activity call —
#     a script_run no-op, so the platform sees real session work, not
#     just a wake ping. Its outcome is logged only: it must never
#     change the cycle result, relaunch logic, or failure counting.
printf '%s' '{"code": "export async function main() { return { ping: true }; }", "screenshot": false, "timeout_s": 30}' > "$ARGS_DIR/activity.json"
mcp script_run "$ARGS_DIR/activity.json"
if [ "$MCP_RC" = "0" ]; then
  log "observation" '{"activityB":"script_run","ok":true}'
else
  b_err=$(printf '%s' "$MCP_OUT" | head -c 200 | tr -d '"\\' | tr '\n' ' ')
  log "observation" "{\"activityB\":\"script_run\",\"ok\":false,\"rc\":$MCP_RC,\"err\":\"$b_err\"}"
fi

# --- phase 2: liveness. Outside probe first, then the in-box
#     check/relaunch (one shell call: relaunches supervise.sh if absent)
t_probe=$(date +%s)
code1=$(probe_agn)
mcp shell "$ARGS_DIR/shell.json"
shell_rc=$MCP_RC
relaunched=0
printf '%s' "$MCP_OUT" | grep -q 'SUPERVISOR_RELAUNCHED' && relaunched=1

if [ "$code1" = "404" ] && [ "$relaunched" = "0" ] && [ "$shell_rc" = "0" ]; then
  save_state "$(schedule_next)" 0
  log "observation" '{"cycle":"ok","agnHttp":404}'
  silent "cycle ok: box awake, stack alive (AGN 404)" '{}'
  exit 0
fi

# --- phase 3: something was down or missing. Give the (re)launched
#     stack time to register, then re-probe.
note="AGN=$code1 at cycle start"
[ "$relaunched" = "1" ] && note="$note; supervise.sh was missing and relaunched"
[ "$shell_rc" != "0" ] && note="$note; shell check rc=$shell_rc"
sleep 75
code2=$(probe_agn)
t_end=$(date +%s)

if [ "$code2" = "404" ]; then
  if [ "$code1" != "404" ]; then
    record_incident "$t_probe" "$t_end" "$note; recovered after relaunch/settle"
    log "observation" "{\"cycle\":\"recovered\",\"agnHttpBefore\":$code1,\"downSeconds\":$((t_end - t_probe))}"
  else
    log "observation" '{"cycle":"supervisor_relaunched_tunnel_unaffected"}'
  fi
  save_state "$(schedule_next)" 0
  silent "cycle recovered: stack relaunched/settled, AGN back to 404" '{}'
  exit 0
fi

# --- unrestored: record an open incident and wake the agent
if [ "$code1" != "404" ]; then
  record_incident "$t_probe" "OPEN" "$note; still AGN=$code2 after relaunch + 75 s"
fi
fails=$((fails + 1))
save_state "$(schedule_next)" "$fails"
log "observation" "{\"cycle\":\"restore_failed\",\"agnHttpBefore\":$code1,\"agnHttpAfter\":$code2,\"relaunched\":$relaunched,\"consecutiveFailures\":$fails}"
wake "simular_supervisor_restore_failed" "{\"agnHttpBefore\":$code1,\"agnHttpAfter\":$code2,\"relaunched\":$relaunched,\"consecutiveFailures\":$fails}"
