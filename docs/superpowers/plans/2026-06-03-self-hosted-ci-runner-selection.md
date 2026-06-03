# Self-Hosted CI — Smart-Hybrid Runner Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) or superpowers:subagent-driven-development to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the fleet CI run on free on-prem self-hosted runners (LXC-104) when GitHub-hosted minutes are exhausted, by fixing `decide-runner` to fail safe to self-hosted and removing the 2 hardcoded-hosted jobs — unblocking all `main` pipelines (incl. the pending deploy-tail/DT3).

**Architecture:** `decide-runner` (already `runs-on: [self-hosted,…]`) chooses the runner label; invert its fallbacks so the ONLY path to hosted is "billing readable AND minutes available". Convert the 2 reusable jobs that hardcode `ubuntu-latest` to `inputs.runner-label`. Drop RecyclageApp arm64 (amd64-only) to avoid QEMU OOM on the 4 GB runner.

**Tech Stack:** GitHub Actions reusable workflows + per-app thin callers, `actions/delete-package-versions`, LXC-104 self-hosted runners.

**Spec:** `docs/superpowers/specs/2026-06-03-self-hosted-ci-runner-selection-design.md`

**"Test" model for CI:** there is no unit test; the verification per task is (a) `actionlint` exit 0 (parse), and (b) observing the real run on self-hosted — `decide-runner` outputs the self-hosted label, downstream jobs dispatch to self-hosted (not billing-blocked), run goes green.

---

## File Structure

- `shared-workflows/.github/workflows/reusable-security-scan.yml` — 2 jobs (`codeql`:212, `dependency-review`:248) `runs-on` → `inputs.runner-label`. → **v1.4.1**.
- `Rechnungsapp/.github/workflows/build.yml` — `decide-runner` fallbacks `host`→`self`.
- `FootballApp/.github/workflows/build.yml` — same.
- `MitarbeiterApp/.github/workflows/build.yml` — same.
- `RecyclageApp/.github/workflows/build.yml` — same + `multi-arch: true`→`false`.

---

## Phase 1 — reusable-security-scan stragglers → v1.4.1

### Task 1.1: 2 hardcoded-hosted jobs → runner-label

**Files:** Modify `shared-workflows/.github/workflows/reusable-security-scan.yml` (`codeql` job ~line 212, `dependency-review` job ~line 248)

- [ ] **Step 1: Read both job `runs-on` lines** to get exact context:

Run: `grep -n "runs-on: ubuntu-latest" shared-workflows/.github/workflows/reusable-security-scan.yml`
Expected: two lines (codeql + dependency-review).

- [ ] **Step 2: Replace both** `runs-on: ubuntu-latest` with `runs-on: ${{ fromJSON(inputs.runner-label) }}` (use `replace_all` since both lines are identical and these are the only two in the file). New value:

```yaml
    runs-on: ${{ fromJSON(inputs.runner-label) }}
```

- [ ] **Step 3: Verify input exists.** `reusable-security-scan.yml` already declares `runner-label` (it is used by 5 other jobs). Confirm: `grep -n "runner-label:" shared-workflows/.github/workflows/reusable-security-scan.yml` shows the input declaration. No new input needed.

- [ ] **Step 4: actionlint**

Run: `cd shared-workflows && ./bin/actionlint.exe .github/workflows/reusable-security-scan.yml`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-security-scan.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "fix(ci): codeql + dependency-review honor runner-label (no hardcoded hosted) — full self-hosted capability"
```

### Task 1.2: Release v1.4.1 + move @v1

- [ ] **Step 1: Push + tag + move @v1**

```bash
cd shared-workflows
git push origin dev
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); DEVH=$(git rev-parse dev)
git -c user.name="$NAME" -c user.email="$EMAIL" tag -a v1.4.1 "$DEVH" -m "v1.4.1 — codeql/dependency-review runner-label (full self-hosted)"
git push origin v1.4.1
git tag -f v1 "$DEVH"; git push -f origin v1
git ls-remote origin refs/tags/v1 refs/tags/v1.4.1
```
Expected: both `refs/tags/v1` and `refs/tags/v1.4.1` point to `$DEVH`.

---

## Phase 2 — `decide-runner` fail-safe to self-hosted (4 callers)

The 4 callers share an identical `decide-runner` step script. The change in each: the **two fallback `host` calls become `self`**; the final computed `else host` (minutes available) stays `host`.

### Task 2.1: Invert fallbacks in each caller

**Files:** Modify `decide-runner` step in each: `Rechnungsapp`, `FootballApp`, `MitarbeiterApp`, `RecyclageApp` `/.github/workflows/build.yml`

- [ ] **Step 1 (per app): Read the decide-runner step** to confirm exact text:

Run: `grep -nE 'host "|self "|GH_PAT' <app>/.github/workflows/build.yml`

- [ ] **Step 2 (per app): Change the no-PAT fallback** — `host "kein RUNNER_SWITCH_PAT"; exit 0` → `self "kein RUNNER_SWITCH_PAT → on-prem default"; exit 0`. Exact edit:

old:
```bash
            host "kein RUNNER_SWITCH_PAT"; exit 0
```
new:
```bash
            self "kein RUNNER_SWITCH_PAT → on-prem default"; exit 0
```

- [ ] **Step 3 (per app): Change the billing-unreadable fallback** — `host "Billing nicht lesbar"; exit 0` → `self "Billing nicht lesbar → on-prem default"; exit 0`. Exact edit:

old:
```bash
            host "Billing nicht lesbar"; exit 0
```
new:
```bash
            self "Billing nicht lesbar → on-prem default"; exit 0
```

> If a caller's wording differs slightly (parallel-session drift), match its actual `host "<msg>"; exit 0` fallback lines and flip `host`→`self`. Do NOT change the final `else host "${REMAIN} Gratis-Min übrig…"` — that path (minutes confirmed available) must stay hosted.

- [ ] **Step 4: actionlint each** (`./bin/actionlint.exe` is in shared-workflows; for app callers use `python -m yamllint -d relaxed <app>/.github/workflows/build.yml` or actionlint if available). Expected: no parse error.

### Task 2.2: RecyclageApp amd64-only

**Files:** Modify `RecyclageApp/.github/workflows/build.yml`

- [ ] **Step 1: Flip multi-arch** — `multi-arch: true` → `multi-arch: false`.

### Task 2.3: Commit + push the 4 callers (dev)

- [ ] **Step 1 (per app):**

```bash
cd <app>
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "fix(runner): decide-runner fails safe to self-hosted (free on-prem when hosted minutes unavailable)"
git push origin dev
```
(RecyclageApp message also notes `multi-arch:false`.)

---

## Phase 3 — Merge to main + validate on self-hosted

### Task 3.1: Merge each dev→main

- [ ] **Step 1 (per app):**

```bash
cd <app>; git fetch origin --quiet
git checkout main; git reset --hard origin/main
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" merge --no-ff origin/dev -m "ci: self-hosted fail-safe runner selection dev→main"
# build.yml conflict → take dev: git checkout --theirs .github/workflows/build.yml; git add; git commit --no-edit
git push origin main
git checkout dev
```

### Task 3.2: Validate ONE pipeline end-to-end on self-hosted (Rechnungsapp)

- [ ] **Step 1: Find the Rechnungsapp main run + watch decide-runner output + run conclusion**

Run:
```bash
RID=$(gh api "repos/ADZA-Group/rechnungsapp/actions/runs?branch=main&per_page=3" --jq '[.workflow_runs[]|select(.name=="CI/CD")][0].id')
# wait for completion, then:
gh run view "$RID" -R ADZA-Group/rechnungsapp --json status,conclusion --jq '"\(.status)/\(.conclusion)"'
gh run view "$RID" -R ADZA-Group/rechnungsapp --json jobs --jq '.jobs[]|select(.conclusion=="failure")|"❌ \(.name)"'
```
Expected: `completed/success`, **zero billing-blocked jobs** (no "spending limit" message), `decide-runner` green, downstream jobs ran on self-hosted. This also confirms the pending **verify-prod** (deploy-tail/DT3) on prod `/health`.

- [ ] **Step 2: OOM check during the run**

Run: `ssh root@192.168.1.20 "pct exec 104 -- free -m | sed -n '2p'"`
Expected: free memory stays > ~300 MB (no OOM). If it crashes/OOMs → stop `proxmox-runner-3` (back to 2 runners) and/or note Risk #2 for follow-up.

### Task 3.3: Fleet verification

- [ ] **Step 1: Confirm all 4 apps' latest main run dispatched to self-hosted + no billing block**

Run (per app `ADZA-Group/rechnungsapp|footballapp|recyclage-app`, `azad-ahmed/MitarbeiterApp`):
```bash
gh run view "$RID" -R "$repo" --json conclusion,jobs --jq '.conclusion, ([.jobs[]|select(.conclusion=="failure")|.name])'
```
Expected: no job failed with the billing/"spending limit" message. Genuine app-test failures (if any) are separate and noted, not part of this fix.

- [ ] **Step 2:** Use `superpowers:verification-before-completion` before claiming done — cite the actual run conclusions.

---

## Self-review notes

- **Spec coverage:** §3.1 → Task 2.1; §3.2 → Task 1.1; §3.3 → Task 2.2; §3.4 (capacity/OOM) → Task 3.2 Step 2; §5 rollout → Phases 1-3. All covered.
- **`decide-runner` already runs-on self-hosted** (pushed earlier this session) — Phase 2 only fixes the fallback *direction*.
- **Gating:** Phase 3 merges touch `main` (prod rebuild via Watchtower; CI-config only, no app behaviour change). Confirm with the user before each main push per the session's gating agreement.
- **Order:** Phase 1 (v1.4.1) must be released + `@v1` moved before Phase 3 runs pick up the codeql/dep-review fix.
