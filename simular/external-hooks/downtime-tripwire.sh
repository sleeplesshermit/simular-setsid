#!/usr/bin/env bash
# Simular AGN downtime tripwire: measurement only, never wakes an agent.
# Independent outside check of the pico node (AGN root must return the
# xray signature 404). Polls every ~120 s; 3 consecutive non-404 polls
# open an incident window in ~/workspace/box-simular/downtime-log.md,
# which is completed in place when the AGN answers 404 again. Runs even
# if the supervisor hook is down, so downtime is measured regardless.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

AGN="https://<AGN>/"  # your tunnel hostname, e.g. https://cf-tunnel-example.example.org/
STATE_DIR="$HOME/hooks/state"
STATE_FILE="$STATE_DIR/simular-agn-downtime-watch.state"
DTLOG="$HOME/workspace/box-simular/downtime-log.md"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
mkdir -p "$STATE_DIR"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# --- state: "consec_down first_fail_epoch open_id"
consec=0
first_fail=0
open_id=""
if [ -f "$STATE_FILE" ]; then
  read -r consec first_fail open_id < "$STATE_FILE" || true
  case "${consec:-}" in ''|*[!0-9]*) consec=0 ;; esac
  case "${first_fail:-}" in ''|*[!0-9]*) first_fail=0 ;; esac
fi

save_state() { # $1=consec $2=first_fail $3=open_id
  [ "$DRY" = "1" ] && return 0
  printf '%s %s %s' "$1" "$2" "$3" > "$STATE_FILE"
}

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$AGN" 2>/dev/null || echo 000)
now=$(date +%s)

if [ "$code" = "404" ]; then
  if [ -n "$open_id" ]; then
    # close the open window in place
    if [ "$DRY" != "1" ]; then
      dur=$((now - first_fail))
      newline="- [tripwire] id: $open_id | down_detected: $(iso "$first_fail") | recovered: $(iso "$now") | duration_s: $dur | note: AGN non-404 for 3+ consecutive polls, then 404"
      ln=$(grep -n "id: $open_id " "$DTLOG" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
      if [ -n "$ln" ]; then
        esc=$(printf '%s' "$newline" | sed -e 's/[&|\\]/\\&/g')
        sed -i "${ln}s|.*|$esc|" "$DTLOG"
      else
        printf -- '%s\n' "$newline" >> "$DTLOG"
      fi
    fi
    log "observation" "{\"tripwire\":\"recovered\",\"incident\":\"$open_id\"}"
    save_state 0 0 ""
    silent "AGN back to 404; incident $open_id closed" '{}'
    exit 0
  fi
  save_state 0 0 ""
  silent "AGN up (404)" '{}'
  exit 0
fi

# non-404: count toward a sustained-down window
if [ "$consec" = "0" ]; then
  first_fail=$now
fi
consec=$((consec + 1))

if [ "$consec" -ge 3 ] && [ -z "$open_id" ]; then
  open_id="tw-$first_fail"
  if [ "$DRY" != "1" ]; then
    printf -- '- [tripwire] id: %s | down_detected: %s | recovered: OPEN | duration_s: - | note: AGN=%s sustained (3+ polls)\n' \
      "$open_id" "$(iso "$first_fail")" "$code" >> "$DTLOG"
  fi
  log "observation" "{\"tripwire\":\"down_window_opened\",\"incident\":\"$open_id\",\"agnHttp\":$code}"
fi

save_state "$consec" "$first_fail" "$open_id"
silent "AGN=$code (down streak $consec)" '{}'
