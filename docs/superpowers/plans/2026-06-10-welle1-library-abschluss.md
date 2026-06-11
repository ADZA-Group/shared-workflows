# Welle 1 — Library-Abschluss Implementation Plan (Fleet-Endausbau)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Library-Voraussetzungen des Fleet-Endausbaus shippen: Node-24-Action-Pins (Deadline 16.06.), `GIT_SHA`-Default-Build-Arg (C2-Voraussetzung), referenced-safer Candidate-Prune, pip-Härtung → Release `v1.8.0`.

**Architecture:** Vier unabhängige Edits an bestehenden Workflows/Composites in `shared-workflows`, je eigener Commit; Node-Bumps in 4 bisectbaren Familien-Commits mit zur Laufzeit aufgelösten Release-SHAs (kein Hardcode veralteter SHAs im Plan). Validierung über die bestehenden `_smoke-*` auf ubuntu; Release nach dem etablierten v1.7.x-Muster mit frischem Fetch + Verlust-Check (Parallel-Session-Risiko R4).

**Tech Stack:** GitHub Actions, bash/jq/`gh api`, GHCR REST.

**Konventionen (wie v1.6.0–v1.7.2):** Arbeit auf `dev`; `./bin/actionlint.exe <wf>` exit 0 nach jedem Edit; Commits mit Log-Identität (`NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit …`), LF-Endings, kein `git config`; vor JEDEM Push `git fetch origin dev` + ggf. rebase.

---

## File Structure

| Datei | Art | Verantwortung |
|---|---|---|
| `.github/workflows/reusable-docker-build.yml` | modify | T1: `GIT_SHA`-Default-Build-Arg in beiden build-push-Steps |
| `.github/actions/setup-python-deps/action.yml` | modify | T2: pip retries 3→5 + `PIP_DEFAULT_TIMEOUT` |
| `.github/workflows/reusable-ci.yml` | modify | T3: `enable-candidate-prune`-Input + Candidate-Prune-Step in `prune-ghcr` |
| alle `.github/{workflows,actions}` | modify | T4: Node-24-Pin-Bumps (20 Familien, 4 Commits) |
| `CLAUDE.md` | modify | T6: Resume-Update |

---

## Task 1: `GIT_SHA`-Default-Build-Arg (C2-Voraussetzung)

**Files:** Modify: `.github/workflows/reusable-docker-build.yml`

- [ ] **Step 1: Beide build-push-Steps erweitern.** Der Workflow hat zwei `docker/build-push-action`-Steps: `Build (single-arch, load for scan)` und `Build + push (multi-arch)` (id `build-push`). Beide haben `build-args: ${{ inputs.build-args }}`. Ersetze in BEIDEN Steps exakt diese Zeile durch den mehrzeiligen Block (GHA-Multiline: Caller-Args + unsere Zeile):

```yaml
          build-args: |
            ${{ inputs.build-args }}
            GIT_SHA=${{ github.sha }}
```

> Semantik: docker/build-push-action nimmt newline-separierte `build-args`; leere Zeilen (leerer Caller-Input) sind harmlos. Apps, die `ARG GIT_SHA` nicht deklarieren, bekommen nur die bekannte „unused build-arg"-Warnung — kein Bruch.

- [ ] **Step 2: Lint** — `./bin/actionlint.exe .github/workflows/reusable-docker-build.yml` → exit 0.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/reusable-docker-build.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): GIT_SHA default build-arg in docker builds (C2 prerequisite)

Apps konsumieren via 'ARG GIT_SHA' -> ENV APP_SHA -> /health sha-Feld, womit
der version-assert in verify-staging/prod scharf wird. Apps ohne ARG: nur
unused-build-arg-Warnung, kein Verhaltenswechsel."
```

---

## Task 2: pip-Härtung in `setup-python-deps`

**Files:** Modify: `.github/actions/setup-python-deps/action.yml`

- [ ] **Step 1: Retries+Timeout.** Die Datei hat vier `pip install`-Aufrufe mit `--retries 3 --timeout 60` (venv-pip-upgrade, requirements, coverage-tooling, extra-packages). Ersetze in ALLEN vier Vorkommen `--retries 3 --timeout 60` durch `--retries 5 --timeout 90`.

- [ ] **Step 2: Env-Fallback.** Im Step `Create per-job venv and put it on PATH` nach der `echo "$VENV/bin" >> "$GITHUB_PATH"`-Zeile ergänzen:

```bash
        echo "PIP_DEFAULT_TIMEOUT=90" >> "$GITHUB_ENV"
```

> Begründung: pips parallele Batch-Downloads (`_complete_partial_requirements`) respektieren das CLI-Retry nur teilweise (IncompleteRead-Flake, Run 27261571015 auf LXC-104). Mehr Versuche + Env-Timeout senken die Rate; Heilung bleibt Re-Run.

- [ ] **Step 3: Lint + Commit**

`python -m yamllint -d relaxed .github/actions/setup-python-deps/action.yml` → keine Errors.

```bash
git add .github/actions/setup-python-deps/action.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "fix(ci): pip retries 5 + PIP_DEFAULT_TIMEOUT=90 (IncompleteRead-Flakes, LXC-104)"
```

---

## Task 3: Candidate-Prune (referenced-safe, opt-in)

**Files:** Modify: `.github/workflows/reusable-ci.yml` (Input + `prune-ghcr`-Job)

- [ ] **Step 1: Input** — am Ende des `inputs:`-Blocks (nach `gated-promotion`):

```yaml
      enable-candidate-prune:
        required: false
        type: boolean
        default: false
        description: "Opt-in: delete GHCR versions tagged ONLY candidate-*/main-<sha> older than 14 days (referenced-safe; promoted candidates carry :latest/:main on the same version and are skipped)"
```

- [ ] **Step 2: prune-ghcr-Job erweitern.** Der Job `prune-ghcr` hat heute einen Step (`Delete untagged versions`, gated via `inputs.enable-ghcr-prune`). Diesen Step um eine eigene `if`-Bedingung ergänzen (er lief bisher implizit über den Job-`if`) und einen NEUEN zweiten Step anhängen. Der Job-`if` wird so erweitert, dass er läuft, wenn EINER der beiden Prunes aktiv ist:

Job-`if` (aktuell endet auf `needs.verify-prod.result != 'failure' }}`) — die Bedingung `inputs.enable-ghcr-prune &&` im Job-`if` ersetzen durch `(inputs.enable-ghcr-prune || inputs.enable-candidate-prune) &&`.

Bestehender Step bekommt:
```yaml
        if: ${{ inputs.enable-ghcr-prune }}
```

Neuer Step danach:

```yaml
      - name: Delete stale candidate versions (referenced-safe)
        if: ${{ inputs.enable-candidate-prune }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          IMAGE: ${{ inputs.image-name != '' && inputs.image-name || format('ghcr.io/adza-group/{0}', inputs.app-name) }}
        run: |
          # ghcr.io/<owner>/<pkg...> -> owner + url-encoded package path
          OWNER=$(echo "$IMAGE" | cut -d/ -f2)
          PKG=$(echo "$IMAGE" | cut -d/ -f3- | sed 's|/|%2F|g')
          CUTOFF=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)
          BASE="/orgs/${OWNER}/packages/container/${PKG}"
          gh api "${BASE}/versions?per_page=100" --paginate > /tmp/vers.json 2>/dev/null \
            || { BASE="/users/${OWNER}/packages/container/${PKG}"; gh api "${BASE}/versions?per_page=100" --paginate > /tmp/vers.json; }
          # Loeschregel: aelter als CUTOFF, hat Tags, ALLE Tags matchen ^(candidate-|main-[0-9a-f]{7,40}$),
          # KEIN Tag aus dem Schutz-Set (Gurt+Hosentraeger zur Regex).
          jq -r --arg cutoff "$CUTOFF" '
            .[] | select(.created_at < $cutoff)
            | select((.metadata.container.tags | length) > 0)
            | select([.metadata.container.tags[] | test("^(candidate-[0-9a-f]+|main-[0-9a-f]{7,40})$")] | all)
            | select([.metadata.container.tags[] | IN("latest","previous","staging","staging-previous","main","dev")] | any | not)
            | "\(.id)\t\(.metadata.container.tags | join(","))"' /tmp/vers.json > /tmp/prune.list
          COUNT=$(wc -l < /tmp/prune.list | tr -d ' ')
          echo "## 🧹 Candidate-Prune (${COUNT} versions)" >> "$GITHUB_STEP_SUMMARY"
          if [ "$COUNT" = "0" ]; then echo "::notice::no stale candidate versions"; exit 0; fi
          while IFS=$'\t' read -r ID TAGS; do
            echo "deleting version ${ID} (${TAGS})"
            echo "| ${ID} | ${TAGS} |" >> "$GITHUB_STEP_SUMMARY"
            gh api -X DELETE "${BASE}/versions/${ID}"
          done < /tmp/prune.list
```

> Sicherheitslogik: promotete Candidates tragen `latest`+`main` an DERSELBEN Version → von beiden Filtern ausgeschlossen. `:previous`-Anker ebenso. Gelöscht werden nur superseded, >14 Tage alte, ausschließlich candidate-/sha-getaggte Versionen — KEIN untagged-Sweep (Risk #2 bleibt unberührt).

- [ ] **Step 3: Lint + Commit**

`./bin/actionlint.exe .github/workflows/reusable-ci.yml` → exit 0.

```bash
git add .github/workflows/reusable-ci.yml
git -c user.name="$(git log -1 --format='%an')" -c user.email="$(git log -1 --format='%ae')" \
  commit -m "feat(ci): referenced-safe candidate prune (opt-in enable-candidate-prune)

Loescht nur Versionen, deren Tags AUSSCHLIESSLICH candidate-*/main-<sha> sind
(>14d). Promotete tragen :latest/:main am selben Digest -> geschuetzt. Bewusst
KEIN untagged-Sweep (dokumentiertes UNSAFE-Risk #2 unberuehrt)."
```

---

## Task 4: Node-24-Pin-Bumps (20 Familien, 4 bisectbare Commits)

**Files:** Modify: alle Dateien unter `.github/workflows` + `.github/actions` mit `uses:`-SHA-Pins (Inventur 2026-06-10: 20 Familien / 85 Vorkommen; führend `actions/checkout` 47×).

**Auflöse-Prozedur pro Familie** (zur Laufzeit, KEINE hartkodierten Ziel-SHAs — sie veralten):

```bash
fam_bump() {  # $1 = owner/repo (z.B. actions/checkout), $2.. = sed-Pfadmuster (default: owner/repo)
  REPO="$1"; PAT="${2:-$1}"
  TAG=$(gh api "repos/${REPO}/releases/latest" --jq .tag_name)
  OBJ=$(gh api "repos/${REPO}/git/ref/tags/${TAG}" --jq '.object | "\(.type) \(.sha)"')
  TYPE=${OBJ%% *}; SHA=${OBJ##* }
  [ "$TYPE" = "tag" ] && SHA=$(gh api "repos/${REPO}/git/tags/${SHA}" --jq .object.sha)
  echo "${REPO}: ${TAG} -> ${SHA}"
  grep -rl "${PAT}@" .github/workflows .github/actions | \
    xargs sed -i "s|\(uses: ${PAT}[a-zA-Z0-9_./-]*\)@[a-f0-9]\{40\}.*|\1@${SHA}  # ${TAG}|"
}
```

> Hinweis Monorepo: `github/codeql-action/{init,autobuild,analyze}` teilen die SHA → `fam_bump github/codeql-action github/codeql-action` ersetzt alle drei (das sed-Muster `[a-zA-Z0-9_./-]*` fängt die Subpfade).
> **Major-Bump-Vorsicht (Spec R1):** Vor jedem Bump `gh api repos/<repo>/releases/latest --jq .body | head -40` auf Breaking-Changes für UNSERE Nutzung prüfen (z.B. checkout: default-fetch-Verhalten; upload/download-artifact v4→v5: Artefakt-Format-Kompatibilität upload↔download MUSS paarweise gebumpt werden). Wenn ein Major für unsere Nutzung bricht: neuesten Release des aktuellen Majors nehmen (`gh api repos/<repo>/releases --jq '.[].tag_name' | grep '^v<major>' | head -1`).

- [ ] **Step 1 — Commit A (actions/* Kern):** `fam_bump` für `actions/checkout`, `actions/cache`, `actions/upload-artifact`, `actions/download-artifact`, `actions/setup-node`. upload/download-artifact ZUSAMMEN bumpen (Format-Paarung). Danach `./bin/actionlint.exe .github/workflows/*.yml` → exit 0; Commit `ci(deps): bump actions/* core pins to node24 releases (checkout/cache/artifact/setup-node)`.

- [ ] **Step 2 — Commit B (docker/*):** `fam_bump` für `docker/setup-buildx-action`, `docker/login-action`, `docker/build-push-action`, `docker/setup-qemu-action`, `docker/metadata-action`. actionlint → Commit `ci(deps): bump docker/* action pins`.

- [ ] **Step 3 — Commit C (Security-Tools):** `fam_bump` für `aquasecurity/trivy-action`, `sigstore/cosign-installer`, `github/codeql-action`, `actions/dependency-review-action`, `actions/attest-build-provenance`. actionlint → Commit `ci(deps): bump security tool action pins (trivy/cosign/codeql/dep-review/attest)`.

- [ ] **Step 4 — Commit D (Misc):** `fam_bump` für `dorny/paths-filter`, `actions/delete-package-versions`, `EnricoMi/publish-unit-test-result-action`. actionlint → Commit `ci(deps): bump misc action pins (paths-filter/delete-package-versions/test-results)`.

- [ ] **Step 5 — Rest-Check:** `grep -rE "uses: .+@[a-f0-9]{40}" .github | grep -vE "adza-group" | grep -cE "."` — Anzahl muss 85 bleiben (nur SHAs getauscht, keine Zeile verloren); `grep -rE "uses: [^a]" .github | grep -vE "@[a-f0-9]{40}|adza-group|#"` → leer (keine neuen Floating-Refs).

---

## Task 5: Smoke-Validierung (push dev → Smokes)

**Files:** keine (CI-Runs)

- [ ] **Step 1: Push** — `git fetch origin dev && git rebase origin/dev` (R4!), dann `git push origin dev`.

- [ ] **Step 2: Smokes dispatchen + watchen** (alle auf ubuntu, `--ref dev`):

```bash
for WF in _smoke-composites-ubuntu.yml _smoke-ci.yml _smoke-docker-build.yml _smoke-promotion.yml; do
  gh workflow run "$WF" --ref dev && sleep 8
  RID=$(gh run list --workflow="$WF" --branch dev --limit 1 --json databaseId --jq '.[0].databaseId')
  gh run watch "$RID" --exit-status || { echo "FAIL: $WF run $RID"; exit 1; }
done
```
Expected: alle 4 success. Bei Rot: `gh run view <id> --log-failed` → systematic-debugging → fixen (häufigste Klasse: Action-Major mit geändertem Input — dann Familien-Commit per Bisect identifizieren, auf letzten kompatiblen Major zurückpinnen) → re-push → re-smoke.

- [ ] **Step 3: Node-20-Beweis:** Im `_smoke-ci`-Run-Log prüfen:
`gh run view <smoke-ci-id> --log 2>&1 | grep -ci "Node.js 20" ` → Expected: **0** (keine Deprecation-Warnungen mehr).

- [ ] **Step 4: Candidate-Prune-Probelauf (real, RecyclageApp-Paket, read-only zuerst):** das jq-Filter aus T3 lokal gegen die echte Versions-Liste laufen lassen:

```bash
gh api "/orgs/adza-group/packages/container/recyclage-app/versions?per_page=100" --paginate | \
  jq -r --arg cutoff "$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)" '
    .[] | select(.created_at < $cutoff)
    | select((.metadata.container.tags | length) > 0)
    | select([.metadata.container.tags[] | test("^(candidate-[0-9a-f]+|main-[0-9a-f]{7,40})$")] | all)
    | select([.metadata.container.tags[] | IN("latest","previous","staging","staging-previous","main","dev")] | any | not)
    | "\(.id)\t\(.metadata.container.tags | join(","))"'
```
Expected HEUTE: leer (Candidates sind <14d alt) — beweist, dass der Filter die frischen/promoteten Versionen NICHT anfasst. Output im Abschlussbericht dokumentieren.

---

## Task 6: Release v1.8.0 + Docs

**Files:** Modify: `CLAUDE.md`

- [ ] **Step 1: Verlust-Check (frisch!):**

```bash
git fetch origin dev --tags
git rev-list --left-right --count origin/dev...dev   # links MUSS 0 sein, sonst erst rebase
git log "$(git ls-remote origin refs/tags/v1 | cut -c1-40)" --not dev --oneline   # MUSS leer sein
```

- [ ] **Step 2: Tag + Move + Verify:**

```bash
NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); SHA=$(git rev-parse dev)
git -c user.name="$NAME" -c user.email="$EMAIL" tag -a v1.8.0 -m "v1.8.0: node24 action pins + GIT_SHA build-arg + candidate-prune (opt-in) + pip hardening (welle 1)" "$SHA"
git push origin v1.8.0
git tag -f v1 "$SHA" && git push -f origin v1
git ls-remote origin refs/tags/v1 'refs/tags/v1.8.0^{}'   # beide -> $SHA
```

- [ ] **Step 3: CLAUDE.md-Resume** — im Kopf-Handoff nach dem v1.7.x-Block ergänzen:

```markdown
> **🏁 2026-06-10 WELLE 1 (Fleet-Endausbau, Umbrella `2026-06-10-ci-fleet-endausbau-design.md`): `@v1`=`v1.8.0`.**
> Node-24-Pins (20 Familien, 0 Node-20-Warnungen im Smoke), `GIT_SHA`-Default-Build-Arg (C2-Voraussetzung),
> `enable-candidate-prune` (referenced-safe, opt-in, Probelauf dokumentiert), pip retries 5/timeout 90.
> **NÄCHSTE WELLEN:** 2 = C2 `/health`-SHA je App (RecyclageApp→FootballApp→Rechnungsapp(dev)→MitarbeiterApp(inert))
> + a11y 12→0 + e2e RecyclageApp; 3 = OpenAPI+Playwright-Smoke je App; 4 = Watchtower-Flotte (DT4).
```

Commit: `docs(ci): welle 1 released — resume fuer wellen 2-4` + push dev.

---

## Self-Review (gegen Spec §1)

**Coverage:** Spec 1.1 Node-Pins→T4+T5(Step 3 Beweis) ✓ · 1.2 GIT_SHA→T1 ✓ · 1.3 Candidate-Prune→T3+T5(Step 4 Probelauf) ✓ · 1.4 pip→T2 ✓ · Validierung/Release→T5+T6 (inkl. R4-Fetch-Disziplin) ✓.
**Placeholder:** keine; Ziel-SHAs bewusst zur Laufzeit aufgelöst (Prozedur vollständig, inkl. annotated-tag-Deref + Major-Fallback).
**Konsistenz:** Input-Name `enable-candidate-prune` einheitlich (Input/Job-if/Step-if); IMAGE-Default-Expression identisch zum bestehenden Muster; upload/download-artifact-Paarung explizit.
