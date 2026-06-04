#!/usr/bin/env bash
# Unit tests for prewarmer.sh — pure bash, mocks all external calls (billing/pct).
# Run: bash infra/runner-prewarmer/test_prewarmer.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1 (got '$2' want '$3')"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

export PREWARMER_ENV=/dev/null
export PREWARMER_LIB=1
# shellcheck disable=SC1091
. "$HERE/prewarmer.sh"

# ===== Task 1 =====
eq "lib-mode: log() defined" "$(type -t log)" "function"

# ===== Task 2: compute_floor (mock the jq-using wrapper + token) =====
billing_used_minutes(){ echo "$MOCK_USED"; }

GH_TOKEN=t MOCK_USED=100;   eq "viel Rest -> 1"          "$(compute_floor)" "1"
GH_TOKEN=t MOCK_USED=1700;  eq "wenig Rest -> count"     "$(compute_floor)" "3"
GH_TOKEN=t MOCK_USED=1600;  eq "exakt Schwelle -> count" "$(compute_floor)" "3"
GH_TOKEN=t MOCK_USED=-1;    eq "unlesbar -> 1"           "$(compute_floor)" "1"
GH_TOKEN="" MOCK_USED=1700; eq "kein Token -> 1"         "$(compute_floor)" "1"

# ===== Task 3: write_floor + main (mock the pct-exec writer) =====
pct_write_floor(){ WRITE_LOG="floor=$1"; }

GH_TOKEN=t MOCK_USED=1700; WRITE_LOG=""; main >/dev/null
eq "main low -> writes floor=3" "$WRITE_LOG" "floor=3"

GH_TOKEN=t MOCK_USED=100; WRITE_LOG=""; main >/dev/null
eq "main plenty -> writes floor=1" "$WRITE_LOG" "floor=1"

GH_TOKEN="" MOCK_USED=1700; WRITE_LOG=""; main >/dev/null
eq "main no-token -> floor=1" "$WRITE_LOG" "floor=1"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
