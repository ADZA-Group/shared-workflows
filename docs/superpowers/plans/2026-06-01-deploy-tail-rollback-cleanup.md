# Deploy-Tail Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the existing prod auto-rollback fleet-wide, add a staging auto-rollback, and add post-success image cleanup (Watchtower `--cleanup` + GHCR prune) — all without SSH to the LXCs.

**Architecture:** Registry-re-tag rollback (`:previous`→`:latest`, `:staging-previous`→`:staging`) that Watchtower re-pulls; a `continue-on-error` GHCR-prune job that runs only on green deploys; per-app caller wiring (`prod-url`/`deploy-prod`) and per-app compose wiring (`--cleanup`).

**Tech Stack:** GitHub Actions reusable workflows + composite actions, `docker buildx imagetools`, `actions/delete-package-versions`, nickfedor/watchtower, Cloudflare-exposed health URLs.

**Spec:** `docs/superpowers/specs/2026-06-01-deploy-tail-rollback-cleanup-design.md`

---

## File Structure

**shared-workflows (→ tag v1.4.0):**
- Modify `.github/workflows/reusable-docker-build.yml` — add `:staging-previous` backup (dev).
- Modify `.github/workflows/reusable-ci.yml` — restructure `verify-staging` (rollback) + new `prune-ghcr` job + 2 new inputs.

**App callers:**
- Modify `Rechnungsapp/.github/workflows/build.yml` — `prod-url` + `deploy-prod: true`.
- Modify `FootballApp/.github/workflows/build.yml` — `prod-url` + `deploy-prod: true` (keep the `decide-runner` job).
- Modify `RecyclageApp/.github/workflows/build.yml` — `prod-url` (only if public).
- MitarbeiterApp — deferred (Phase 0, no live prod LXC).

**App composes (LXC-side `--cleanup`):**
- Modify `Rechnungsapp/docker-compose.staging.yml` + prod compose — watchtower `--cleanup`.
- Modify `FootballApp/docker-compose.prod.yml` — watchtower `--cleanup`.
- Modify `RecyclageApp/docker-compose.postgres.yml` — migrate `containrrr`→`nickfedor` + config.json mount + `--cleanup`.

---

## Phase 1 — Reusable changes (shared-workflows → v1.4.0)

### Task 1.1: `:staging-previous` backup (dev)

**Files:**
- Modify: `shared-workflows/.github/workflows/reusable-docker-build.yml` (after the `:previous` backup step, ~line 212)

- [ ] **Step 1: Add the dev backup step** immediately after the existing `Backup :latest -> :previous (main only)` step:

```yaml
      - name: "Backup :staging -> :staging-previous (dev only)"
        if: ${{ inputs.push && github.ref == 'refs/heads/dev' }}
        continue-on-error: true
        run: |
          if docker buildx imagetools inspect ${{ inputs.image-name }}:staging >/dev/null 2>&1; then
            docker buildx imagetools create --tag ${{ inputs.image-name }}:staging-previous ${{ inputs.image-name }}:staging
            echo "::notice::backed up :staging -> :staging-previous"
          else
            echo "::notice::no existing :staging to back up (first push)"
          fi
```

- [ ] **Step 2: Validate it parses**

Run: `cd shared-workflows && ./bin/actionlint.exe .github/workflows/reusable-docker-build.yml`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-docker-build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): backup :staging->:staging-previous on dev (staging rollback target)"
```

### Task 1.2: Staging auto-rollback in `verify-staging`

**Files:**
- Modify: `shared-workflows/.github/workflows/reusable-ci.yml:567-583` (the `verify-staging` job steps)

- [ ] **Step 1: Replace the `verify-staging` `steps:` block** (currently a single health-check) with the verify-prod-mirrored rollback structure:

```yaml
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: adza-group/shared-workflows/.github/actions/health-check@v1
        id: staging-check
        continue-on-error: true
        with:
          url: ${{ inputs.staging-url }}
          max-retries: "40"
          retry-delay: "30"
          check-security-headers: "true"

      - name: Auto-rollback on failure
        if: steps.staging-check.outcome == 'failure'
        run: |
          IMAGE="${{ inputs.image-name != '' && inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}"
          echo "::warning::staging unhealthy — attempting rollback :staging-previous -> :staging"
          if docker buildx imagetools inspect "${IMAGE}:staging-previous" >/dev/null 2>&1; then
            docker buildx imagetools create --tag "${IMAGE}:staging" "${IMAGE}:staging-previous"
            echo "::warning::rollback applied — watchtower will re-deploy :staging-previous on next poll"
          else
            echo "::warning::no :staging-previous tag found — rollback skipped"
          fi

      - name: Fail on staging unhealthy
        if: steps.staging-check.outcome == 'failure'
        run: exit 1
```

- [ ] **Step 2: Confirm the gate invariant holds.** `require-staging-green` (line ~585) reads `needs.verify-staging.result`. The new final `exit 1` keeps the job `failure` on unhealthy staging → gate still blocks main push. No change needed to `require-staging-green`.

- [ ] **Step 3: Validate**

Run: `cd shared-workflows && ./bin/actionlint.exe .github/workflows/reusable-ci.yml`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): staging auto-rollback (:staging-previous re-tag) mirroring verify-prod"
```

### Task 1.3: `prune-ghcr` job + inputs

**Files:**
- Modify: `shared-workflows/.github/workflows/reusable-ci.yml` (inputs block ~line 130; new job after `verify-prod` ~line 653)

- [ ] **Step 1: Add two inputs** to the `workflow_call.inputs` block:

```yaml
      enable-ghcr-prune:
        required: false
        type: boolean
        default: true
        description: "Prune old GHCR versions after a successful deploy"
      ghcr-keep-versions:
        required: false
        type: number
        default: 3
        description: "Number of recent tagged GHCR versions to keep"
```

- [ ] **Step 2: Add the `prune-ghcr` job** after `verify-prod`:

```yaml
  prune-ghcr:
    name: "🧹 Prune GHCR"
    needs: [docker-build, verify-staging, verify-prod]
    if: >-
      ${{ always() && inputs.enable-ghcr-prune && github.event_name == 'push' &&
      needs.docker-build.result == 'success' &&
      needs.verify-staging.result != 'failure' &&
      needs.verify-prod.result != 'failure' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    permissions:
      packages: write
    steps:
      # SAFE sweep first: untagged manifests only — never touches :latest/:staging/:previous/:staging-previous.
      - name: Delete untagged versions
        continue-on-error: true
        uses: actions/delete-package-versions@e5bc658cc4c965c472efe991f8beea3981499c55  # v5.0.0
        with:
          package-name: ${{ inputs.app-name }}
          package-type: container
          delete-only-untagged-versions: "true"
          min-versions-to-keep: 0
```

> NOTE: the keep-last-N **tagged** prune is intentionally NOT enabled in this step — it is gated behind Task 4.2 (multi-arch safety validation). The untagged sweep is always safe and reclaims the bulk of the space (each multi-arch push leaves dangling untagged manifests).
>
> ⚠️ **SHA must be verified before commit:** the `@e5bc658…# v5.0.0` pin above is illustrative. Resolve the real SHA for the latest `actions/delete-package-versions` release (`gh api repos/actions/delete-package-versions/git/refs/tags/v5.0.0 --jq .object.sha`, or the current major) and pin THAT, per the repo's SHA-pinning policy. Do not commit an unverified SHA.

- [ ] **Step 3: Add `prune-ghcr` to the `telemetry` job `needs:` list** (line ~655) so it shows in the run summary. Append `, prune-ghcr` to the existing `needs: [...]` array.

- [ ] **Step 4: Validate**

Run: `cd shared-workflows && ./bin/actionlint.exe .github/workflows/reusable-ci.yml`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/reusable-ci.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(ci): prune-ghcr job (untagged sweep, green-deploy-only, continue-on-error) + inputs"
```

### Task 1.4: Release v1.4.0 + validate + move @v1

- [ ] **Step 1: Push dev**

```bash
cd shared-workflows && git push origin dev
```

- [ ] **Step 2: Tag v1.4.0 + move floating @v1**

```bash
cd shared-workflows
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); DEVH=$(git rev-parse dev)
git -c user.name="$NAME" -c user.email="$EMAIL" tag -a v1.4.0 "$DEVH" -m "v1.4.0 — staging rollback + prune-ghcr (untagged sweep) + :staging-previous backup"
git push origin v1.4.0
git tag -f v1 "$DEVH"
git push -f origin v1
git ls-remote origin refs/tags/v1 refs/tags/v1.4.0   # verify both → DEVH
```

- [ ] **Step 3: Validate on Rechnungsapp dev** (empty commit forces a fresh run on @v1=v1.4.0; the new staging-backup + prune jobs only fire on push):

```bash
cd Rechnungsapp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit --allow-empty -m "ci: re-trigger on @v1=v1.4.0 (prune-ghcr validation)"
git push origin dev
```

- [ ] **Step 4: Verify the run** — `prune-ghcr` ran + is green (or skipped), nothing red:

Run: `RID=$(gh api "repos/ADZA-Group/rechnungsapp/actions/runs?branch=dev&per_page=5" --jq '[.workflow_runs[]|select(.name=="CI/CD")][0].id'); gh run view "$RID" -R ADZA-Group/rechnungsapp --json conclusion,jobs --jq '.conclusion, (.jobs[]|select(.name|contains("Prune"))|.conclusion)'`
Expected: `success` + prune-ghcr `success`.

---

## Phase 2 — Per-app rollback wiring (callers)

### Task 2.1: Rechnungsapp prod-url + deploy-prod

**Files:** Modify `Rechnungsapp/.github/workflows/build.yml:25-27`

- [ ] **Step 1: Set the two values** in the `with:` block:

```yaml
      coverage-threshold: 49
      enable-redis: true
      install-system-deps: true
      deploy-prod: true
      staging-url: "https://i-rechnungsapp.adza-group.ch"
      prod-url: "https://rechnungsapp.adza-group.ch"
```

- [ ] **Step 2: Commit + push dev**

```bash
cd Rechnungsapp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci: activate prod auto-rollback (prod-url + deploy-prod)"
git push origin dev
```

- [ ] **Step 3: Verify dev run green** (prod-verify only runs on main; dev run must stay green): `gh run list -R ADZA-Group/rechnungsapp --branch dev --limit 1 --json conclusion`. Expected `success`.

### Task 2.2: FootballApp prod-url + deploy-prod

**Files:** Modify `FootballApp/.github/workflows/build.yml:85-87` (the `ci` job `with:` — keep the `decide-runner` job + `needs: decide-runner` untouched)

- [ ] **Step 1: Change the values** (currently `deploy-prod: false`, `prod-url: ""`):

```yaml
      deploy-prod: true
      staging-url: ""
      prod-url: "https://footballapp.adza-group.ch"
```

- [ ] **Step 2: Commit + push dev**

```bash
cd FootballApp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci: activate prod auto-rollback (prod-url + deploy-prod)"
git push origin dev
```

- [ ] **Step 3: Verify dev run green**: `gh run list -R ADZA-Group/footballapp --branch dev --limit 1 --json conclusion`. Expected `success`.

### Task 2.3: RecyclageApp prod-url (only if public)

**Files:** Modify `RecyclageApp/.github/workflows/build.yml`

- [ ] **Step 1: Determine the prod URL.** Check whether RecyclageApp is Cloudflare-exposed:

Run: `ssh root@192.168.1.20 "pct exec 100 -- cat /etc/cloudflared/config.yml 2>/dev/null | grep -i recycl"` (LXC 100 = cloudflare tunnel)
- If a public hostname exists (e.g. `recyclage.adza-group.ch`) → set `prod-url: "https://<that>"`.
- If NONE (LAN-only) → **leave `prod-url` unset/empty**; prod-rollback stays skipped (the ubuntu runner cannot reach a LAN URL). Staging-rollback + prune + `--cleanup` still apply. Document the decision in the commit message.

- [ ] **Step 2: Apply + commit + push dev** (only if a public URL was found):

```bash
cd RecyclageApp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add .github/workflows/build.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci: activate prod auto-rollback (prod-url) — RecyclageApp"
git push origin dev
```

### Task 2.4: MitarbeiterApp — deferred

- [ ] **Step 1: Document deferral.** MitarbeiterApp is Phase 0 (prod LXC TBD). Add a `# TODO(deploy-tail): set prod-url + deploy-prod:true once prod LXC is live (mitarbeiter.adza-group.ch)` comment above the `with:` block in `MitarbeiterApp/.github/workflows/build.yml`, commit + push dev. No functional change.

---

## Phase 3 — Cleanup wiring (composes, LXC-side `--cleanup`)

### Task 3.1: Rechnungsapp watchtower --cleanup

**Files:** Modify `Rechnungsapp/docker-compose.staging.yml` + the prod compose (find via `ls Rechnungsapp/docker-compose*.yml`)

- [ ] **Step 1: Read the watchtower service** (`grep -n -A12 "watchtower:" Rechnungsapp/docker-compose.staging.yml`) and add `--cleanup` to its `command:` (Watchtower args). Example shape:

```yaml
  watchtower:
    image: nickfedor/watchtower:latest
    command: ["--cleanup", "--label-enable", "--interval", "300"]
```

(Preserve existing args; just add `--cleanup` if absent.)

- [ ] **Step 2: Commit + push dev**

```bash
cd Rechnungsapp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add docker-compose.staging.yml docker-compose.yml 2>/dev/null
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "chore(deploy): watchtower --cleanup (auto-remove old image on update)"
git push origin dev
```

- [ ] **Step 3: Apply on the LXC** (one-time, manual — No-SSH from CI by design):

Run: `ssh root@192.168.1.203 "cd /opt/rechnungsapp && docker compose up -d watchtower"` (staging) and the prod LXC `192.168.1.103` analogously after dev→main.

### Task 3.2: FootballApp watchtower --cleanup

**Files:** Modify `FootballApp/docker-compose.prod.yml` (watchtower service ~line 132)

- [ ] **Step 1: Add `--cleanup`** to the watchtower `command:` (read `grep -n -A12 "watchtower:" FootballApp/docker-compose.prod.yml` first; it already uses the nickfedor fork).

- [ ] **Step 2: Commit + push dev**

```bash
cd FootballApp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add docker-compose.prod.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "chore(deploy): watchtower --cleanup"
git push origin dev
```

- [ ] **Step 3: Apply on LXC 105**: `ssh root@192.168.1.5 "cd /opt/footballapp && docker compose up -d watchtower"` (after dev→main).

### Task 3.3: RecyclageApp — migrate containrrr→nickfedor + config.json + --cleanup

**Files:** Modify `RecyclageApp/docker-compose.postgres.yml:78-90` (watchtower service)

- [ ] **Step 1: Read the current watchtower service**: `grep -n -A15 "watchtower:" RecyclageApp/docker-compose.postgres.yml`.

- [ ] **Step 2: Replace `containrrr/watchtower:1.7.1`** with the active fork + cleanup + private-GHCR creds mount (per the known 403 gotcha):

```yaml
  watchtower:
    image: nickfedor/watchtower:latest
    container_name: watchtower
    command: ["--cleanup", "--label-enable", "--interval", "300"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /root/.docker/config.json:/config.json:ro
    restart: unless-stopped
```

(Preserve any other existing keys like `environment`/`networks`.)

- [ ] **Step 3: Commit + push dev**

```bash
cd RecyclageApp
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git add docker-compose.postgres.yml
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "chore(deploy): migrate watchtower containrrr(EOL)->nickfedor + --cleanup + config.json mount"
git push origin dev
```

- [ ] **Step 4: Apply on LXC 102** (prod) — ensure `/root/.docker/config.json` exists (`echo $(gh auth token) | docker login ghcr.io -u <user> --password-stdin`) then `docker compose up -d watchtower`.

---

## Phase 4 — Validation (the 3 spec risks)

### Task 4.1: GHCR-prune permission test (Risk #1)

- [ ] **Step 1:** After Task 1.4's Rechnungsapp run, read the `prune-ghcr` job log:

Run: `RID=$(gh api "repos/ADZA-Group/rechnungsapp/actions/runs?branch=dev&per_page=5" --jq '[.workflow_runs[]|select(.name=="CI/CD")][0].id'); JID=$(gh run view "$RID" -R ADZA-Group/rechnungsapp --json jobs --jq '.jobs[]|select(.name|contains("Prune"))|.databaseId'); gh api "repos/ADZA-Group/rechnungsapp/actions/jobs/$JID/logs" | grep -iE "deleted|403|not accessible|forbidden|error"`

- [ ] **Step 2:** If `403`/`not accessible` → `GITHUB_TOKEN` lacks org-package delete. Fix: create a PAT with `delete:packages`, add as repo/org secret `GHCR_CLEANUP_TOKEN`, and pass `token: ${{ secrets.GHCR_CLEANUP_TOKEN }}` to the `delete-package-versions` step (add `GHCR_CLEANUP_TOKEN` to `secrets:` in the caller + `secrets: inherit`). Re-run, confirm deletions logged. If you prefer not to add a PAT, set `enable-ghcr-prune: false` per caller and rely on `reusable-weekly-cleanup.yml` — document the choice.

### Task 4.2: Multi-arch keep-N safety (Risk #2)

- [ ] **Step 1:** After a successful prune, confirm the kept image still pulls (all arches):

Run: `docker buildx imagetools inspect ghcr.io/adza-group/rechnungsapp:staging` (lists the manifest list; both `linux/amd64` + `linux/arm64` must be present).
Expected: manifest list intact.

- [ ] **Step 2:** ONLY if Step 1 passes AND you want the aggressive keep-last-3 tagged prune: add a second `delete-package-versions` step with `min-versions-to-keep: ${{ inputs.ghcr-keep-versions }}` + `ignore-versions: '^(latest|staging|previous|staging-previous)$'`, push as a v1.4.1, and **re-run Step 1** to confirm `:staging`/`:latest` still pull. If the manifest list breaks → revert to untagged-only sweep (Task 1.3 default) and document that keep-N-tagged is unsafe with multi-arch on this action version.

### Task 4.3: Deliberate-fail rollback test (staging)

- [ ] **Step 1:** On Rechnungsapp dev, temporarily point the health check at a guaranteed-404 path by setting `staging-url: "https://i-rechnungsapp.adza-group.ch/__nope__"` in the caller, commit + push dev.

- [ ] **Step 2:** Watch the run — `verify-staging` health-check fails → "Auto-rollback" step re-tags `:staging-previous`→`:staging` → job fails (expected).

Run: `RID=$(gh api "repos/ADZA-Group/rechnungsapp/actions/runs?branch=dev&per_page=3" --jq '[.workflow_runs[]|select(.name=="CI/CD")][0].id'); gh run view "$RID" -R ADZA-Group/rechnungsapp --json jobs --jq '.jobs[]|select(.name|contains("Verify Staging"))|.conclusion'`
Expected: `failure` (with the rollback warning in the log).

- [ ] **Step 3: Revert** the `staging-url` back to `https://i-rechnungsapp.adza-group.ch`, commit + push dev, confirm green. (Verifies the rollback path end-to-end without leaving staging broken.)

---

## Self-review notes (for the executor)

- Rollback re-tags run on the **runner** (need `docker buildx` — present on ubuntu + self-hosted). They do NOT touch the LXC.
- `prune-ghcr` + both rollback re-tag steps are `continue-on-error` where they must never break the pipeline; the verify jobs still **fail** so failures surface.
- Order matters: **Phase 1 must be released (v1.4.0, @v1 moved) before Phase 2/3 runs** pick it up.
- MitarbeiterApp is intentionally deferred (no live prod).
