# CI-Runner-Watchdog (M1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein externer Watchdog auf dem Proxmox-Host hält den self-hosted CI-Runner (LXC104) am Leben (Auto-Heal) und alarmiert per E-Mail, wenn die Selbstheilung scheitert — ohne je auf bezahltes hosted auszuweichen.

**Architecture:** Bash-Script `watchdog.sh`, getrieben von einem `systemd`-Timer (alle 5 Min) auf `192.168.1.20`. Alle externen Aufrufe (`pct`, GitHub-API, Mailversand, sleep) sind in Wrapper-Funktionen gekapselt → unit-testbar mit gemockten Stubs (lokal, ohne echten Host). Quelle versioniert in `shared-workflows/infra/runner-watchdog/`, Deploy nach `/opt/runner-watchdog/`.

**Tech Stack:** Bash, systemd (service+timer), `pct` (Proxmox CLI), GitHub REST API via `curl`+`jq`, `msmtp` (one.com SMTP).

**Spec:** `docs/superpowers/specs/2026-06-04-ci-runner-watchdog-design.md`

---

## File Structure (alle neu, additive)

| Datei | Verantwortung |
|---|---|
| `infra/runner-watchdog/watchdog.sh` | Logik: Signale sammeln → klassifizieren (down/busy/healthy + Hysterese) → Heal-Leiter → idempotenter Alarm |
| `infra/runner-watchdog/test_watchdog.sh` | Unit-Tests: sourct watchdog.sh im Lib-Modus, überschreibt Wrapper mit Mocks, Zustandstabelle → erwartete Aktion |
| `infra/runner-watchdog/.env.example` | Vorlage für `/opt/runner-watchdog/.env` (SMTP + GH-Token + Tuning), KEINE echten Secrets |
| `infra/runner-watchdog/runner-watchdog.service` | systemd oneshot |
| `infra/runner-watchdog/runner-watchdog.timer` | systemd Timer (5 Min) |
| `infra/runner-watchdog/README.md` | Deploy-Runbook + Integrationstest-Anleitung |

**Konvention:** `watchdog.sh` endet mit `if [ "${WATCHDOG_LIB:-0}" != "1" ]; then main "$@"; fi` → Tests sourcen mit `WATCHDOG_LIB=1`, ohne `main` auszuführen.

**State-Datei** `/var/lib/runner-watchdog/state` (key=value):
`status` (`healthy`/`down`), `down_since` (epoch), `last_alert` (epoch), `zero_ticks` (consecutive 0-runner Ticks).

---

## Task 1: Scaffold + Lib-Guard + Config-Header

**Files:**
- Create: `infra/runner-watchdog/watchdog.sh`
- Create: `infra/runner-watchdog/test_watchdog.sh`
- Create: `infra/runner-watchdog/.env.example`

- [ ] **Step 1: Write the failing test (lib-mode sourcing executes nothing)**

`infra/runner-watchdog/test_watchdog.sh`:
```bash
#!/usr/bin/env bash
# Unit tests for watchdog.sh — pure bash, mocks all external calls.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1 (got: '$2' want: '$3')"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

# isolate state per test run
export STATE_FILE="$(mktemp)"; export WATCHDOG_ENV=/dev/null
export WATCHDOG_LIB=1
. "$HERE/watchdog.sh"

# Task 1 assertion: sourcing did not run main (no side effects / reachable funcs)
eq "lib-mode: log() defined" "$(type -t log)" "function"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: FAIL — `watchdog.sh` existiert noch nicht (`No such file`).

- [ ] **Step 3: Write minimal watchdog.sh (config + log + lib-guard)**

`infra/runner-watchdog/watchdog.sh`:
```bash
#!/usr/bin/env bash
# /opt/runner-watchdog/watchdog.sh — external CI-runner watchdog for LXC104.
# Cost-hart: never falls back to paid hosted. Auto-heal then e-mail alert.
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

main(){ log "noop (scaffold)"; }
if [ "${WATCHDOG_LIB:-0}" != "1" ]; then main "$@"; fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: `ok: lib-mode: log() defined` … `PASS=1 FAIL=0`.

- [ ] **Step 5: Create `.env.example`**

`infra/runner-watchdog/.env.example`:
```bash
# Copy to /opt/runner-watchdog/.env on the Proxmox host, chmod 600. NO secrets in git.
GH_TOKEN=ghp_xxx_readonly_actions_org
ALERT_TO=aazad.aahmed@hotmail.com
# msmtp account name configured in /root/.msmtprc (one.com SMTP)
MSMTP_ACCOUNT=onecom
# tuning (optional)
LXC_ID=104
GH_ORG=ADZA-Group
COOLDOWN_SEC=21600
ZERO_TICKS_DOWN=2
```

- [ ] **Step 6: Commit**

```bash
git add infra/runner-watchdog/watchdog.sh infra/runner-watchdog/test_watchdog.sh infra/runner-watchdog/.env.example
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): scaffold runner-watchdog (lib-guard, config, env example)"
```

---

## Task 2: Signal wrappers + `classify` (down/maybe/healthy)

**Files:**
- Modify: `infra/runner-watchdog/watchdog.sh`
- Modify: `infra/runner-watchdog/test_watchdog.sh`

- [ ] **Step 1: Write the failing tests (classify state-table)**

Append to `test_watchdog.sh` before the summary line:
```bash
# --- Task 2: classify() with mocked signals ---
container_status(){ echo "$MOCK_CS"; }
controller_active(){ echo "$MOCK_CA"; }
runners_online_count(){ echo "$MOCK_ONLINE"; }

MOCK_CS=running MOCK_CA=active MOCK_ONLINE=2; eq "healthy"        "$(classify)" "healthy"
MOCK_CS=stopped MOCK_CA=active MOCK_ONLINE=0; eq "container down" "$(classify)" "down:container=stopped"
MOCK_CS=running MOCK_CA=failed MOCK_ONLINE=0; eq "controller down""$(classify)" "down:controller=failed"
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0; eq "maybe (0 online)" "$(classify)" "maybe:online=0"
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=-1; eq "api error->maybe" "$(classify)" "maybe:online=-1"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: FAIL — `classify: command not found`.

- [ ] **Step 3: Implement wrappers + classify (insert above `main()`)**

```bash
# ---- external wrappers (overridden in tests) ----
container_status(){ pct status "$LXC_ID" 2>/dev/null | awk '{print $2}'; }
controller_active(){ pct exec "$LXC_ID" -- systemctl is-active runner-controller.service 2>/dev/null; }
gh_api(){ curl -fsS --max-time 25 -H "Authorization: Bearer ${GH_TOKEN:-}" \
            -H "Accept: application/vnd.github+json" "https://api.github.com/$1"; }
runners_json(){ gh_api "orgs/${GH_ORG}/actions/runners"; }
runners_online_count(){ runners_json | jq '[.runners[]|select(.status=="online")]|length' 2>/dev/null || echo -1; }
runners_busy_count(){ runners_json | jq '[.runners[]|select(.busy==true)]|length' 2>/dev/null || echo 0; }

# ---- classify: echoes healthy | down:<reason> | maybe:<reason> ----
classify(){
  local cs ca online
  cs="$(container_status)";  [ "$cs" != "running" ] && { echo "down:container=$cs"; return; }
  ca="$(controller_active)"; [ "$ca" != "active" ]  && { echo "down:controller=$ca"; return; }
  online="$(runners_online_count)"
  [ "${online:-0}" -le 0 ] && { echo "maybe:online=$online"; return; }
  echo "healthy"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: all 5 classify cases `ok`, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-watchdog/watchdog.sh infra/runner-watchdog/test_watchdog.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): signal wrappers + classify (down/maybe/healthy)"
```

---

## Task 3: State helpers + hysteresis (`assess`)

`assess` turns a single-tick `classify` + persisted `zero_ticks` into a final verdict: `healthy` | `down`. The `maybe:online=0` case becomes `down` only after `ZERO_TICKS_DOWN` consecutive ticks.

**Files:**
- Modify: `infra/runner-watchdog/watchdog.sh`
- Modify: `infra/runner-watchdog/test_watchdog.sh`

- [ ] **Step 1: Write failing tests**

Append to `test_watchdog.sh`:
```bash
# --- Task 3: state + hysteresis ---
state_set zero_ticks 0; eq "state roundtrip" "$(state_get zero_ticks)" "0"

MOCK_CS=running MOCK_CA=active MOCK_ONLINE=3
state_set zero_ticks 0; eq "healthy resets"      "$(assess)" "healthy"; eq "  ticks=0" "$(state_get zero_ticks)" "0"

MOCK_ONLINE=0
state_set zero_ticks 0; eq "maybe tick1 -> healthy" "$(assess)" "healthy"; eq "  ticks=1" "$(state_get zero_ticks)" "1"
eq                       "maybe tick2 -> down"    "$(assess)" "down";    eq "  ticks=2" "$(state_get zero_ticks)" "2"

MOCK_CS=stopped MOCK_CA=active MOCK_ONLINE=0
state_set zero_ticks 0; eq "container down immediate" "$(assess)" "down"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: FAIL — `state_set`/`assess` not found.

- [ ] **Step 3: Implement state helpers + assess (insert above `main()`)**

```bash
# ---- state (key=value file) ----
state_get(){ [ -f "$STATE_FILE" ] && { grep -E "^$1=" "$STATE_FILE" | tail -1 | cut -d= -f2-; } || true; }
state_set(){ local k="$1" v="$2" tmp; mkdir -p "$(dirname "$STATE_FILE")"; touch "$STATE_FILE"
  tmp="$(mktemp)"; grep -vE "^$k=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"; mv "$tmp" "$STATE_FILE"; }

now_epoch(){ date +%s; }

# ---- assess: classify + hysteresis -> healthy|down ----
assess(){
  local c z; c="$(classify)"; z="$(state_get zero_ticks)"; z="${z:-0}"
  case "$c" in
    healthy)  state_set zero_ticks 0; echo "healthy" ;;
    down:*)   echo "down" ;;
    maybe:*)  z=$((z+1)); state_set zero_ticks "$z"
              if [ "$z" -ge "$ZERO_TICKS_DOWN" ]; then echo "down"; else echo "healthy"; fi ;;
  esac
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: hysteresis cases `ok`, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-watchdog/watchdog.sh infra/runner-watchdog/test_watchdog.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): state helpers + hysteresis (assess)"
```

---

## Task 4: Heal ladder with reboot-guard (`heal`)

`heal` runs only when `assess`==down. Records actions into the global `HEAL_LOG` (newline list) so tests can assert the sequence. Real waits/commands are wrappers (mocked in tests).

**Files:**
- Modify: `infra/runner-watchdog/watchdog.sh`
- Modify: `infra/runner-watchdog/test_watchdog.sh`

- [ ] **Step 1: Write failing tests**

Append to `test_watchdog.sh`:
```bash
# --- Task 4: heal ladder (mock side-effect commands + waits) ---
HEAL_LOG=""
do_start_container(){ HEAL_LOG+="start
"; }
do_restart_controller(){ HEAL_LOG+="restart
"; }
do_reboot_container(){ HEAL_LOG+="reboot
"; }
sleep_s(){ :; }   # no real sleep in tests

# container stopped, no jobs busy -> start
HEAL_LOG=""; MOCK_CS=stopped MOCK_CA=active MOCK_ONLINE=0; MOCK_BUSY=0
runners_busy_count(){ echo "$MOCK_BUSY"; }
heal >/dev/null; eq "stopped -> start" "$HEAL_LOG" "start
"

# controller inactive -> restart
HEAL_LOG=""; MOCK_CS=running MOCK_CA=failed MOCK_ONLINE=0
heal >/dev/null; eq "controller dead -> restart" "$HEAL_LOG" "restart
"

# online 0 but controller active, busy=0 -> restart then reboot
HEAL_LOG=""; MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0; MOCK_BUSY=0
heal >/dev/null; eq "0 runners busy=0 -> restart+reboot" "$HEAL_LOG" "restart
reboot
"

# online 0 but a job is busy -> restart only, NO reboot (guard)
HEAL_LOG=""; MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0; MOCK_BUSY=1
heal >/dev/null; eq "0 runners busy=1 -> NO reboot" "$HEAL_LOG" "restart
"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: FAIL — `heal`/`do_*` not found.

- [ ] **Step 3: Implement side-effect wrappers + heal (insert above `main()`)**

```bash
do_start_container(){ log "heal: pct start $LXC_ID"; pct start "$LXC_ID"; }
do_restart_controller(){ log "heal: restart controller"; pct exec "$LXC_ID" -- systemctl restart runner-controller.service; }
do_reboot_container(){ log "heal: pct reboot $LXC_ID"; pct reboot "$LXC_ID"; }
sleep_s(){ sleep "$1"; }

# heal: attempt recovery for a confirmed-down state. Reboot is guarded by busy==0.
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
```

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: all 4 heal cases `ok`, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-watchdog/watchdog.sh infra/runner-watchdog/test_watchdog.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): auto-heal ladder with reboot busy-guard"
```

---

## Task 5: E-mail + idempotent alert/recovery (`notify`)

`notify <verdict>` manages the alert state machine via `MAIL_LOG` (tests) / `send_email` (real).

**Files:**
- Modify: `infra/runner-watchdog/watchdog.sh`
- Modify: `infra/runner-watchdog/test_watchdog.sh`

- [ ] **Step 1: Write failing tests**

Append to `test_watchdog.sh`:
```bash
# --- Task 5: notify state machine (mock email + clock) ---
MAIL_LOG=""; send_email(){ MAIL_LOG+="MAIL:$1
"; }
NOW=1000000; now_epoch(){ echo "$NOW"; }
state_set status healthy; state_set last_alert 0

# healthy -> healthy: no mail
MAIL_LOG=""; notify healthy; eq "healthy stays quiet" "$MAIL_LOG" ""

# healthy -> down: one down mail, status=down
MAIL_LOG=""; notify down
case "$MAIL_LOG" in *"MAIL:🔴"*) ok "down -> alert";; *) no "down -> alert" "$MAIL_LOG" "🔴";; esac
eq "  status=down" "$(state_get status)" "down"

# down -> down within cooldown: no second mail
MAIL_LOG=""; NOW=$((NOW+60)); notify down; eq "cooldown suppresses" "$MAIL_LOG" ""

# down -> down after cooldown: re-alert
MAIL_LOG=""; NOW=$((NOW+COOLDOWN_SEC+1)); notify down
case "$MAIL_LOG" in *"MAIL:🔴"*) ok "re-alert after cooldown";; *) no "re-alert" "$MAIL_LOG" "🔴";; esac

# down -> healthy: recovery mail, status healthy
MAIL_LOG=""; notify healthy
case "$MAIL_LOG" in *"MAIL:✅"*) ok "recovery mail";; *) no "recovery" "$MAIL_LOG" "✅";; esac
eq "  status=healthy" "$(state_get status)" "healthy"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: FAIL — `notify`/`send_email` not found.

- [ ] **Step 3: Implement send_email + notify (insert above `main()`)**

```bash
send_email(){ # $1 subject, $2 body
  printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
    "$ALERT_TO" "$1" "${2:-}" | msmtp -a "$MSMTP_ACCOUNT" "$ALERT_TO"; }

# notify <healthy|down>: idempotent alert/recovery
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

queued_count(){ : "${GH_QUEUED:=0}"; echo "${GH_QUEUED}"; }  # refined in Task 6 (optional)
```

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: notify cases `ok`, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-watchdog/watchdog.sh infra/runner-watchdog/test_watchdog.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): idempotent e-mail alert + recovery state machine"
```

---

## Task 6: Orchestration (`main`) + end-to-end mocked scenarios

**Files:**
- Modify: `infra/runner-watchdog/watchdog.sh`
- Modify: `infra/runner-watchdog/test_watchdog.sh`

- [ ] **Step 1: Write failing E2E tests**

Append to `test_watchdog.sh`:
```bash
# --- Task 6: main() E2E ---
HEAL_LOG=""; MAIL_LOG=""
# scenario A: steady healthy -> no heal, no mail
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=2 MOCK_BUSY=0; state_set status healthy; state_set zero_ticks 0
HEAL_LOG=""; MAIL_LOG=""; run_once >/dev/null
eq "A: healthy no heal" "$HEAL_LOG" ""; eq "A: healthy no mail" "$MAIL_LOG" ""

# scenario B: controller dead, heal succeeds (online after restart) -> no mail
state_set status healthy; state_set zero_ticks 0
MOCK_CS=running MOCK_CA=failed MOCK_ONLINE=0
# after restart, controller becomes active + runners online:
do_restart_controller(){ HEAL_LOG+="restart
"; MOCK_CA=active; MOCK_ONLINE=1; }
HEAL_LOG=""; MAIL_LOG=""; run_once >/dev/null
eq "B: healed via restart" "$HEAL_LOG" "restart
"; eq "B: no mail (recovered)" "$MAIL_LOG" ""

# scenario C: hard down, heal fails -> alert
state_set status healthy; state_set zero_ticks "$ZERO_TICKS_DOWN"
MOCK_CS=stopped MOCK_CA=failed MOCK_ONLINE=0
do_start_container(){ HEAL_LOG+="start
"; }    # start does NOT fix it (stays stopped)
HEAL_LOG=""; MAIL_LOG=""; run_once >/dev/null
case "$MAIL_LOG" in *"MAIL:🔴"*) ok "C: alert on heal-fail";; *) no "C: alert" "$MAIL_LOG" "🔴";; esac
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: FAIL — `run_once` not found.

- [ ] **Step 3: Implement run_once + main (replace the scaffold `main`)**

```bash
# run_once: one full tick. assess -> if down: heal, re-assess -> notify final verdict.
run_once(){
  local v; v="$(assess)"
  if [ "$v" = "down" ]; then
    log "verdict=down ($(classify)) -> heal"; heal; v="$(assess)"
    log "post-heal verdict=$v"
  fi
  notify "$v"
}

main(){ log "tick start"; run_once; log "tick end"; }
```

(Delete the old `main(){ log "noop (scaffold)"; }`.)

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-watchdog/test_watchdog.sh`
Expected: A/B/C `ok`, final `PASS=… FAIL=0`.

- [ ] **Step 5: shellcheck (style/safety gate)**

Run: `shellcheck infra/runner-watchdog/watchdog.sh` (if installed locally; else run on host in Task 8)
Expected: no errors (warnings acceptable; fix obvious ones).

- [ ] **Step 6: Commit**

```bash
git add infra/runner-watchdog/watchdog.sh infra/runner-watchdog/test_watchdog.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): run_once orchestration + E2E mocked scenarios"
```

---

## Task 7: systemd unit + timer

**Files:**
- Create: `infra/runner-watchdog/runner-watchdog.service`
- Create: `infra/runner-watchdog/runner-watchdog.timer`

- [ ] **Step 1: Write the service**

`infra/runner-watchdog/runner-watchdog.service`:
```ini
[Unit]
Description=ADZA CI-runner watchdog (LXC104 auto-heal + alert)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/runner-watchdog/watchdog.sh
Nice=10
# never hang a tick longer than ~4 min (heal waits sum < this)
TimeoutStartSec=240
```

- [ ] **Step 2: Write the timer**

`infra/runner-watchdog/runner-watchdog.timer`:
```ini
[Unit]
Description=Run ADZA CI-runner watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Verify unit syntax**

Run (locally if `systemd-analyze` present, else on host in Task 8):
`systemd-analyze verify infra/runner-watchdog/runner-watchdog.service infra/runner-watchdog/runner-watchdog.timer`
Expected: no output (valid). Note: `ExecStart` path-exists warning is fine pre-deploy.

- [ ] **Step 4: Commit**

```bash
git add infra/runner-watchdog/runner-watchdog.service infra/runner-watchdog/runner-watchdog.timer
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(watchdog): systemd service + 5-min timer"
```

---

## Task 8: Deploy runbook + controlled host integration test

**Files:**
- Create: `infra/runner-watchdog/README.md`

- [ ] **Step 1: Write README (deploy + integration test runbook)**

`infra/runner-watchdog/README.md`:
````markdown
# runner-watchdog — deploy + verify

External watchdog for the CI cost-switch. Lives on the **Proxmox host** (192.168.1.20),
keeps LXC104 (self-hosted runner) alive + e-mails on unrecoverable failure. See spec:
`docs/superpowers/specs/2026-06-04-ci-runner-watchdog-design.md`.

## Prereqs on the host (once)
1. `msmtp` + one.com SMTP in `/root/.msmtprc` (account `onecom`), `chmod 600`.
2. `jq` + `curl` installed.
3. Read-only GitHub token (scope `read:org`) for the runner-status API.

## Deploy
```bash
ssh root@192.168.1.20
mkdir -p /opt/runner-watchdog /var/lib/runner-watchdog
# copy watchdog.sh + units from this repo (scp or git pull on host)
install -m 0755 watchdog.sh /opt/runner-watchdog/watchdog.sh
cp .env.example /opt/runner-watchdog/.env && chmod 600 /opt/runner-watchdog/.env
$EDITOR /opt/runner-watchdog/.env          # fill GH_TOKEN, ALERT_TO
install -m 0644 runner-watchdog.service /etc/systemd/system/
install -m 0644 runner-watchdog.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now runner-watchdog.timer
```

## Verify it runs
```bash
systemctl start runner-watchdog.service     # one manual tick
journalctl -u runner-watchdog -n 20 --no-pager   # see "tick start ... tick end"
systemctl list-timers runner-watchdog.timer
```

## Controlled integration tests
1. **Heal Stufe 1 (controller restart):**
   `pct exec 104 -- systemctl stop runner-controller`
   → next tick (or `systemctl start runner-watchdog.service`) must log `heal: restart controller`,
     controller active again, recovery mail (if it had alerted).
2. **Heal Stufe 2 (reboot) — MAINTENANCE WINDOW, ensure no CI job running (`busy=0`):**
   `pct stop 104` → tick must log `heal: pct start`/`reboot`, container back, recovery mail.
3. **Alert path:** temporarily set `.env` `GH_TOKEN=invalid` + stop controller so heal can't confirm
   → after heal, `🔴` mail arrives; restore token → next tick `✅` recovery mail.
4. **Anti-spam:** with state `down`, run two ticks within 6h → only the first mails.
````

- [ ] **Step 2: Deploy to host**

Run the README "Deploy" block via `ssh root@192.168.1.20`. (User provides `.env` secrets per spec §8.)

- [ ] **Step 3: Smoke — one manual tick is green**

Run: `ssh root@192.168.1.20 "systemctl start runner-watchdog.service && journalctl -u runner-watchdog -n 10 --no-pager"`
Expected: `tick start … verdict=healthy … tick end`, exit 0, no mail (system currently healthy).

- [ ] **Step 4: Integration test — heal Stufe 1**

Run: `ssh root@192.168.1.20 "pct exec 104 -- systemctl stop runner-controller; systemctl start runner-watchdog.service; journalctl -u runner-watchdog -n 15 --no-pager"`
Expected: log shows `heal: restart controller`; `pct exec 104 -- systemctl is-active runner-controller` → `active`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-watchdog/README.md
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "docs(watchdog): deploy + integration-test runbook"
git push origin dev
```

---

## Self-Review (gegen Spec)

- **§3 Platzierung** → Task 7 (systemd service+timer, host). ✅
- **§4 Detektion (down/busy/Hysterese)** → Task 2 (`classify`) + Task 3 (`assess`, 2-Tick). ✅
- **§5 Heal-Leiter + Reboot-Guard** → Task 4 (`heal`, busy==0-Guard). ✅
- **§6 Alarm idempotent + Recovery** → Task 5 (`notify`, cooldown + ✅-Mail). ✅
- **§7 Logging journald** → `log()` (Task 1) + oneshot service (Task 7). ✅
- **§8 Setup-Deps (SMTP, GH-Token, .env 600)** → `.env.example` (Task 1) + README (Task 8). ✅
- **§9 Testplan (mock state-table + host integration)** → Tasks 2–6 (unit) + Task 8 (integration). ✅
- **§10 Non-Goals (kein hosted-Fallback, kein Job-Kill, kein busy-Eingriff)** → `heal` macht nie hosted; Reboot-Guard; `classify` busy=healthy. ✅

**Placeholder scan:** keine TBD/TODO; jede Code-Step enthält vollständigen Code. ✅
**Type/Name-Konsistenz:** Funktionsnamen über Tasks konsistent (`classify`/`assess`/`heal`/`notify`/`run_once`; Wrapper `do_start_container`/`do_restart_controller`/`do_reboot_container`/`runners_online_count`/`runners_busy_count`/`send_email`/`now_epoch`/`state_get`/`state_set`). ✅
**Offene Kleinigkeit:** `queued_count` ist in Task 5 ein Stub (GH_QUEUED, default 0) und bleibt optional — rein kosmetisch im Mail-Body; bewusst YAGNI, kein Blocker.
