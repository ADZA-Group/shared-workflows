#!/usr/bin/env bash
# /opt/runner-prewarmer/prewarmer.sh — proactively keep self-hosted runners warm
# when free GitHub minutes are low. Writes a min-floor into LXC104 for the
# runner-controller to honor. Runs on the Proxmox host via systemd timer.
# Spec: docs/superpowers/specs/2026-06-04-ci-load-manager-design.md
set -uo pipefail

: "${PREWARMER_ENV:=/opt/runner-prewarmer/.env}"
# shellcheck disable=SC1090
[ -f "$PREWARMER_ENV" ] && . "$PREWARMER_ENV"
: "${LXC_ID:=104}"
: "${GH_ORG:=ADZA-Group}"
: "${INCLUDED_MINUTES:=2000}"
: "${PREWARM_THRESHOLD:=400}"      # remain <= this -> keep more warm
: "${PREWARM_COUNT:=3}"            # how many to keep warm when minutes low
: "${FLOOR_PATH:=/run/runner-controller/min-floor}"

log(){ echo "$(date -u +%FT%TZ) [prewarmer] $*"; }

# ---- external wrappers (overridden in tests) ----
gh_api(){ curl -fsS --max-time 25 -H "Authorization: Bearer ${GH_TOKEN:-}" \
            -H "Accept: application/vnd.github+json" "https://api.github.com/$1"; }
billing_json(){ local y m; y="$(date -u +%Y)"; m="$(date -u +%-m)"
  gh_api "organizations/${GH_ORG}/settings/billing/usage?year=${y}&month=${m}" 2>/dev/null \
    || gh_api "users/${GH_ORG}/settings/billing/usage?year=${y}&month=${m}" 2>/dev/null; }
# echoes used Actions minutes (int), or -1 if billing unreadable
billing_used_minutes(){
  local data used; data="$(billing_json)"
  echo "$data" | jq -e '.usageItems' >/dev/null 2>&1 || { echo -1; return; }
  used="$(printf '%s' "$data" | jq '[.usageItems[]|select(.product=="actions" and .unitType=="Minutes")|.quantity]|add // 0')"
  printf '%.0f\n' "${used:-0}"
}

# ---- compute_floor: desired warm-runner floor (1 normally, PREWARM_COUNT when low) ----
compute_floor(){
  [ -z "${GH_TOKEN:-}" ] && { echo 1; return; }                 # no token -> safe default
  local used remain; used="$(billing_used_minutes)"
  [ "${used:--1}" -lt 0 ] && { echo 1; return; }                # unreadable -> safe default
  remain=$(( INCLUDED_MINUTES - used ))
  if [ "$remain" -le "$PREWARM_THRESHOLD" ]; then echo "$PREWARM_COUNT"; else echo 1; fi
}

# ---- write the floor INTO LXC104 (host /run != container /run!), atomically ----
pct_write_floor(){
  pct exec "$LXC_ID" -- sh -c "d=\$(dirname '$FLOOR_PATH'); mkdir -p \"\$d\"; t=\$(mktemp \"\$d/.floor.XXXX\"); printf '%s\n' '$1' > \"\$t\"; mv \"\$t\" '$FLOOR_PATH'"; }
write_floor(){ pct_write_floor "$1"; }

main(){
  local floor; floor="$(compute_floor)"
  log "floor=${floor} (threshold=${PREWARM_THRESHOLD} count=${PREWARM_COUNT})"
  write_floor "${floor}"
}
if [ "${PREWARMER_LIB:-0}" != "1" ]; then main "$@"; fi
