# C1-It.2 — Candidate-Promotion + Branch-Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `:latest` bewegt sich nur noch nach Staging-grün (opt-in `gated-promotion`), und `main` akzeptiert nur noch dev-Merges (`branch-policy`, default an, hart).

**Architecture:** Zwei Single-File-Edits an den bestehenden Workflows (`reusable-docker-build.yml`: candidate-Tag statt `:latest` im gated-Mode; `reusable-ci.yml`: `branch-policy`- + `promote-prod`-Jobs + Wiring) + ein neuer Smoke (`_smoke-promotion.yml`) mit deterministischem Policy-Logik-Test (synthetische Git-Repos) und realem Retag-Mechanik-Test gegen GHCR. Kein neuer Sub-Reusable → keine `@dev`-Build-out-Refs nötig.

**Tech Stack:** GitHub Actions, bash/git (`merge-base --is-ancestor`), `docker buildx imagetools`, GHCR.

**Validierungs-Konvention:** `./bin/actionlint.exe <wf>` (exit 0) + `python -m yamllint -d relaxed <wf>` lokal; Ubuntu-Smoke via temp `push:[dev]`-Trigger + `gh run watch --exit-status`, Trigger danach zurück. Commits mit Log-Identität (`NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit …`), LF-Endings, kein `git config`.

---

## File Structure

| Datei | Art | Verantwortung |
|---|---|---|
| `.github/workflows/reusable-docker-build.yml` | modify | `gated-promotion`-Input; candidate-Tag; `:latest`/Backup nur non-gated; `candidate-tag`-Output |
| `.github/workflows/reusable-ci.yml` | modify | Inputs `enforce-branch-policy`/`gated-promotion`; Jobs `branch-policy` + `promote-prod`; Wiring docker-build/verify-prod/telemetry |
| `.github/workflows/_smoke-promotion.yml` | create | policy-logic (3 synthetische Fälle) + retag-mechanics (GHCR) |
| `README.md` | modify | gated-promotion-Contract, branch-policy-Verhalten, Promote/Rollback-Runbook |
| `CLAUDE.md` | modify | Resume-Update It.2 |

---

## Task 1: `reusable-docker-build.yml` — gated-promotion

**Files:** Modify: `.github/workflows/reusable-docker-build.yml`

- [ ] **Step 1: Input ergänzen** — nach dem `sign-image`-Input (boolean, default true) einfügen:

```yaml
      gated-promotion:
        required: false
        type: boolean
        default: false
        description: "main pushes :candidate-<sha> instead of :latest; a later promote job retags after staging is green"
```

- [ ] **Step 2: Metadata-Tags umbauen** — der `Docker metadata`-Step (id `meta`) hat aktuell als letzte zwei Tag-Zeilen:

```yaml
            type=raw,value=staging,enable=${{ github.ref == 'refs/heads/dev' }}
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}
```

Ersetzen durch:

```yaml
            type=raw,value=staging,enable=${{ github.ref == 'refs/heads/dev' }}
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' && !inputs.gated-promotion }}
            type=raw,value=candidate-${{ github.sha }},enable=${{ github.ref == 'refs/heads/main' && inputs.gated-promotion }}
```

(Per-SHA-Candidate, kein Moving-Tag → keine Race bei sequenziellen main-Pushes.)

- [ ] **Step 3: Backup-Step gaten** — der Step `"Backup :latest -> :previous (main only)"` hat `if: ${{ inputs.push && github.ref == 'refs/heads/main' }}`. Ersetzen durch:

```yaml
        if: ${{ inputs.push && github.ref == 'refs/heads/main' && !inputs.gated-promotion }}
```

(Im gated-Mode bewegt sich `:latest` erst im promote-Job — Backup dort.)

- [ ] **Step 4: candidate-Output** — (a) im Workflow-`outputs:`-Block (nach `digest`) ergänzen:

```yaml
      candidate-tag:
        description: "Candidate tag pushed when gated-promotion on main (empty otherwise)"
        value: ${{ jobs.build.outputs.candidate }}
```

(b) im `build`-Job-`outputs:` ergänzen: `candidate: ${{ steps.candidate.outputs.tag }}`
(c) neuen Step direkt nach `Build + push (multi-arch)` einfügen:

```yaml
      - name: Candidate tag output
        if: ${{ inputs.push && inputs.gated-promotion && github.ref == 'refs/heads/main' }}
        id: candidate
        run: echo "tag=${{ inputs.image-name }}:candidate-${{ github.sha }}" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 5: Lint** — Run: `./bin/actionlint.exe .github/workflows/reusable-docker-build.yml` → exit 0; yamllint keine Errors.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/reusable-docker-build.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): gated-promotion — main builds :candidate-<sha> instead of :latest (C1-it.2)

Opt-in (default false = today's behavior). :latest and the :previous backup
move to the promote job; per-sha candidate tags avoid moving-tag races."
```

---

## Task 2: `reusable-ci.yml` — branch-policy (Job + Wiring)

**Files:** Modify: `.github/workflows/reusable-ci.yml`

- [ ] **Step 1: Input ergänzen** — am Ende des `inputs:`-Blocks (nach `prod-version-url`):

```yaml
      enforce-branch-policy:
        required: false
        type: boolean
        default: true
        description: "Hard gate: main pushes must come via dev (ff- or --no-ff-merge); violations block docker-build/promote"
```

- [ ] **Step 2: Job einfügen** — direkt nach dem `changes`-Job:

```yaml
  branch-policy:
    name: "🛡️ Branch Policy"
    if: ${{ inputs.enforce-branch-policy && github.ref == 'refs/heads/main' && github.event_name == 'push' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
        with:
          fetch-depth: 0
      - name: Enforce dev -> main merge flow
        run: |
          git fetch origin dev --quiet || { echo "::error::cannot fetch origin/dev"; exit 1; }
          HEAD_SHA=$(git rev-parse HEAD)
          if git merge-base --is-ancestor "$HEAD_SHA" origin/dev; then
            echo "✅ main HEAD liegt auf dev (fast-forward merge) — policy ok"
            exit 0
          fi
          P2=$(git rev-parse "${HEAD_SHA}^2" 2>/dev/null || true)
          if [ -n "$P2" ] && git merge-base --is-ancestor "$P2" origin/dev; then
            echo "✅ main HEAD ist Merge mit dev als zweitem Parent (--no-ff/PR) — policy ok"
            exit 0
          fi
          echo "::error::Branch policy violated: main wurde nicht über dev befüllt. Iron Law: dev -> Staging grün -> main. Heilung: Änderung auf dev landen, Staging verifizieren, dann dev -> main mergen."
          exit 1
```

- [ ] **Step 3: docker-build wiring** — `needs` von
`[changes, lint-python, test-matrix, security, coverage, e2e]` auf
`[changes, lint-python, test-matrix, security, coverage, e2e, branch-policy]`; im `if:`-Guard nach der `needs.e2e`-Zeile einfügen:

```yaml
      (needs.branch-policy.result == 'success' || needs.branch-policy.result == 'skipped') &&
```

(skipped auf dev/PR/dispatch/Tags; auf main-Push MUSS success = fail-closed.)

- [ ] **Step 4: telemetry** — `branch-policy` in die `telemetry.needs`-Liste; Summary-Zeile nach `lint-python`:

```bash
            echo "| branch-policy | ${{ needs.branch-policy.result }} |"
```

- [ ] **Step 5: Lint + Commit**

Run: `./bin/actionlint.exe .github/workflows/reusable-ci.yml` → exit 0.

```bash
git add .github/workflows/reusable-ci.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): hard branch-policy gate — main accepts only dev merges (C1-it.2)

Default on. ff-merge (HEAD on dev) or --no-ff/PR merge (HEAD^2 on dev) pass;
anything else fails and blocks docker-build via needs guard (fail-closed on
main pushes, skipped elsewhere). Free-tier enforcement: the push lands but is
operationally inert (no image, no deploy, run red)."
```

---

## Task 3: `reusable-ci.yml` — promote-prod + verify-prod-Wiring

**Files:** Modify: `.github/workflows/reusable-ci.yml`

- [ ] **Step 1: Input + Passthrough** — am Ende des `inputs:`-Blocks (nach `enforce-branch-policy`):

```yaml
      gated-promotion:
        required: false
        type: boolean
        default: false
        description: "Opt-in: main builds :candidate-<sha>; promote-prod retags to :latest only after require-staging-green. REQUIRES staging-url."
```

Im `docker-build`-Job-Call (`with:`-Block) ergänzen:

```yaml
      gated-promotion: ${{ inputs.gated-promotion }}
```

- [ ] **Step 2: promote-prod-Job** — zwischen `require-staging-green` und `verify-prod` einfügen:

```yaml
  promote-prod:
    name: "🚀 Promote Prod"
    needs: [docker-build, require-staging-green]
    if: >-
      ${{ always() && inputs.gated-promotion && inputs.deploy-prod &&
      github.ref == 'refs/heads/main' && github.event_name == 'push' &&
      needs.docker-build.result == 'success' &&
      needs.require-staging-green.result == 'success' }}
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 10
    permissions:
      contents: read
      packages: write
    steps:
      - uses: docker/setup-buildx-action@b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2  # v3.10.0
      - name: GHCR login
        uses: docker/login-action@650006c6eb7dba73a995cc03b0b2d7f5ca915bee  # v4.2.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: "Backup :latest -> :previous"
        continue-on-error: true
        run: |
          IMAGE="${{ inputs.image-name != '' && inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}"
          if docker buildx imagetools inspect "${IMAGE}:latest" >/dev/null 2>&1; then
            docker buildx imagetools create --tag "${IMAGE}:previous" "${IMAGE}:latest"
            echo "::notice::backed up :latest -> :previous"
          else
            echo "::notice::no existing :latest to back up (first gated run)"
          fi
      - name: "Promote :candidate -> :latest"
        run: |
          IMAGE="${{ inputs.image-name != '' && inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}"
          CANDIDATE="${{ needs.docker-build.outputs.candidate-tag }}"
          if [ -z "$CANDIDATE" ]; then
            CANDIDATE="${IMAGE}:candidate-${{ github.sha }}"
            echo "::notice::candidate-tag output empty — reconstructed ${CANDIDATE}"
          fi
          docker buildx imagetools create --tag "${IMAGE}:latest" "$CANDIDATE"
          echo "::notice::promoted ${CANDIDATE} -> ${IMAGE}:latest — watchtower deploys prod on next poll"
```

- [ ] **Step 3: verify-prod wiring** — `needs: [docker-build, require-staging-green]` →
`needs: [docker-build, require-staging-green, promote-prod]`; im `if:`-Guard nach der
`needs.docker-build.result == 'success' &&`-Zeile einfügen:

```yaml
      (needs.promote-prod.result == 'success' || (!inputs.gated-promotion && needs.promote-prod.result == 'skipped')) &&
```

> Begründung: gated + Staging rot ⇒ promote skipped ⇒ verify-prod MUSS skippen — sonst liefe
> der C2-Version-Assert gegen das alte Prod-Image rot und der Auto-Rollback würde Prod aktiv
> downgraden, obwohl gar nichts deployt wurde. Non-gated: skipped-promote ist der Normalfall.

- [ ] **Step 4: telemetry** — `promote-prod` in `telemetry.needs`; Summary-Zeile nach `verify-staging`:

```bash
            echo "| promote-prod | ${{ needs.promote-prod.result }} |"
```

- [ ] **Step 5: Lint + Commit**

Run: `./bin/actionlint.exe .github/workflows/reusable-ci.yml .github/workflows/reusable-docker-build.yml` → exit 0.

```bash
git add .github/workflows/reusable-ci.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): promote-prod — :latest moves only after staging green (C1-it.2)

Opt-in via gated-promotion. Backup :latest->:previous then digest-stable
imagetools retag of :candidate-<sha>. verify-prod now requires the promotion
(or non-gated skip) so a skipped promote never triggers a false rollback."
```

---

## Task 4: `_smoke-promotion.yml` + Ubuntu-Validierung

**Files:** Create: `.github/workflows/_smoke-promotion.yml`

- [ ] **Step 1: Datei anlegen**

```yaml
name: "🔥 smoke: promotion"
on:
  workflow_dispatch: {}
  # TEMP for validation (remove after green):
  push:
    branches: [dev]
    paths:
      - ".github/workflows/_smoke-promotion.yml"
      - ".github/workflows/reusable-docker-build.yml"

permissions:
  contents: read
  packages: write

jobs:
  policy-logic:
    name: "🛡️ policy ancestry logic"
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: 3 synthetic cases (ff PASS / no-ff PASS / direct FAIL)
        run: |
          set -e
          check() {
            cd "$1"
            local verdict=FAIL
            HEAD_SHA=$(git rev-parse HEAD)
            if git merge-base --is-ancestor "$HEAD_SHA" dev; then verdict=PASS
            else
              P2=$(git rev-parse "${HEAD_SHA}^2" 2>/dev/null || true)
              if [ -n "$P2" ] && git merge-base --is-ancestor "$P2" dev; then verdict=PASS; fi
            fi
            cd ..; echo "$verdict"
          }
          G="git -c user.name=t -c user.email=t@t"
          mk() { mkdir "$1"; cd "$1"; git init -q -b dev; $G commit -q --allow-empty -m base; cd ..; }
          # Case 1: fast-forward (main HEAD == dev commit)
          mk r1; cd r1; git checkout -q -b main dev; cd ..
          [ "$(check r1)" = "PASS" ] || { echo "::error::case1 ff expected PASS"; exit 1; }
          # Case 2: --no-ff merge of dev into diverged main
          mk r2; cd r2; git checkout -q -b main; $G commit -q --allow-empty -m old-main
          git checkout -q dev; $G commit -q --allow-empty -m feat
          git checkout -q main; $G merge -q --no-ff dev -m merge-dev; cd ..
          [ "$(check r2)" = "PASS" ] || { echo "::error::case2 no-ff expected PASS"; exit 1; }
          # Case 3: direct commit on main (violation)
          mk r3; cd r3; git checkout -q -b main dev; $G commit -q --allow-empty -m direct; cd ..
          [ "$(check r3)" = "FAIL" ] || { echo "::error::case3 direct expected FAIL"; exit 1; }
          echo "✅ all 3 policy cases behave as designed"

  retag-mechanics:
    name: "🚀 candidate->latest retag"
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: docker/setup-buildx-action@b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2  # v3.10.0
      - uses: docker/login-action@650006c6eb7dba73a995cc03b0b2d7f5ca915bee  # v4.2.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build + push candidate
        uses: docker/build-push-action@f9f3042f7e2789586610d6e8b85c8f03e5195baf  # v7.2.0
        with:
          context: tests/fixtures/docker
          file: tests/fixtures/docker/Dockerfile
          push: true
          tags: ghcr.io/adza-group/shared-workflows-smoke:candidate-${{ github.sha }}
      - name: Promote + assert digest equality
        run: |
          IMG="ghcr.io/adza-group/shared-workflows-smoke"
          docker buildx imagetools create --tag "${IMG}:latest-smoke" "${IMG}:candidate-${{ github.sha }}"
          D1=$(docker buildx imagetools inspect "${IMG}:candidate-${{ github.sha }}" --format '{{json .Manifest.Digest}}')
          D2=$(docker buildx imagetools inspect "${IMG}:latest-smoke" --format '{{json .Manifest.Digest}}')
          echo "candidate=$D1  latest-smoke=$D2"
          [ -n "$D1" ] && [ "$D1" = "$D2" ] || { echo "::error::digest mismatch after retag"; exit 1; }
          echo "✅ digest-stable promotion verified"
```

- [ ] **Step 2: Lint** — `./bin/actionlint.exe .github/workflows/_smoke-promotion.yml` → exit 0.

- [ ] **Step 3: Commit + Push (Smoke feuert via temp Trigger)**

```bash
git add .github/workflows/_smoke-promotion.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "test(ci): _smoke-promotion — policy ancestry cases + digest-stable retag"
git push origin dev
```

- [ ] **Step 4: Watch** — `gh run watch "$(gh run list --workflow=_smoke-promotion.yml --branch dev --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status` → success (beide Jobs). Bei Fehler: `gh run view <id> --log-failed` → systematic-debugging → re-push.

- [ ] **Step 5: Regression `_smoke-ci`** — `gh workflow run _smoke-ci.yml --ref dev` → watch → success. Erwartung: `branch-policy` skipped (kein main-Push), `promote-prod` skipped (gated off), docker-build baut wie in v1.6.0.

- [ ] **Step 6: Temp-Trigger zurücknehmen**

`_smoke-promotion.yml`: `push:`-Block entfernen (nur `workflow_dispatch`).

```bash
git add .github/workflows/_smoke-promotion.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "ci: revert temp push trigger on _smoke-promotion (dispatch-only)"
git push origin dev
```

---

## Task 5: Docs

**Files:** Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: README** — unter den v1.6.0-Sektionen (Version App-Contract / e2e / Branch-Pflicht) die Branch-Pflicht-Sektion ERSETZEN durch:

```markdown
### Branch-Policy (C1-It.2 — enforced, default an)
Jeder `main`-Push wird vom `branch-policy`-Job geprüft: HEAD muss auf `dev` liegen (ff-Merge) oder
ein Merge-Commit mit dev als zweitem Parent sein (`--no-ff`/PR). Verstoß ⇒ Run rot, docker-build/
promote geblockt ⇒ kein Image, kein Deploy (Free-Tier-Enforcement; echtes Server-Reject braucht
GitHub Team). Not-Aus: `enforce-branch-policy: false` (Bibliotheks-Schalter, kein Break-Glass).

### Gated Promotion (C1-It.2 — opt-in)
`gated-promotion: true` (REQUIRES `staging-url`): main baut+pusht `:candidate-<sha>` statt `:latest`.
`promote-prod` retagt erst nach `require-staging-green` digest-stabil auf `:latest` (Backup
`:latest`→`:previous` inklusive) → Watchtower deployt Prod gegatet. Staging rot ⇒ Prod unverändert,
Candidate liegt bereit. **Manuelles Promote nach Fix:**
`docker buildx imagetools create --tag ghcr.io/adza-group/<app>:latest ghcr.io/adza-group/<app>:candidate-<sha>`
**Rollback:** unverändert `:previous` → `:latest` (verify-prod macht das bei rotem Health-Check automatisch).
```

- [ ] **Step 2: CLAUDE.md** — im 2026-06-09-Verifiziert-Block den Punkt „(b) C1-It.2 = Candidate-Tag-Promotion …" ersetzen durch:

```markdown
> (b) **C1-It.2 GEBAUT** (Spec/Plan `2026-06-09-ci-candidate-promotion-branch-policy*`): `branch-policy`
> default AN (main nur via dev, hart, fail-closed in docker-build.needs) + `gated-promotion` opt-in
> (`:candidate-<sha>`→promote-prod nach Staging-grün→`:latest`, digest-stabil, verify-prod skippt bei
> nicht-promotetem gated-Run gegen False-Rollback). Smoke `_smoke-promotion` (policy-Fälle + Retag-Digest).
> **Offen: FootballApp-Pilot (`gated-promotion: true`) = echter main-E2E-Beweis; Branch-Protection-API-Befund;**
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "docs(ci): branch-policy + gated-promotion contracts, promote/rollback runbook (C1-it.2)"
```

---

## Task 6: Branch-Protection-API-Versuch (Best-Effort, dokumentieren)

**Files:** keine (gh api + Befund in CLAUDE.md-Commit von Task 5 nachtragen falls nötig)

- [ ] **Step 1: Pro App-Repo versuchen** (Fehlschlag erwartet = Befund, kein Blocker):

```bash
for REPO in adza-group/FootballApp adza-group/recyclage-app adza-group/rechnungsapp azad-ahmed/MitarbeiterApp; do
  echo "=== $REPO ==="
  gh api -X PUT "repos/${REPO}/branches/main/protection" \
    -F required_pull_request_reviews='null' \
    -F enforce_admins=true -F required_status_checks='null' -F restrictions='null' \
    -F allow_force_pushes=false -F allow_deletions=false 2>&1 | head -3 || true
done
```

> Hinweis: exakte Repo-Slugs vorher mit `gh repo list adza-group --limit 20` verifizieren (MitarbeiterApp
> liegt laut Memory unter `azad-ahmed`). 403/422 „Upgrade to GitHub Team" = erwarteter Free-Plan-Befund.

- [ ] **Step 2: Befund dokumentieren** — Ergebnis (pro Repo: aktiviert ODER paid-blocked) als eine Zeile in CLAUDE.md-Resume ergänzen + committen (`docs(ci): branch-protection api findings`).

---

## Task 7: Release v1.7.0 + @v1 (Smokes-grün vorausgesetzt; vom User im Spec freigegeben)

- [ ] **Step 1: Vorbedingung** — `_smoke-promotion` grün + `_smoke-ci`-Regression grün (Task 4) bestätigt; `git status` clean; dev gepusht.

- [ ] **Step 2: Verlust-Check**

```bash
git fetch origin --tags
git ls-remote origin refs/tags/v1
git log v1 --not dev --oneline   # MUSS leer sein
```

- [ ] **Step 3: Tag + Move + Verify**

```bash
SHA=$(git rev-parse dev)
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  tag -a v1.7.0 -m "v1.7.0: branch-policy hard gate (default on) + opt-in gated-promotion (C1-it.2)" "$SHA"
git push origin v1.7.0
git tag -f v1 "$SHA"
git push -f origin v1
git ls-remote origin refs/tags/v1 'refs/tags/v1.7.0^{}'   # beide -> $SHA
```

- [ ] **Step 4: STOP — User-Gate für Pilot.** FootballApp-Caller `gated-promotion: true` NICHT automatisch setzen; dem User als nächsten Schritt vorlegen (echter main-E2E-Beweis).

---

## Self-Review (gegen Spec)

**Spec-Coverage:** 2.1 branch-policy (Job+Input+Wiring+telemetry) → T2 ✓ · 2.2 gated-promotion (docker-build-Tags/Backup/Output → T1; ci-Input/promote-prod/verify-prod/telemetry → T3) ✓ · Smoke (policy-Fälle + Retag) → T4 ✓ · 2.3 Branch-Protection-API → T6 ✓ · Docs → T5 ✓ · Rollout v1.7.0 + Pilot-Gate → T7 ✓ · R1–R4 in Spec dokumentiert, R-relevante Guards im Code (verify-prod-Skip-Logik T3-Step3) ✓.

**Placeholder-Scan:** kein TBD/TODO; aller Code ausgeschrieben; Repo-Slugs in T6 explizit als zu-verifizieren markiert (kein blindes Raten).

**Konsistenz:** Job-Name `branch-policy` identisch in needs/Guard/telemetry; `promote-prod` identisch in verify-prod-needs/Guard/telemetry; Input-Namen `gated-promotion`/`enforce-branch-policy` identisch Caller↔Reusable; `candidate-tag`-Output-Name docker-build↔promote-Verbrauch; IMAGE-Default-Expression identisch zu verify-staging/verify-prod (bestehendes Muster).
