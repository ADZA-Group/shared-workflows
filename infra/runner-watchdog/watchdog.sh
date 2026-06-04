#!/usr/bin/env bash
# /opt/runner-watchdog/watchdog.sh — external CI-runner watchdog for LXC104.
# Cost-hart: never falls back to paid hosted. Auto-heal then e-mail alert.
# Runs on the Proxmox host (outside LXC104) via systemd timer. See:
#   docs/superpowers/specs/2026-06-04-ci-runner-watchdog-design.md
set -uo pipefail

: "${WATCHDOG_ENV:=/opt/runner-watchdog/.env}"
# shellcheck disable=SC1090
[ -f "$WATCHDOG_ENV" ] && . "$WATCHDOG_ENV"
: "${LXC_ID:=104}"
: "${GH_ORG:=ADZA-Group}"
: "${ALERT_TO:=aazad.aahmed@hotmail.com}"
: "${STATE_FILE:=/var/lib/runner-watchdog/state}"
: "${COOLDOWN_SEC:=21600}"          # 6h between repeat down-alerts
: "${ZERO_TICKS_DOWN:=2}"           # consecutive 0-runner ticks before "down"
: "${RESTART_WAIT:=60}"
: "${REBOOT_WAIT:=90}"
: "${MSMTP_ACCOUNT:=onecom}"

log(){ echo "$(date -u +%FT%TZ) [watchdog] $*"; }

# ---- external wrappers (overridden in tests) ----
container_status(){ pct status "$LXC_ID" 2>/dev/null | awk '{print $2}'; }
controller_active(){ pct exec "$LXC_ID" -- systemctl is-active runner-controller.service 2>/dev/null; }
gh_api(){ curl -fsS --max-time 25 -H "Authorization: Bearer ${GH_TOKEN:-}" \
            -H "Accept: application/vnd.github+json" "https://api.github.com/$1"; }
runners_json(){ gh_api "orgs/${GH_ORG}/actions/runners"; }
runners_online_count(){ runners_json | jq '[.runners[]|select(.status=="online")]|length' 2>/dev/null || echo -1; }
runners_busy_count(){ runners_json | jq '[.runners[]|select(.busy==true)]|length' 2>/dev/null || echo 0; }
do_start_container(){ log "heal: pct start $LXC_ID"; pct start "$LXC_ID"; }
do_restart_controller(){ log "heal: restart controller"; pct exec "$LXC_ID" -- systemctl restart runner-controller.service; }
do_reboot_container(){ log "heal: pct reboot $LXC_ID"; pct reboot "$LXC_ID"; }
sleep_s(){ sleep "$1"; }
send_email(){ # $1 subject, $2 body
  printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
    "$ALERT_TO" "$1" "${2:-}" | msmtp -a "$MSMTP_ACCOUNT" "$ALERT_TO"; }
now_epoch(){ date +%s; }
queued_count(){ : "${GH_QUEUED:=0}"; echo "${GH_QUEUED}"; }   # optional, refined later

# ---- state (key=value file) ----
state_get(){ [ -f "$STATE_FILE" ] && { grep -E "^$1=" "$STATE_FILE" | tail -1 | cut -d= -f2-; } || true; }
state_set(){ local k="$1" v="$2" tmp; mkdir -p "$(dirname "$STATE_FILE")"; touch "$STATE_FILE"
  tmp="$(mktemp)"; grep -vE "^$k=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"; mv "$tmp" "$STATE_FILE"; }

# ---- classify: echoes healthy | down:<reason> | maybe:<reason> ----
classify(){
  local cs ca online
  cs="$(container_status)";  [ "$cs" != "running" ] && { echo "down:container=$cs"; return; }
  ca="$(controller_active)"; [ "$ca" != "active" ]  && { echo "down:controller=$ca"; return; }
  online="$(runners_online_count)"
  [ "${online:-0}" -le 0 ] && { echo "maybe:online=$online"; return; }
  echo "healthy"
}

# ---- assess: classify + hysteresis -> healthy | down ----
assess(){
  local c z; c="$(classify)"; z="$(state_get zero_ticks)"; z="${z:-0}"
  case "$c" in
    healthy)  state_set zero_ticks 0; echo "healthy" ;;
    down:*)   echo "down" ;;
    maybe:*)  z=$((z+1)); state_set zero_ticks "$z"
              if [ "$z" -ge "$ZERO_TICKS_DOWN" ]; then echo "down"; else echo "healthy"; fi ;;
  esac
}

# ---- heal: recovery ladder for confirmed-down. Reboot guarded by busy==0. ----
heal(){
  local cs ca online busy
  cs="$(container_status)"
  if [ "$cs" != "running" ]; then do_start_container; sleep_s "$REBOOT_WAIT"; return; fi
  ca="$(controller_active)"
  if [ "$ca" != "active" ]; then do_restart_controller; sleep_s "$RESTART_WAIT"; return; fi
  # container running, controller active, but 0 runners online:
  do_restart_controller; sleep_s "$RESTART_WAIT"
  online="$(runners_online_count)"; [ "${online:-0}" -gt 0 ] && return
  busy="$(runners_busy_count)"
  if [ "${busy:-0}" -eq 0 ]; then do_reboot_container; sleep_s "$REBOOT_WAIT"
  else log "heal: 0 runners but busy=$busy -> skip reboot (won't kill live job)"; fi
}

# ---- notify <healthy|down>: idempotent alert/recovery ----
notify(){
  local verdict="$1" prev now last
  prev="$(state_get status)"; prev="${prev:-healthy}"; now="$(now_epoch)"
  if [ "$verdict" = "down" ]; then
    last="$(state_get last_alert)"; last="${last:-0}"
    if [ "$prev" != "down" ]; then state_set down_since "$now"; fi
    if [ "$prev" != "down" ] || [ $((now - last)) -ge "$COOLDOWN_SEC" ]; then
      send_email "🔴 ADZA CI-Runner LXC${LXC_ID} down — Self-Heal fehlgeschlagen" \
        "Self-Heal scheiterte. Zustand: $(classify). Wartende Runs: $(queued_count). Host: $(hostname)."
      state_set last_alert "$now"
    fi
    state_set status down
  else
    if [ "$prev" = "down" ]; then
      send_email "✅ ADZA CI-Runner LXC${LXC_ID} wieder gesund" \
        "Runner ist wieder online. Zustand: $(classify)."
    fi
    state_set status healthy; state_set last_alert 0; state_set zero_ticks 0
  fi
}

# ---- run_once: one full tick ----
run_once(){
  local v; v="$(assess)"
  if [ "$v" = "down" ]; then
    log "verdict=down ($(classify)) -> heal"; heal; v="$(assess)"
    log "post-heal verdict=$v"
  fi
  notify "$v"
}

main(){ log "tick start"; run_once; log "tick end"; }
if [ "${WATCHDOG_LIB:-0}" != "1" ]; then main "$@"; fi
