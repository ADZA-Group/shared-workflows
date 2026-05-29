# Unified CI — Phase 2b: Complete `reusable-docker-build` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `reusable-docker-build.yml` from a build+scan stub (with dead `push`/`sign-image` inputs) into a senior-grade build → size-gate → Trivy-gate → smoke → SBOM → multi-arch push → cosign keyless sign → SLSA provenance → `:previous` backup workflow.

**Architecture:** One `build` job. It always builds a single-arch image **loaded** locally (for size-gate, Trivy, smoke, SBOM). When `push: true`, it then logs into GHCR, computes tags via `docker/metadata-action`, backs up `:latest`→`:previous` (main only), builds+pushes (multi-arch via qemu when `platforms` lists more than one), and when `sign-image: true` signs the pushed digest with keyless cosign + attaches SLSA build provenance. The two builds share the `type=gha` cache, so the push build is mostly cache-hits.

**Tech Stack:** GitHub reusable workflow, buildx, `docker/build-push-action@v7`, `docker/metadata-action`, `docker/login-action`, `docker/setup-qemu-action`, `aquasecurity/trivy-action`, `sigstore/cosign-installer`, `actions/attest-build-provenance`, `actionlint`, `yamllint`.

**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` §2.2 (docker-build is incomplete), §5.2 (complete docker-build), §6 (dual-gate + pinning).

---

## Critical constraints

1. **No expressions in `uses:` refs.** All action pins are literal SHAs (resolved below). This reusable references **no** ADZA composites (only marketplace actions), so it has no `@dev` cross-repo dependency — it only needs itself + a caller on GitHub to run.
2. **Dual-gate Trivy:** `exit-code: ${{ (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && '1' || '0' }}` + `ignore-unfixed: true`.
3. **Scan/smoke/SBOM run on the loaded single-arch (amd64) image** (`docker load` cannot hold multi-arch). For multi-arch pushes, amd64 is the scanned representative — documented, matches the sibling apps' practice.
4. **Validation deferred (local-only build):** local checks = `actionlint` + `yamllint`. Real run needs `dev` pushed (Task 3, deferred).
5. **Pins (resolved 2026-05-28):**
   - `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4`
   - `docker/setup-qemu-action@06116385d9baf250c9f4dcb4858b16962ea869c3  # v4.1.0`
   - `docker/setup-buildx-action@b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2  # v3` (reuse repo pin)
   - `docker/build-push-action@f9f3042f7e2789586610d6e8b85c8f03e5195baf  # v7.2.0`
   - `aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0`
   - `actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08  # v4.6.0`
   - `docker/login-action@650006c6eb7dba73a995cc03b0b2d7f5ca915bee  # v4.2.0`
   - `docker/metadata-action@80c7e94dd9b9319bd5eb7a0e0fe9291e23a2a2e9  # v6.1.0`
   - `sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6  # v4.1.2`
   - `actions/attest-build-provenance@v2` (first-party major tag per policy)

## Environment & rules
- Work from `C:\Users\ADZArecaclage\Documents\Projekte\shared-workflows`, branch `dev` (already checked out).
- Linters: `./bin/actionlint.exe <file>`, `python -m yamllint -d relaxed <file>`. These ARE workflows → actionlint validates expressions fully; must exit 0.
- Git: NO `git config`; inline identity `NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "..."`. No push. Explicit `git add <paths>` (untracked `bin/` stays untracked).

---

### Task 1: Rewrite `reusable-docker-build.yml`

**Files:**
- Overwrite: `.github/workflows/reusable-docker-build.yml`

- [ ] **Step 1: Replace the entire file** with this content (verbatim):

```yaml
# ═══════════════════════════════════════════════════════════════
# Reusable Docker Build / Scan / Push / Sign — ADZA-Group (senior)
#
# build(load) → size-gate → Trivy image scan (dual-gate) → smoke → SBOM
# and when push=true: GHCR login → metadata tags → :previous backup (main)
# → build+push (multi-arch) → cosign keyless sign + SLSA provenance.
#
# Usage:
#   uses: adza-group/shared-workflows/.github/workflows/reusable-docker-build.yml@v1
#   with:
#     image-name: ghcr.io/adza-group/my-app
#     push: true
#     sign-image: true
#     platforms: "linux/amd64,linux/arm64"
#   secrets: inherit
# ═══════════════════════════════════════════════════════════════

name: "🐳 Docker Build"

on:
  workflow_call:
    inputs:
      image-name:
        required: true
        type: string
        description: "Full image name (e.g. ghcr.io/adza-group/my-app)"
      dockerfile:
        required: false
        type: string
        default: "Dockerfile"
      context:
        required: false
        type: string
        default: "."
      runner-label:
        required: false
        type: string
        default: '["self-hosted", "linux", "proxmox"]'
      push:
        required: false
        type: boolean
        default: false
      platforms:
        required: false
        type: string
        default: "linux/amd64"
      image-size-limit-mb:
        required: false
        type: number
        default: 800
      run-trivy:
        required: false
        type: boolean
        default: true
      generate-sbom:
        required: false
        type: boolean
        default: true
      sign-image:
        required: false
        type: boolean
        default: false
      build-args:
        required: false
        type: string
        default: ""
      cache-from:
        required: false
        type: string
        default: "type=gha"
      smoke-command:
        required: false
        type: string
        description: "Optional shell command to smoke-test the loaded image ($IMAGE env = ci tag)"
        default: ""
      tag-config:
        required: false
        type: string
        description: "docker/metadata-action tags block"
        default: |
          type=ref,event=branch
          type=ref,event=tag
          type=sha,prefix={{branch}}-,format=short
          type=raw,value=latest,enable={{is_default_branch}}
    outputs:
      image-tag:
        description: "Local CI image tag (single-arch, loaded)"
        value: ${{ jobs.build.outputs.tag }}
      image-size-mb:
        description: "Image size in MB"
        value: ${{ jobs.build.outputs.size }}
      digest:
        description: "Pushed image digest (empty when push=false)"
        value: ${{ jobs.build.outputs.digest }}

jobs:
  build:
    name: "🐳 Build + Scan + Push/Sign"
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 30
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    outputs:
      tag: ${{ steps.localtag.outputs.tag }}
      size: ${{ steps.size.outputs.mb }}
      digest: ${{ steps.build-push.outputs.digest }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - name: Set up QEMU (multi-arch only)
        if: ${{ inputs.push && contains(inputs.platforms, ',') }}
        uses: docker/setup-qemu-action@06116385d9baf250c9f4dcb4858b16962ea869c3  # v4.1.0

      - uses: docker/setup-buildx-action@b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2  # v3

      - name: Build (single-arch, load for scan)
        uses: docker/build-push-action@f9f3042f7e2789586610d6e8b85c8f03e5195baf  # v7.2.0
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          push: false
          load: true
          tags: ${{ inputs.image-name }}:ci-${{ github.run_id }}
          cache-from: ${{ inputs.cache-from }}
          cache-to: type=gha,mode=max
          build-args: ${{ inputs.build-args }}

      - name: Local tag output
        id: localtag
        run: echo "tag=${{ inputs.image-name }}:ci-${{ github.run_id }}" >> "$GITHUB_OUTPUT"

      - name: "📏 Image Size Gate"
        id: size
        run: |
          REF="${{ inputs.image-name }}:ci-${{ github.run_id }}"
          SIZE_BYTES=$(docker image inspect "$REF" --format='{{.Size}}')
          MB=$((SIZE_BYTES / 1024 / 1024))
          LAYERS=$(docker image inspect "$REF" --format='{{len .RootFS.Layers}}')
          echo "mb=$MB" >> "$GITHUB_OUTPUT"
          {
            echo "## 🐳 Docker Image"
            echo "| Metric | Value |"
            echo "|--------|-------|"
            echo "| Size | **${MB} MB** |"
            echo "| Layers | ${LAYERS} |"
            echo "| Limit | ${{ inputs.image-size-limit-mb }} MB |"
          } >> "$GITHUB_STEP_SUMMARY"
          if [ "$MB" -gt "${{ inputs.image-size-limit-mb }}" ]; then
            echo "::error::Image too large: ${MB} MB (max ${{ inputs.image-size-limit-mb }} MB)"; exit 1
          fi

      - name: "🔍 Trivy Image Scan (gate)"
        if: ${{ inputs.run-trivy }}
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref: ${{ inputs.image-name }}:ci-${{ github.run_id }}
          format: table
          severity: CRITICAL,HIGH
          ignore-unfixed: true
          exit-code: ${{ (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && '1' || '0' }}

      - name: "🔥 Smoke boot"
        if: ${{ inputs.smoke-command != '' }}
        env:
          IMAGE: ${{ inputs.image-name }}:ci-${{ github.run_id }}
        run: ${{ inputs.smoke-command }}

      - name: "📋 SBOM (CycloneDX)"
        if: ${{ inputs.generate-sbom }}
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref: ${{ inputs.image-name }}:ci-${{ github.run_id }}
          format: cyclonedx
          output: sbom.json

      - name: Upload SBOM
        if: ${{ inputs.generate-sbom }}
        uses: actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08  # v4.6.0
        with:
          name: sbom
          path: sbom.json
          retention-days: 90

      - name: GHCR login
        if: ${{ inputs.push }}
        uses: docker/login-action@650006c6eb7dba73a995cc03b0b2d7f5ca915bee  # v4.2.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Docker metadata (tags + labels)
        if: ${{ inputs.push }}
        id: meta
        uses: docker/metadata-action@80c7e94dd9b9319bd5eb7a0e0fe9291e23a2a2e9  # v6.1.0
        with:
          images: ${{ inputs.image-name }}
          tags: ${{ inputs.tag-config }}

      - name: "Backup :latest -> :previous (main only)"
        if: ${{ inputs.push && github.ref == 'refs/heads/main' }}
        continue-on-error: true
        run: |
          if docker buildx imagetools inspect ${{ inputs.image-name }}:latest >/dev/null 2>&1; then
            docker buildx imagetools create --tag ${{ inputs.image-name }}:previous ${{ inputs.image-name }}:latest
            echo "::notice::backed up :latest -> :previous"
          else
            echo "::notice::no existing :latest to back up (first push)"
          fi

      - name: Build + push (multi-arch)
        if: ${{ inputs.push }}
        id: build-push
        uses: docker/build-push-action@f9f3042f7e2789586610d6e8b85c8f03e5195baf  # v7.2.0
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          push: true
          platforms: ${{ inputs.platforms }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: ${{ inputs.cache-from }}
          cache-to: type=gha,mode=max
          build-args: ${{ inputs.build-args }}

      - name: Install cosign
        if: ${{ inputs.push && inputs.sign-image }}
        uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6  # v4.1.2

      - name: Cosign sign (keyless)
        if: ${{ inputs.push && inputs.sign-image }}
        env:
          DIGEST: ${{ steps.build-push.outputs.digest }}
        run: cosign sign --yes "${{ inputs.image-name }}@${DIGEST}"

      - name: SLSA build provenance
        if: ${{ inputs.push && inputs.sign-image }}
        uses: actions/attest-build-provenance@v2
        with:
          subject-name: ${{ inputs.image-name }}
          subject-digest: ${{ steps.build-push.outputs.digest }}
          push-to-registry: true
```

- [ ] **Step 2: Static-validate**

Run: `./bin/actionlint.exe .github/workflows/reusable-docker-build.yml && python -m yamllint -d relaxed .github/workflows/reusable-docker-build.yml`
Expected: actionlint exit 0; yamllint exit 0 (line-length warnings only). If actionlint flags an expression (e.g. the `contains(...)` guard or the Trivy `exit-code` ternary), fix syntax without changing semantics; if irreconcilable, STOP and report.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-docker-build.yml
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "feat(docker-build): wire push/cosign/SLSA/smoke, gate Trivy, build-push@v7, multi-arch + :previous backup"
```

---

### Task 2: Fixture Dockerfile + deferred smoke caller

**Files:**
- Create: `tests/fixtures/docker/Dockerfile`
- Create: `.github/workflows/_smoke-docker-build.yml`

- [ ] **Step 1: Create a minimal, policy-compliant fixture** `tests/fixtures/docker/Dockerfile`:

```dockerfile
# Minimal buildable fixture for the reusable-docker-build smoke (also OPA-compliant).
FROM python:3.11-slim
RUN useradd -m appuser
USER appuser
HEALTHCHECK CMD python -c "print('ok')" || exit 1
CMD ["python", "-c", "print('hello from fixture')"]
```

- [ ] **Step 2: Create the smoke caller** `.github/workflows/_smoke-docker-build.yml`:

```yaml
# Manual smoke for reusable-docker-build. Runnable AFTER dev is pushed.
# push=false → exercises build + size-gate + Trivy + SBOM only (no GHCR/sign).
name: "🧪 Smoke — Docker Build"

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    uses: ./.github/workflows/reusable-docker-build.yml
    with:
      image-name: ghcr.io/adza-group/smoke-fixture
      context: tests/fixtures/docker
      dockerfile: tests/fixtures/docker/Dockerfile
      push: false
      image-size-limit-mb: 600
      smoke-command: 'docker run --rm "$IMAGE"'
    secrets: inherit
```

- [ ] **Step 3: Static-validate**

Run: `./bin/actionlint.exe .github/workflows/_smoke-docker-build.yml && python -m yamllint -d relaxed .github/workflows/_smoke-docker-build.yml`
Expected: exit 0 both (line-length warnings ok).

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/docker/Dockerfile .github/workflows/_smoke-docker-build.yml
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae')
git -c user.name="$NAME" -c user.email="$EMAIL" commit -m "ci(docker-build): add fixture Dockerfile + deferred smoke caller"
```

---

### Task 3 (DEFERRED — requires push)

**Do NOT run now.** When `dev` is pushed:
- [ ] `gh workflow run _smoke-docker-build.yml --ref dev` and `gh run watch <id> --exit-status`.
- [ ] Confirm: build loads, size-gate runs, Trivy image scan runs (advisory on dev), SBOM uploads, smoke `docker run` prints "hello from fixture". (push/sign paths are exercised later by a real app caller on dev/main, Phase 4.)

---

## Self-Review

**1. Spec coverage (§5.2 "complete docker-build"):** dead `push` wired (login + metadata + build+push) ✓; dead `sign-image` wired (cosign keyless + SLSA attest) ✓; Trivy made a real **gate** (dual exit-code + ignore-unfixed) ✓; smoke-boot via `smoke-command` ✓; `build-push@v5`→`@v7.2.0` ✓; multi-arch via qemu (conditional on `,` in platforms) ✓; `:latest`→`:previous` backup on main ✓; SBOM retained ✓. Outputs add `digest` ✓.

**2. Placeholder scan:** No TBD/TODO. All pins are concrete SHAs (resolved 2026-05-28). `tag-config` has a concrete default; `smoke-command` defaults empty (skips).

**3. Type/expression consistency:** dual-gate expression matches Phase 2a's form. `fromJSON(inputs.runner-label)` consistent. `steps.build-push.outputs.digest` is produced by the `id: build-push` step and consumed by cosign + attest + the job output — consistent. `id: size`/`localtag`/`meta` referenced correctly. checkout/trivy/upload-artifact SHAs match the values used elsewhere in the repo. Permissions (`packages: write`, `id-token: write`, `attestations: write`) cover GHCR push + cosign keyless + SLSA attest.

**Known limitation (documented):** size-gate/Trivy/smoke/SBOM run on the loaded amd64 image; arm64 layers in a multi-arch push are not separately scanned (amd64 is the representative — matches sibling-app practice). The orchestrator (Phase 3) / app callers can override `tag-config` for the `:staging` alias scheme.
