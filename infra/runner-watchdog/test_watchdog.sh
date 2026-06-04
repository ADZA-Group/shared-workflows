#!/usr/bin/env bash
# Unit tests for watchdog.sh — pure bash, mocks ALL external calls (pct/gh/mail/sleep/clock).
# Run: bash infra/runner-watchdog/test_watchdog.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1 (got: '$2' want: '$3')"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

# isolate state + skip real .env; source in library mode (no main run)
export STATE_FILE; STATE_FILE="$(mktemp)"
export WATCHDOG_ENV=/dev/null
export WATCHDOG_LIB=1
# shellcheck disable=SC1091
. "$HERE/watchdog.sh"

# ===== Task 1: lib-mode sourcing executes nothing reachable as a run =====
eq "lib-mode: log() defined" "$(type -t log)" "function"

# ===== Task 2: classify() with mocked signals =====
container_status(){ echo "$MOCK_CS"; }
controller_active(){ echo "$MOCK_CA"; }
runners_online_count(){ echo "$MOCK_ONLINE"; }

MOCK_CS=running MOCK_CA=active MOCK_ONLINE=2;  eq "healthy"          "$(classify)" "healthy"
MOCK_CS=stopped MOCK_CA=active MOCK_ONLINE=0;  eq "container down"   "$(classify)" "down:container=stopped"
MOCK_CS=running MOCK_CA=failed MOCK_ONLINE=0;  eq "controller down"  "$(classify)" "down:controller=failed"
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0;  eq "maybe (0 online)" "$(classify)" "maybe:online=0"
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=-1; eq "api unreadable->unknown" "$(classify)" "unknown:online_api"

# ===== Task 3: state + hysteresis =====
state_set zero_ticks 0; eq "state roundtrip" "$(state_get zero_ticks)" "0"

MOCK_CS=running MOCK_CA=active MOCK_ONLINE=3
state_set zero_ticks 0; eq "healthy resets" "$(assess)" "healthy"; eq "  ticks=0" "$(state_get zero_ticks)" "0"

MOCK_ONLINE=0
state_set zero_ticks 0; eq "maybe tick1 -> healthy" "$(assess)" "healthy"; eq "  ticks=1" "$(state_get zero_ticks)" "1"
eq "maybe tick2 -> down" "$(assess)" "down"; eq "  ticks=2" "$(state_get zero_ticks)" "2"

MOCK_CS=stopped MOCK_CA=active MOCK_ONLINE=0
state_set zero_ticks 0; eq "container down immediate" "$(assess)" "down"

# SAFETY: API unreadable (bad/missing token) must NEVER escalate to down (no false reboot)
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=-1; state_set zero_ticks 0
eq "unknown tick1 -> healthy" "$(assess)" "healthy"
eq "unknown tick2 -> healthy" "$(assess)" "healthy"
eq "unknown tick3 -> healthy" "$(assess)" "healthy"
eq "  unknown keeps ticks=0" "$(state_get zero_ticks)" "0"

# ===== Task 4: heal ladder (mock side-effect commands + waits + busy) =====
do_start_container(){ HEAL_LOG+="start
"; }
do_restart_controller(){ HEAL_LOG+="restart
"; }
do_reboot_container(){ HEAL_LOG+="reboot
"; }
sleep_s(){ :; }
runners_busy_count(){ echo "$MOCK_BUSY"; }

HEAL_LOG=""; MOCK_CS=stopped MOCK_CA=active MOCK_ONLINE=0 MOCK_BUSY=0
heal >/dev/null; eq "stopped -> start" "$HEAL_LOG" "start
"

HEAL_LOG=""; MOCK_CS=running MOCK_CA=failed MOCK_ONLINE=0
heal >/dev/null; eq "controller dead -> restart" "$HEAL_LOG" "restart
"

HEAL_LOG=""; MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0 MOCK_BUSY=0
heal >/dev/null; eq "0 runners busy=0 -> restart+reboot" "$HEAL_LOG" "restart
reboot
"

HEAL_LOG=""; MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0 MOCK_BUSY=1
heal >/dev/null; eq "0 runners busy=1 -> NO reboot" "$HEAL_LOG" "restart
"

# ===== Task 5: notify state machine (mock email + clock) =====
MAIL_LOG=""; send_email(){ MAIL_LOG+="MAIL:$1
"; }
NOW=1000000; now_epoch(){ echo "$NOW"; }
ALERTS_ENABLED=1   # test the alert LOGIC (notify_send -> send_email); suppression tested at the end
# keep classify cheap for the mail body
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=0
state_set status healthy; state_set last_alert 0

MAIL_LOG=""; notify healthy; eq "healthy stays quiet" "$MAIL_LOG" ""

MAIL_LOG=""; notify down
case "$MAIL_LOG" in *"MAIL:🔴"*) ok "down -> alert";; *) no "down -> alert" "$MAIL_LOG" "🔴";; esac
eq "  status=down" "$(state_get status)" "down"

MAIL_LOG=""; NOW=$((NOW+60)); notify down; eq "cooldown suppresses" "$MAIL_LOG" ""

MAIL_LOG=""; NOW=$((NOW+COOLDOWN_SEC+1)); notify down
case "$MAIL_LOG" in *"MAIL:🔴"*) ok "re-alert after cooldown";; *) no "re-alert" "$MAIL_LOG" "🔴";; esac

MAIL_LOG=""; notify healthy
case "$MAIL_LOG" in *"MAIL:✅"*) ok "recovery mail";; *) no "recovery" "$MAIL_LOG" "✅";; esac
eq "  status=healthy" "$(state_get status)" "healthy"

# ===== Task 6: run_once E2E =====
# scenario A: steady healthy -> no heal, no mail
MOCK_CS=running MOCK_CA=active MOCK_ONLINE=2 MOCK_BUSY=0
state_set status healthy; state_set zero_ticks 0
HEAL_LOG=""; MAIL_LOG=""; run_once >/dev/null
eq "A: healthy no heal" "$HEAL_LOG" ""; eq "A: healthy no mail" "$MAIL_LOG" ""

# scenario B: controller dead, heal succeeds (restart brings it active+online) -> no mail
state_set status healthy; state_set zero_ticks 0
MOCK_CS=running MOCK_CA=failed MOCK_ONLINE=0
do_restart_controller(){ HEAL_LOG+="restart
"; MOCK_CA=active; MOCK_ONLINE=1; }
HEAL_LOG=""; MAIL_LOG=""; run_once >/dev/null
eq "B: healed via restart" "$HEAL_LOG" "restart
"; eq "B: no mail (recovered)" "$MAIL_LOG" ""

# scenario C: hard down, heal fails -> alert
state_set status healthy; state_set zero_ticks "$ZERO_TICKS_DOWN"
MOCK_CS=stopped MOCK_CA=failed MOCK_ONLINE=0
do_start_container(){ HEAL_LOG+="start
"; }   # start does NOT fix it (stays stopped)
HEAL_LOG=""; MAIL_LOG=""; run_once >/dev/null
case "$MAIL_LOG" in *"MAIL:🔴"*) ok "C: alert on heal-fail";; *) no "C: alert" "$MAIL_LOG" "🔴";; esac

# ===== ALERTS_ENABLED=0 suppresses e-mail (log-only, no notification) =====
ALERTS_ENABLED=0; state_set status healthy; MAIL_LOG=""; notify down >/dev/null
eq "ALERTS off -> no mail (log-only)" "$MAIL_LOG" ""

echo "----"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
