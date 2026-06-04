# runner-prewarmer (M2-Komp.2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein externer Pre-Warmer auf dem Proxmox-Host hält bei knappen GitHub-Gratis-Minuten proaktiv mehr self-hosted Runner warm (kein Kaltstart-Stau), indem er einen `min-floor` in LXC104 schreibt, den der runner-controller liest.

**Architecture:** Bash `prewarmer.sh` per systemd-Timer (5 Min) auf `192.168.1.20`. Fragt die Billing-Usage-API, mappt `remain` → `floor`, und schreibt den floor via `pct exec` INS LXC104 (Host-/run ≠ Container-/run!). Alle externen Calls in Wrapper-Funktionen → unit-testbar mit Mocks. Quelle in `shared-workflows/infra/runner-prewarmer/`, Muster identisch zu M1-Watchdog. **Der runner-controller (Parallel-Session) liest den floor — das ist ein dokumentierter 1-Zeilen-Koordinations-Task, nicht von uns gebaut.**

**Tech Stack:** Bash, systemd, GitHub REST billing-usage API (`curl`+`jq`), Proxmox `pct exec`.

**Spec:** `docs/superpowers/specs/2026-06-04-ci-load-manager-design.md` (§4, §6)

---

## File Structure (alle neu, additive)

| Datei | Verantwortung |
|---|---|
| `infra/runner-prewarmer/prewarmer.sh` | billing → `compute_floor` → `write_floor` (in 104); lib-guard |
| `infra/runner-prewarmer/test_prewarmer.sh` | Unit-Tests: mock billing/pct → floor-Mapping + write-Format |
| `infra/runner-prewarmer/.env.example` | Vorlage (GH_TOKEN + Schwellen), KEINE Secrets |
| `infra/runner-prewarmer/.gitattributes` | `eol=lf` (CRLF bräche Shebang/Units am Host) |
| `infra/runner-prewarmer/runner-prewarmer.service` | systemd oneshot |
| `infra/runner-prewarmer/runner-prewarmer.timer` | Timer (5 Min) |
| `infra/runner-prewarmer/README.md` | Deploy-Runbook + **Controller-Koordinations-Snippet** |

**Lib-Guard:** `prewarmer.sh` endet mit `if [ "${PREWARMER_LIB:-0}" != "1" ]; then main "$@"; fi`.
**Floor-Datei (in 104):** `/run/runner-controller/min-floor` (tmpfs; fehlt → Controller nutzt sein eigenes MIN).

---

## Task 1: Scaffold + lib-guard + config + env + gitattributes

**Files:**
- Create: `infra/runner-prewarmer/prewarmer.sh`
- Create: `infra/runner-prewarmer/test_prewarmer.sh`
- Create: `infra/runner-prewarmer/.env.example`
- Create: `infra/runner-prewarmer/.gitattributes`

- [ ] **Step 1: Write the failing test (lib-mode sourcing defines log)**

`infra/runner-prewarmer/test_prewarmer.sh`:
```bash
#!/usr/bin/env bash
# Unit tests for prewarmer.sh — pure bash, mocks all external calls.
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

eq "lib-mode: log() defined" "$(type -t log)" "function"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash infra/runner-prewarmer/test_prewarmer.sh`
Expected: FAIL — `prewarmer.sh` not found.

- [ ] **Step 3: Write minimal prewarmer.sh (config + log + lib-guard)**

`infra/runner-prewarmer/prewarmer.sh`:
```bash
#!/usr/bin/env bash
# /opt/runner-prewarmer/prewarmer.sh — proactively keep self-hosted runners warm
# when free GitHub minutes are low. Writes a min-floor into LXC104 for the
# runner-controller to honor. Spec: docs/superpowers/specs/2026-06-04-ci-load-manager-design.md
set -uo pipefail

: "${PREWARMER_ENV:=/opt/runner-prewarmer/.env}"
# shellcheck disable=SC1090
[ -f "$PREWARMER_ENV" ] && . "$PREWARMER_ENV"
: "${LXC_ID:=104}"
: "${GH_ORG:=ADZA-Group}"
: "${INCLUDED_MINUTES:=2000}"
: "${PREWARM_THRESHOLD:=400}"      # remain <= this -> warm more
: "${PREWARM_COUNT:=3}"            # how many to keep warm when low
: "${FLOOR_PATH:=/run/runner-controller/min-floor}"

log(){ echo "$(date -u +%FT%TZ) [prewarmer] $*"; }

main(){ log "noop (scaffold)"; }
if [ "${PREWARMER_LIB:-0}" != "1" ]; then main "$@"; fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash infra/runner-prewarmer/test_prewarmer.sh`
Expected: `ok: lib-mode: log() defined` … `PASS=1 FAIL=0`.

- [ ] **Step 5: Create `.env.example` + `.gitattributes`**

`infra/runner-prewarmer/.env.example`:
```bash
# Copy to /opt/runner-prewarmer/.env on the Proxmox host, chmod 600. NO secrets in git.
GH_TOKEN=ghp_xxx_readonly_actions_org
# tuning (defaults shown)
LXC_ID=104
GH_ORG=ADZA-Group
INCLUDED_MINUTES=2000
PREWARM_THRESHOLD=400
PREWARM_COUNT=3
```

`infra/runner-prewarmer/.gitattributes`:
```
*.sh       text eol=lf
*.service  text eol=lf
*.timer    text eol=lf
.env.example text eol=lf
```

- [ ] **Step 6: Commit**

```bash
git add infra/runner-prewarmer/prewarmer.sh infra/runner-prewarmer/test_prewarmer.sh infra/runner-prewarmer/.env.example infra/runner-prewarmer/.gitattributes
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(prewarmer): scaffold runner-prewarmer (lib-guard, config, env)"
```

---

## Task 2: billing wrappers + `compute_floor` (mapping)

**Files:**
- Modify: `infra/runner-prewarmer/prewarmer.sh`
- Modify: `infra/runner-prewarmer/test_prewarmer.sh`

- [ ] **Step 1: Write failing tests (floor mapping table)**

Append to `test_prewarmer.sh` before the summary:
```bash
# --- Task 2: compute_floor (mock billing_used_minutes + token) ---
billing_used_minutes(){ echo "$MOCK_USED"; }   # override the jq-using wrapper

GH_TOKEN=t MOCK_USED=100;  eq "viel Rest -> 1"        "$(compute_floor)" "1"   # remain 1900
GH_TOKEN=t MOCK_USED=1700; eq "wenig Rest -> count"   "$(compute_floor)" "3"   # remain 300 <=400
GH_TOKEN=t MOCK_USED=1600; eq "exakt Schwelle -> count" "$(compute_floor)" "3" # remain 400 <=400
GH_TOKEN=t MOCK_USED=-1;   eq "unlesbar -> 1"         "$(compute_floor)" "1"
GH_TOKEN="" MOCK_USED=1700; eq "kein Token -> 1"      "$(compute_floor)" "1"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-prewarmer/test_prewarmer.sh`
Expected: FAIL — `compute_floor` not found.

- [ ] **Step 3: Implement wrappers + compute_floor (insert above `main()`)**

```bash
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

# compute_floor: echoes desired warm-runner floor (1 normally, PREWARM_COUNT when minutes low)
compute_floor(){
  [ -z "${GH_TOKEN:-}" ] && { echo 1; return; }
  local used remain; used="$(billing_used_minutes)"
  [ "${used:--1}" -lt 0 ] && { echo 1; return; }
  remain=$(( INCLUDED_MINUTES - used ))
  if [ "$remain" -le "$PREWARM_THRESHOLD" ]; then echo "$PREWARM_COUNT"; else echo 1; fi
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-prewarmer/test_prewarmer.sh`
Expected: all 5 mapping cases `ok`, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-prewarmer/prewarmer.sh infra/runner-prewarmer/test_prewarmer.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(prewarmer): billing wrappers + compute_floor mapping"
```

---

## Task 3: `write_floor` (host→104) + `main` orchestration

**Files:**
- Modify: `infra/runner-prewarmer/prewarmer.sh`
- Modify: `infra/runner-prewarmer/test_prewarmer.sh`

- [ ] **Step 1: Write failing tests**

Append to `test_prewarmer.sh`:
```bash
# --- Task 3: write_floor + main (mock the pct-exec writer) ---
WRITE_LOG=""
pct_write_floor(){ WRITE_LOG="floor=$1"; }   # override real pct exec

GH_TOKEN=t MOCK_USED=1700; WRITE_LOG=""; main >/dev/null
eq "main low -> writes floor=3" "$WRITE_LOG" "floor=3"

GH_TOKEN=t MOCK_USED=100; WRITE_LOG=""; main >/dev/null
eq "main plenty -> writes floor=1" "$WRITE_LOG" "floor=1"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash infra/runner-prewarmer/test_prewarmer.sh`
Expected: FAIL — `pct_write_floor` / new `main` not found (old scaffold main writes nothing).

- [ ] **Step 3: Implement pct_write_floor + write_floor + main (replace scaffold main)**

```bash
# pct_write_floor: write the floor value into LXC104 atomically (host /run != container /run!)
pct_write_floor(){
  pct exec "$LXC_ID" -- sh -c "d=\$(dirname '$FLOOR_PATH'); mkdir -p \"\$d\"; t=\$(mktemp \"\$d/.floor.XXXX\"); printf '%s\n' '$1' > \"\$t\"; mv \"\$t\" '$FLOOR_PATH'"; }

write_floor(){ pct_write_floor "$1"; }

main(){
  local floor; floor="$(compute_floor)"
  log "floor=${floor} (threshold=${PREWARM_THRESHOLD} count=${PREWARM_COUNT})"
  write_floor "${floor}"
}
```

(Delete the old `main(){ log "noop (scaffold)"; }`.)

- [ ] **Step 4: Run to verify pass**

Run: `bash infra/runner-prewarmer/test_prewarmer.sh`
Expected: both main cases `ok`, final `PASS=… FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add infra/runner-prewarmer/prewarmer.sh infra/runner-prewarmer/test_prewarmer.sh
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(prewarmer): write_floor into LXC104 + main orchestration"
```

---

## Task 4: systemd unit + timer

**Files:**
- Create: `infra/runner-prewarmer/runner-prewarmer.service`
- Create: `infra/runner-prewarmer/runner-prewarmer.timer`

- [ ] **Step 1: Write the service**

`infra/runner-prewarmer/runner-prewarmer.service`:
```ini
[Unit]
Description=ADZA CI runner pre-warmer (min-floor by free GitHub minutes)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/runner-prewarmer/prewarmer.sh
Nice=15
TimeoutStartSec=60
```

- [ ] **Step 2: Write the timer**

`infra/runner-prewarmer/runner-prewarmer.timer`:
```ini
[Unit]
Description=Run ADZA CI runner pre-warmer every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Verify unit syntax (on host at deploy, or skip locally)**

Run (host): `systemd-analyze verify /etc/systemd/system/runner-prewarmer.{service,timer}`
Expected: no output (valid).

- [ ] **Step 4: Commit**

```bash
git add infra/runner-prewarmer/runner-prewarmer.service infra/runner-prewarmer/runner-prewarmer.timer
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(prewarmer): systemd service + 5-min timer"
```

---

## Task 5: README — deploy runbook + controller coordination snippet

**Files:**
- Create: `infra/runner-prewarmer/README.md`

- [ ] **Step 1: Write the README**

`infra/runner-prewarmer/README.md`:
````markdown
# runner-prewarmer (M2-Komp.2) — deploy + coordinate

Keeps self-hosted runners warm BEFORE the cost-switch flips to self-hosted, so the first
burst doesn't wait for cold starts. Runs on the **Proxmox host**; writes a `min-floor` into
LXC104 that the **runner-controller** honors. Spec: `docs/superpowers/specs/2026-06-04-ci-load-manager-design.md`.

## Prereqs (host)
- `jq` + `curl` (already installed for the watchdog).
- A read-only GitHub token (scope `read:org`) — same one the watchdog uses works.

## Deploy
```bash
ssh root@192.168.1.20
mkdir -p /opt/runner-prewarmer
install -m 0755 prewarmer.sh /opt/runner-prewarmer/prewarmer.sh
cp .env.example /opt/runner-prewarmer/.env && chmod 600 /opt/runner-prewarmer/.env
$EDITOR /opt/runner-prewarmer/.env          # set GH_TOKEN
install -m 0644 runner-prewarmer.service /etc/systemd/system/
install -m 0644 runner-prewarmer.timer   /etc/systemd/system/
systemctl daemon-reload
```

## ⚠️ COORDINATION REQUIRED before enabling the timer

The pre-warmer only HELPS once the `runner-controller` reads the floor. Until then it writes a
file nobody reads (harmless no-op). **Coordinate this 1-block change into
`/opt/runner-controller/runner-controller.sh`** (owned by the CI-power-up session), where it
computes how many runners to keep / its scale-down minimum:

```bash
# honor an external pre-warm floor (absent/unreadable -> no override)
FLOOR="$(cat /run/runner-controller/min-floor 2>/dev/null || echo 0)"
case "$FLOOR" in (*[!0-9]*|"") FLOOR=0 ;; esac          # only accept a plain integer
EFFECTIVE_MIN="$MIN_RUNNERS"
[ "$FLOOR" -gt "$EFFECTIVE_MIN" ] && EFFECTIVE_MIN="$FLOOR"
# ...then use $EFFECTIVE_MIN instead of $MIN_RUNNERS as the scale-down floor.
```

Once that line is in, enable:
```bash
systemctl enable --now runner-prewarmer.timer
systemctl start runner-prewarmer.service          # one tick
pct exec 104 -- cat /run/runner-controller/min-floor   # see the floor value
journalctl -u runner-prewarmer -n 10 --no-pager
```

## Operate
```bash
systemctl list-timers runner-prewarmer.timer
journalctl -u runner-prewarmer -n 20 --no-pager
pct exec 104 -- cat /run/runner-controller/min-floor
```
````

- [ ] **Step 2: Commit + push**

```bash
git add infra/runner-prewarmer/README.md
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "docs(prewarmer): deploy runbook + runner-controller coordination snippet"
git push origin dev
```

---

## Deferred (NOT in this plan — coordination/host)

- **Controller floor-read line** (snippet in README §COORDINATION) — owned by the CI-power-up
  session; insert in a quiet window, then enable the timer.
- **Host deploy + enable** — after the controller line lands (else harmless no-op).

---

## Self-Review (gegen Spec §4/§6)

- **§4 billing → floor mapping (remain≤400→3, sonst 1; kein Token→1; unlesbar→1)** → Task 2 (`compute_floor`, 5 Tests). ✅
- **§4 floor INS 104 schreiben (host /run ≠ container /run, atomar)** → Task 3 (`pct_write_floor` via `pct exec`, temp+mv). ✅
- **§4 Token aus eigener .env, read-only billing** → Task 1 (`.env.example`) + `gh_api` Bearer. ✅
- **§4 Controller liest floor (1 Zeile, max(MIN,floor), fehlt→kein Override)** → Task 5 README-Snippet (dokumentiert, nicht gebaut). ✅
- **§5 systemd, M1-Muster, LF** → Task 4 (units) + Task 1 (`.gitattributes`). ✅
- **§6 Tests: Zustandstabelle + write-Format** → Task 2 (mapping) + Task 3 (write_floor). ✅

**Placeholder scan:** keine TBD/TODO; voller Code in jedem Step. ✅
**Type/Name-Konsistenz:** `gh_api`/`billing_json`/`billing_used_minutes`/`compute_floor`/`pct_write_floor`/`write_floor`/`main` über Tasks konsistent; Mock-Override-Punkt (`billing_used_minutes`, `pct_write_floor`) genau die in main/compute_floor genutzten Funktionen. ✅
