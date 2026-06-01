# Deploy-Tail Hardening — Rollback Activation + Image/LXC Cleanup

- **Date:** 2026-06-01
- **Scope:** `shared-workflows` (`reusable-ci.yml` + `reusable-docker-build.yml`) → **v1.4.0**, plus per-app caller + compose wiring.
- **Status:** approved design (brainstorming), pending implementation plan.

## 1. Goal

Harden the deploy tail of the unified CI so that:

1. **Rollback on failure** — if the post-deploy health check (staging *or* prod) fails, the image is automatically rolled back to the previous good version. Registry-re-tag based (`:previous`→`:latest`, `:staging-previous`→`:staging`); **Watchtower re-pulls** the reverted tag. **No SSH** to the LXC.
2. **Cleanup on success** — after a successful deploy:
   - the **old local image on the LXC** is removed automatically (Watchtower `--cleanup`);
   - **old GHCR versions** are pruned (keep last 3 + rollback tags).

This makes the existing-but-dormant prod-rollback machinery **active fleet-wide** and **extends it to staging**, and adds the missing **cleanup**.

## 2. Current state (evidence from code)

- `reusable-docker-build.yml:203` — "Backup :latest → :previous (main only)" before pushing the new `:latest`. ✅ rollback target exists for prod.
- `reusable-ci.yml:624` (`verify-prod`) — on prod health-check failure: re-tag `:previous`→`:latest` (`docker buildx imagetools create`) + open incident issue + fail the run. ✅ prod rollback exists, **no SSH**.
- `verify-prod` runs only when `prod-url != '' && deploy-prod && ref==main`. **All 4 apps have `prod-url: ''`**, and 3 of 4 have `deploy-prod: false` → **prod rollback is dormant everywhere.**
- `verify-staging:567` — health-check **only**; no rollback, no `:staging-previous` backup.
- Cleanup today: only `reusable-weekly-cleanup.yml` (scheduled). **No per-deploy prune**, **no Watchtower `--cleanup`**.
- Watchtower images differ: **RecyclageApp = `containrrr/watchtower:1.7.1` (EOL since 2024-09)**; FootballApp already migrated off `containrrr`.

## 3. Design

### 3.1 Reusable changes (shared-workflows → v1.4.0)

**`reusable-docker-build.yml`** — add a step **"Backup :staging → :staging-previous (dev only)"** mirroring the existing `:previous` backup, gated on `push=true && ref==dev`. Gives the staging rollback a target.

**`reusable-ci.yml` → `verify-staging`** — restructure to mirror `verify-prod`:
- health-check step `id: staging-check`, `continue-on-error: true`;
- "Auto-rollback on failure" step (`if: steps.staging-check.outcome == 'failure'`): re-tag `:staging-previous`→`:staging` (skip with warning if no `:staging-previous`);
- final "Fail on staging unhealthy" step → `exit 1`.
- **Invariant preserved:** `require-staging-green` gates the main push on `needs.verify-staging.result`; after the rollback attempt the job still ends `failure` when staging is unhealthy, so the gate behaves exactly as today.

**`reusable-ci.yml` → new job `prune-ghcr`:**
- `needs: [docker-build, verify-staging, verify-prod]`;
- `if: always() && github.event_name == 'push' && needs.docker-build.result == 'success' && needs.verify-staging.result != 'failure' && needs.verify-prod.result != 'failure'` (prune **only** when nothing is broken);
- `permissions: { packages: write }`;
- uses `actions/delete-package-versions@<sha-pinned>`; package name derived from `image-name`;
- **`continue-on-error: true`** — cleanup must never fail the pipeline;
- **Tag-protection (explicit, unambiguous):** the live + rollback tags `:latest`, `:staging`, `:previous`, `:staging-previous` are **never** deleted (via the action's `ignore-versions` regex, or by keeping enough versions that those tags' digests survive). Beyond the protected tags: **keep the 3 newest remaining tagged versions** and **delete all untagged versions** (the dangling manifest leftovers). The exact `min-versions-to-keep` / `ignore-versions` / `delete-only-untagged-versions` parameter mapping is finalized + proven in **Risk #2 validation** (multi-arch manifests make raw version-counting unsafe).

### 3.2 Per-app wiring matrix

| App | `prod-url` | `deploy-prod` | Watchtower `--cleanup` | Notes |
|-----|-----------|---------------|------------------------|-------|
| **Rechnungsapp** | `https://rechnungsapp.adza-group.ch` | `true` | add `--cleanup` to watchtower svc | public ✓; pilot for GHCR-prune validation |
| **FootballApp** | `https://footballapp.adza-group.ch` | `true` (currently `false`) | already nickfedor → add `--cleanup` | public ✓; behaviour change (enables prod-verify) |
| **RecyclageApp** | confirm public hostname; **if LAN-only → leave `prod-url` empty** | keep `true` | **migrate `containrrr`→`nickfedor` + config.json mount** + `--cleanup` | EOL watchtower; if no public URL, prod-rollback skips (staging-rollback + GHCR-prune + `--cleanup` still apply) |
| **MitarbeiterApp** | `https://mitarbeiter.adza-group.ch` (once prod LXC is live) | `true` when live | add `--cleanup` | Phase 0 / prod LXC TBD → wiring may defer until live |

### 3.3 Safety logic

- `prune-ghcr` is `continue-on-error: true` **and** only runs when no verify failed → never cleans up a broken state, never breaks the pipeline.
- Rollback re-tag is `continue-on-error: true`, but the verify job still **fails** (surfacing + incident issue) so a rollback is never silent.
- `--cleanup` only removes images **superseded** by a successful pull → safe by Watchtower design.

## 4. Risks / explicit validation points

1. **GHCR delete permission:** `GITHUB_TOKEN` may not be allowed to delete **org-owned** package versions → may require a PAT secret. **Validate first on Rechnungsapp**; if it fails, fall back to a `GHCR_CLEANUP_TOKEN` secret (documented), else keep weekly-cleanup as the prune path.
2. **Multi-arch + keep-N:** each push creates multiple manifest versions; `min-versions-to-keep` must not orphan the arch-manifests of a kept tag. **Validate** that the kept `:latest`/`:staging` is still pullable after a prune run.
3. **RecyclageApp watchtower migration** (`containrrr`→`nickfedor`) is a prerequisite for reliable `--cleanup` and is also tied to the known private-GHCR 403 gotcha (needs `/root/.docker/config.json` mount). Done as part of this work for RecyclageApp.
4. **Health-check reachability:** `verify-prod`/`verify-staging` poll the URL **from the runner**. ubuntu runners reach **public Cloudflare** URLs only; a LAN-only prod URL is unreachable from ubuntu → prod-rollback only viable for publicly-exposed apps.

## 5. Rollout

1. shared-workflows: 2 files → tag **v1.4.0**, validate on Rechnungsapp dev, then move floating `@v1`.
2. App callers: set `prod-url` + `deploy-prod` per the matrix.
3. App composes: add watchtower `--cleanup` (+ RecyclageApp nickfedor migration); one-time `docker compose up -d watchtower` per LXC to apply.
4. **Validate:** one main deploy per public app (verify-prod green + `prune-ghcr` runs + kept image still pullable); one **deliberate-fail** rollback test on staging (temporary bad health path) to prove the re-tag + Watchtower revert.

## 6. Non-goals (YAGNI)

- **Drift-guard** for internal `@v1` pins — valuable but separate concern.
- **LXC system-wide `docker system prune` timer** — No-SSH path chosen; Watchtower `--cleanup` is sufficient for pull-based (no local builds) deploys.
- **SSH-based deploy** — keeps the clean registry-re-tag + Watchtower-pull model.
