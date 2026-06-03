# Self-Hosted CI — Smart-Hybrid Runner Selection (self-hosted-default)

- **Date:** 2026-06-03
- **Scope:** 4 app callers (`decide-runner` logic) + `shared-workflows/reusable-security-scan.yml` (2 jobs) + RecyclageApp caller (`multi-arch`). Release → **v1.4.1**.
- **Status:** approved design (brainstorming), pending implementation plan (recommended in a fresh session).

## 1. Goal

Make the ADZA fleet CI run reliably on **on-prem self-hosted runners (LXC-104)** with **zero dependency on GitHub-hosted Actions minutes**, while still using free hosted minutes opportunistically *when they are confirmed available*. Trigger: GitHub free Actions minutes for `ADZA-Group` were exhausted (2126/2000 used, $0 spending limit) → every hosted-runner job `startup_failure`d ("spending limit needs to be increased") → entire fleet `main` CI red.

**Success:** with hosted minutes exhausted, a normal `dev`/`main` push runs the full pipeline on self-hosted runners and goes green (no `startup_failure`, no billing block).

## 2. Current state (verified evidence)

- `gh api organizations/ADZA-Group/settings/billing/usage` → **used 2126 / included 2000 minutes, net $0** → hosted runners blocked org-wide.
- `decide-runner` (per-app `build.yml`, parallel-session feature) runs the runner choice. It already runs on `[self-hosted,linux,proxmox]` (fixed earlier this session) and the online `proxmox-runner` accepts jobs (3 of 4 runners now online; runner-4 left off to stay under the 4-runner / 4 GB OOM line — GOTCHA #4).
- **BUG:** `decide-runner` cannot read the enhanced-billing usage API with `RUNNER_SWITCH_PAT` → hits its fallback `host "Billing nicht lesbar"; exit 0` → outputs **hosted** → all `runner-label`-driven jobs land on hosted → billing-blocked. (Confirmed: `Detect Changes` failed with the spending-limit message; the `host` fallback line is in the job log.)
- **Scope reality (grep of all reusables):** **37 jobs already use `runs-on: ${{ fromJSON(inputs.runner-label) }}`** (follow the caller's choice); only **2 jobs hardcode `runs-on: ubuntu-latest`** — `codeql` (`reusable-security-scan.yml:212`) and `dependency-review` (`:248`); 3 utility workflows already pin `[self-hosted,linux,proxmox]`. So the architecture already supports self-hosted; only the *selection* and 2 stragglers are wrong.
- RecyclageApp caller sets `multi-arch: true` (amd64+arm64). The prod LXC (102) is amd64; arm64 is unused and QEMU-emulated arm64 builds OOM on a 4 GB self-hosted runner.

## 3. Design

### 3.1 `decide-runner` fail-safe to self-hosted (4 app callers)
Invert the fallback direction so **self-hosted is the safe default** and hosted is chosen *only when proven cheap-and-available*:
- `if [ -z "${GH_PAT:-}" ]` → call **`self`** (was `host`) — "no PAT → on-prem default".
- billing-unreadable branch → call **`self`** (was `host`) — "billing unreadable → on-prem default".
- keep the computed branch: `if remain ≤ threshold || paid==1 → self; else → host`.
- Net: the **only** path to `host` is *PAT set AND billing readable AND remain > threshold AND not paid*. Every other path (no PAT, unreadable, low minutes, any error) → **self**.
- Because the PAT currently can't read billing, this correctly yields **self-hosted now**; if a billing-capable PAT is later added and minutes are available, it transparently uses hosted again. (decide-runner itself already `runs-on: [self-hosted,linux,proxmox]`.)

### 3.2 Two hardcoded-hosted jobs → runner-label (`reusable-security-scan.yml`)
`codeql` (line 212) and `dependency-review` (line 248): `runs-on: ubuntu-latest` → `runs-on: ${{ fromJSON(inputs.runner-label) }}`. They then follow the chosen runner. Both are advisory (`continue-on-error`); CodeQL is `upload: false` (analysis only, no GHAS dependency).

### 3.3 RecyclageApp: drop arm64 (`multi-arch: false`)
Caller `multi-arch: true` → `false`. amd64-only matches the only deploy target, removes the QEMU-arm64 OOM risk on self-hosted, and makes RecyclageApp's GHCR image single-arch (so the `prune-ghcr` untagged sweep is safe to enable there later — closes the earlier multi-arch-prune caveat).

### 3.4 Runner capacity (operational, LXC-104)
3 runners online (`proxmox-runner`, `-2`, `-3`); `proxmox-runner-4` stays stopped to keep ≤3 concurrent heavy jobs on 4 GB (GOTCHA #4 OOM line). Baseline free mem ~3688 MB. The reusable-ci test-matrix + parallel jobs queue across the 3 runners → slower than hosted but free. Monitor `free -m` under load.

## 4. Risks / explicit validation points

1. **CodeQL on a 4 GB self-hosted runner** may be slow or OOM (it is RAM-hungry). It is advisory, so failure won't block — but if it OOMs the runner it could disrupt neighbours. Validation: watch one run's CodeQL on self-hosted + `free -m`. Fallback (follow-up, not v1): a `skip-codeql-on-self-hosted` input guard.
2. **3 concurrent heavy jobs on 4 GB** (e.g., docker-build + 2 test shards) may OOM. Validation: `free -m` during a full pipeline. Mitigation (follow-up): cap test-matrix `max-parallel`, or raise LXC-104 RAM.
3. **Runner reliability** — historically flaky/zombie (GOTCHA #4); the online `proxmox-runner` currently accepts jobs (pilot-proven). If runs hang "queued", a runner re-registration is needed.
4. **Self-hosted pipeline duration** — full fleet (4 apps × dev+main) on 3 runners will take significantly longer than hosted; not all may complete in one sitting.

## 5. Rollout

1. `shared-workflows`: §3.2 → commit on `dev`, actionlint, tag **v1.4.1**, move floating `@v1`, verify `ls-remote`.
2. App callers (`dev`): §3.1 in all 4 `build.yml` (`decide-runner` fallbacks → self); §3.3 in RecyclageApp.
3. Merge each `dev→main` (the `decide-runner` + multi-arch changes are CI-config/build-config; RecyclageApp `multi-arch:false` changes the image arch — acceptable, amd64-only).
4. Validate: one full pipeline per app goes green on self-hosted (decide-runner → self-hosted → all jobs self-hosted → no billing block). This also confirms the still-pending **DT3 verify-prod** and the **deploy-tail (v1.4.0)** on `main`.

## 6. Non-goals (YAGNI)

- Fixing `RUNNER_SWITCH_PAT` billing-read scope — the fail-safe default makes it unnecessary; add a billing-capable PAT later only if hosted-when-available is wanted.
- `skip-codeql-on-self-hosted` guard — only if Risk #1 materialises.
- LXC-104 RAM upgrade / test-matrix `max-parallel` cap — only if Risk #2 materialises.
- Re-architecting away from `decide-runner` — the smart-hybrid is retained per the chosen approach.

## 7. Relationship to in-flight work

The deploy-tail feature (v1.4.0: rollback + prune) and DT3 (prod-rollback activation, `/health` URLs) are **already merged + dev-validated**; their `main`-run confirmation is blocked only by this billing/runner issue and will go green once this design lands. The earlier-pushed `decide-runner runs-on: self-hosted` change (this session) is the prerequisite half of §3.1; this spec completes it by fixing the fallback *direction*.
