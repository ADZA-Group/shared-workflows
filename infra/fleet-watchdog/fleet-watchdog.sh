#!/usr/bin/env bash
# /opt/fleet-watchdog/fleet-watchdog.sh - fleet-wide LXC + host health & maintenance.
# Runs on the Proxmox host via systemd timer (sibling of runner-watchdog).
#   MODE (arg1): "report" (READ-ONLY) | "maintain" (adds CONSERVATIVE cleanup)
#
# SAFE BY DESIGN: everything is READ-ONLY except maintain's cleanup, which is
# limited to stopped containers >2h + dangling images + apt cache + journal
# vacuum(>7d). It NEVER restarts/deletes a running container, NEVER applies
# updates, NEVER restarts services. Prod (108 etc.) is read + conservatively
# cleaned only. The only writes outside that are `apt-get update` (metadata
# refresh, required to count upgradable packages).
set -uo pipefail

: "${FLEET_ENV:=/opt/fleet-watchdog/.env}"
# shellcheck disable=SC1090
[ -f "$FLEET_ENV" ] && . "$FLEET_ENV"
: "${ALERT_TO:=aazad.aahmed@hotmail.com}"
: "${MSMTP_ACCOUNT:=onecom}"
: "${ALERTS_ENABLED:=0}"        # 0 = log-only; 1 = also e-mail summary (opt-in)
: "${SKIP_IDS:=}"               # LXC ids to skip entirely
: "${RUNNER_IDS:=104}"          # CI runners: stopped containers are normal cruft
: "${DISK_WARN:=85}"            # warn if rootfs use% >= this
: "${MEM_WARN:=92}"             # warn if memory use% >= this
: "${HEALTH_PORTS:=80}"         # ports to probe /health on inside app LXCs

MODE="${1:-report}"
log(){ echo "$(date -u +%FT%TZ) [fleet] $*" >&2; }
inx(){ pct exec "$1" -- sh -c "$2" 2>/dev/null; }   # run cmd inside LXC <id>

ids(){ pct list | awk 'NR>1{print $1}'; }
ctname(){ pct list | awk -v i="$1" '$1==i{print $3}'; }
ctstatus(){ pct status "$1" 2>/dev/null | awk '{print $2}'; }

R=""; add(){ R="${R}${1}
"; }

add "ADZA Fleet-Report $(date -u '+%F %T')Z - host $(hostname) - mode=$MODE"

# ---------------- PROXMOX HOST (the SPOF for everything) ----------------
add ""
add "== PROXMOX HOST =="
add "  load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null) (/$(nproc 2>/dev/null) cpu)"
add "  mem:  $(free -m 2>/dev/null | awk '/^Mem:/{printf "%d%% (%dMB/%dMB)", $3*100/$2, $3, $2}')"
add "  disk /: $(df -P / 2>/dev/null | awk 'NR==2{print $5" used of "int($2/1024/1024)"G"}')"
add "  zfs:  $(zpool status -x 2>/dev/null || echo 'n/a (no ZFS)')"
apt-get update -qq >/dev/null 2>&1 || true
add "  updates: $(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0) upgradable ($(apt list --upgradable 2>/dev/null | grep -ci security || echo 0) security) - CHECK only"
HBAK="$(find /var/lib/vz/dump -maxdepth 1 -name 'vzdump-*' ! -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -n "$HBAK" ]; then
  add "  last backup: $(( ( $(date +%s) - $(stat -c %Y "$HBAK") ) / 86400 ))d ago ($(basename "$HBAK"))"
else
  add "  last backup: none in /var/lib/vz/dump"
fi

# ---------------- LXC FLEET ----------------
add ""
add "== LXC FLEET =="
DOWN=""; WARN=""; DEPLOY=""; PROB=""; UPD=""; TOTAL=0
for id in $(ids); do
  case " $SKIP_IDS " in *" $id "*) continue;; esac
  TOTAL=$((TOTAL+1))
  nm="$(ctname "$id")"; st="$(ctstatus "$id")"
  if [ "$st" != "running" ]; then DOWN="${DOWN}  [DOWN] $id $nm = $st
"; continue; fi

  # --- resource snapshot (read-only) ---
  disk="$(inx "$id" "df -P / 2>/dev/null | awk 'NR==2{print \$5}' | tr -d '%'")"
  mem="$(inx "$id" "free 2>/dev/null | awk '/^Mem:/{printf \"%d\", \$3*100/\$2}'")"
  reboot="$(inx "$id" '[ -f /var/run/reboot-required ] && echo yes')"
  failed="$(inx "$id" 'systemctl --failed --no-legend 2>/dev/null | wc -l')"
  w=""
  [ -n "$disk" ] && [ "$disk" -ge "$DISK_WARN" ] 2>/dev/null && w="$w disk=${disk}%"
  [ -n "$mem" ] && [ "$mem" -ge "$MEM_WARN" ] 2>/dev/null && w="$w mem=${mem}%"
  [ "$reboot" = "yes" ] && w="$w reboot-required"
  [ -n "$failed" ] && [ "$failed" -gt 0 ] 2>/dev/null && w="$w failed-svc=$failed"
  [ -n "$w" ] && WARN="${WARN}  [!] $id $nm:$w
"

  # --- docker: container health + /health probe + (maintain) cleanup ---
  if [ "$(inx "$id" 'command -v docker >/dev/null 2>&1 && echo y')" = "y" ]; then
    bad="$(inx "$id" "docker ps -a --format '{{.Names}}={{.State}}' | grep -v '=running$' || true")"
    case " $RUNNER_IDS " in
      *" $id "*) : ;;   # runner: stopped containers are CI cruft, not a deploy issue
      *) [ -n "$bad" ] && PROB="${PROB}  [CT] $id $nm: $(echo $bad)
" ;;
    esac
    for p in $HEALTH_PORTS; do
      hb="$(inx "$id" "curl -fsS -m3 http://localhost:$p/health 2>/dev/null")"
      if [ -n "$hb" ]; then
        sha="$(printf '%s' "$hb" | grep -oE '\"(app_sha|sha|version)\":\"[^\"]+\"' | head -1)"
        DEPLOY="${DEPLOY}  [OK] $id $nm: /health:$p -> 200 ${sha}
"
        break
      fi
    done
    [ "$MODE" = "maintain" ] && inx "$id" 'docker container prune -f --filter until=2h >/dev/null 2>&1 || true; docker image prune -f >/dev/null 2>&1 || true'
  fi

  # --- apt update-check (+ maintain cache/journal clean) ---
  if [ "$(inx "$id" 'command -v apt-get >/dev/null 2>&1 && echo y')" = "y" ]; then
    n="$(inx "$id" 'apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -c upgradable')"
    sec="$(inx "$id" 'apt list --upgradable 2>/dev/null | grep -ci security')"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && UPD="${UPD}  $id $nm: $n ($sec security)
"
    [ "$MODE" = "maintain" ] && inx "$id" 'apt-get clean >/dev/null 2>&1 || true; command -v journalctl >/dev/null 2>&1 && journalctl --vacuum-time=7d >/dev/null 2>&1 || true'
  fi
done

if [ -n "$DOWN" ]; then add "[!] OFFLINE:"; add "$DOWN"; else add "[OK] ONLINE: all $TOTAL LXC running"; fi
[ -n "$WARN" ] && { add ""; add "[!] RESOURCE WARNINGS (disk>=$DISK_WARN% / mem>=$MEM_WARN% / reboot / failed svc):"; add "$WARN"; }
add ""
[ -n "$DEPLOY" ] && { add "[i] DEPLOY-ARRIVAL (/health reachable):"; add "$DEPLOY"; }
if [ -n "$PROB" ]; then add "[!] CONTAINER ISSUES:"; add "$PROB"; else add "[OK] containers: all running"; fi
add ""
if [ -n "$UPD" ]; then add "[i] UPDATES (check-only, NOT applied):"; add "$UPD"; else add "[OK] UPDATES: none pending"; fi
[ "$MODE" = "maintain" ] && { add ""; add "[~] Cleanup done: stopped-ct>2h + dangling images + apt cache + journals(>7d). No restarts/deletes/updates."; }

printf '%s\n' "$R"

if [ "$ALERTS_ENABLED" = "1" ]; then
  if [ -n "$DOWN" ]; then S="[RED] ADZA Fleet - LXC offline"
  elif [ -n "${WARN}${PROB}" ]; then S="[YEL] ADZA Fleet - warnings"
  else S="[GRN] ADZA Fleet OK ($TOTAL LXC)"; fi
  printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
    "$ALERT_TO" "$S" "$R" | msmtp -a "$MSMTP_ACCOUNT" "$ALERT_TO" && log "summary emailed to $ALERT_TO"
else
  log "ALERTS_ENABLED=0 -> log-only"
fi
