# Design: C1-Iteration-2 — Candidate-Tag-Promotion + Branch-Policy-Gate

> **Stand:** 2026-06-09 · Branch `dev` · baut auf v1.6.0 (C1-It.1) auf
> **User-Entscheidungen:** (1) Candidate-Tag + Rebuild-and-Gate; (2) `gated-promotion` opt-in per App;
> (3) Branch-Policy HART, kein Break-Glass — Direct-Push auf main blockt ALLES; (4) immer dev→main.

## 0. Motivation

Zwei verbleibende Lücken nach v1.6.0:

1. **C1-Residuum:** Auf `main`-Push pusht `docker-build` `:latest` **im Build-Job** — Watchtower deployt
   Prod, **bevor** `verify-staging`/`require-staging-green` laufen. Das Staging-Gate ist post-hoc.
2. **Branch-Disziplin nicht enforced:** `git push` direkt auf `main` umgeht den dev→Staging-Flow komplett.
   Echte Branch-Protection (Server-seitiges Reject) ist auf privaten Repos im Free-Plan **PAID**
   (GitHub Team; analog zum dokumentierten 422-Befund bei required-reviewers, Phase E). FootballApps
   Alt-CI hatte einen „Branch Policy"-Job — ging bei der P4-Migration verloren (wie e2e).

## 1. Scope

**In Scope:**
- **`branch-policy`-Job** in `reusable-ci.yml` (default AN, hart): jeder `main`-Push muss über `dev`
  gekommen sein, sonst rot → blockt docker-build/promote → kein Prod-Image.
- **`gated-promotion`** (opt-in, default `false`): main baut+pusht `:candidate-<sha>` statt `:latest`;
  neuer `promote-prod`-Job retaggt erst nach `require-staging-green` → Watchtower deployt Prod gegatet.
- **Smoke** `_smoke-promotion.yml`: (a) Policy-Logik-Unit-Test gegen synthetische Git-Historie,
  (b) Retag-Mechanik-Test (push `:candidate` → `imagetools create :latest` → Digest-Assert).
- **Rollout-Versuch echte Branch-Protection** via `gh api` pro App-Repo (erwartbar 403/422 auf Free;
  greift automatisch bei späterem Team-Upgrade; Ergebnis dokumentieren).
- Docs (README Caller-Contract, CLAUDE.md Resume).

**Out of Scope:** FootballApp-Pilot-Aktivierung (`gated-promotion: true` im Caller) = separater,
user-gateter Folgeschritt nach dem Release. Kein Break-Glass-Mechanismus (User-Entscheid).

## 2. Design

### 2.1 `branch-policy` (reusable-ci.yml, neuer Job — default AN)

```
if: github.ref == 'refs/heads/main' && github.event_name == 'push' && inputs.enforce-branch-policy
```

Logik (checkout `fetch-depth: 0` + `git fetch origin dev`):
- **PASS** wenn `git merge-base --is-ancestor HEAD origin/dev` (Fast-Forward-Merge: main HEAD liegt auf dev), ODER
- **PASS** wenn HEAD ein Merge-Commit ist UND `git merge-base --is-ancestor HEAD^2 origin/dev`
  (`--no-ff`-Merge / PR-Merge: zweiter Parent ist dev-Stand), sonst
- **FAIL** mit klarer Meldung: *„main wurde nicht über dev befüllt — Iron Law: dev→Staging-grün→main.
  Heilung: Änderung auf dev nachziehen und dev→main mergen."*

Verdrahtung: `docker-build.needs` += `branch-policy`; Guard
`(needs.branch-policy.result == 'success' || needs.branch-policy.result == 'skipped')`
(skipped auf dev/PR/dispatch/Tags; auf main-Push MUSS er success sein = fail-closed).
`telemetry` bekommt `branch-policy` (needs + Summary-Zeile).

Input `enforce-branch-policy` (boolean, default **true**) — Not-Aus für die Bibliothek, kein
Break-Glass pro Push. Default-AN ist gewollt: regelkonforme main-Pushes (dev-Merges) passieren
unverändert; nur Verstöße brechen.

### 2.2 `gated-promotion` (opt-in, default `false`)

**`reusable-docker-build.yml`:**
- Neuer Input `gated-promotion` (boolean, default `false`).
- Metadata-Tags (die ref-basierten Zeilen aus `cdef1d7`):
  - `:staging` (dev) **unverändert**.
  - `:latest`-Zeile: `enable=${{ github.ref == 'refs/heads/main' && !inputs.gated-promotion }}`.
  - NEU: `type=raw,value=candidate-${{ github.sha }},enable=${{ github.ref == 'refs/heads/main' && inputs.gated-promotion }}`
    (per-SHA-Tag, kein Moving-Tag → keine Race bei aufeinanderfolgenden main-Pushes).
- `:latest→:previous`-Backup-Step: zusätzlich `&& !inputs.gated-promotion` (im gated-Mode macht
  der Promote-Job das Backup, denn erst dort bewegt sich `:latest`).
- Neuer Workflow-Output `candidate-tag` (`<image>:candidate-<sha>`; leer wenn nicht gated).

**`reusable-ci.yml`:**
- Neuer Input `gated-promotion` (default `false`), durchgereicht an docker-build.
- Neuer Job **`promote-prod`**:
  ```
  needs: [docker-build, require-staging-green]
  if: always() && inputs.gated-promotion && inputs.deploy-prod &&
      github.ref == 'refs/heads/main' && github.event_name == 'push' &&
      needs.docker-build.result == 'success' &&
      needs.require-staging-green.result == 'success'
  permissions: { contents: read, packages: write }
  ```
  Steps: GHCR-Login → Backup `:latest`→`:previous` (continue-on-error, wie heute) →
  `docker buildx imagetools create --tag <image>:latest <image>:candidate-<sha>` → Notice.
  Digest-stabil: Retag bewegt nur den Tag — cosign/SLSA-Signatur (auf dem Digest) bleibt gültig,
  Multi-Arch-Index wird mitgenommen.
- **`verify-prod`**: `needs` += `promote-prod`; Guard +=
  `(needs.promote-prod.result == 'success' || needs.promote-prod.result == 'skipped')`
  (gated: erst nach Promotion verifizieren; nicht-gated: promote skipped → Verhalten wie heute).
  C2-version-assert funktioniert im gated-Mode sauber: Prod muss `github.sha` melden.
- `telemetry` += `promote-prod`.

**Fail-Safe-Eigenschaft:** Staging rot ⇒ `require-staging-green` rot ⇒ `promote-prod` läuft nicht ⇒
`:latest` unverändert ⇒ Prod bleibt auf dem letzten guten Image. `:candidate-<sha>` liegt in GHCR
bereit für manuelles Promote nach Fix (`docker buildx imagetools create --tag :latest :candidate-<sha>`).

**Caller-Contract:** `gated-promotion: true` **erfordert** `staging-url` (sonst skippt
`require-staging-green` → promote läuft nie → `:latest` friert ein). Wird im README als Pflicht
dokumentiert + Risiko R2.

### 2.3 Echte Branch-Protection (Best-Effort, Rollout-Schritt)

Pro App-Repo einmalig `gh api -X PUT repos/{org}/{repo}/branches/main/protection` versuchen
(required PRs, kein Force-Push, keine Deletion). Auf Free+privat erwartbar 403/422 → Ergebnis
dokumentieren, kein Blocker (der CI-Gate aus 2.1 ist die wirksame Free-Tier-Enforcement-Schicht:
der Push landet zwar im Repo, ist aber operativ wirkungslos — kein Build, kein Deploy, Run rot, Notify).

## 3. Artefakte

| Datei | Art | Inhalt |
|---|---|---|
| `.github/workflows/reusable-ci.yml` | edit | `branch-policy`-Job + `enforce-branch-policy`/`gated-promotion`-Inputs + `promote-prod`-Job + verify-prod/telemetry/docker-build-Wiring |
| `.github/workflows/reusable-docker-build.yml` | edit | `gated-promotion`-Input, candidate-Tag, latest/Backup-Konditionen, `candidate-tag`-Output |
| `.github/workflows/_smoke-promotion.yml` | neu | 2 Jobs: policy-logic (synthetische Git-Repos: ff-merge ✓ / no-ff-merge ✓ / direct-commit ✗) + retag-Mechanik gegen `ghcr.io/adza-group/shared-workflows` Scratch-Tags |
| `README.md` | edit | gated-promotion-Contract (+staging-url-Pflicht), branch-policy-Verhalten, manuelles Promote/Rollback-Runbook |
| `CLAUDE.md` | edit | Resume-Update (It.2 gebaut; offen: FootballApp-Pilot, Branch-Protection-API-Befund) |

## 4. Validierung

1. actionlint + yamllint auf alle geänderten/neuen Workflows.
2. `_smoke-promotion.yml` auf ubuntu (temp `push:[dev]`-Trigger, danach zurück): policy-Job testet
   die Ancestry-Logik deterministisch in-job (3 synthetische Fälle), retag-Job beweist
   `imagetools create` + Digest-Gleichheit real gegen GHCR.
3. `_smoke-ci.yml`-Dispatch (dev): beweist, dass die neuen Jobs auf Nicht-main-Pfaden sauber
   skippen (branch-policy skipped, promote-prod skipped, docker-build baut wie in v1.6.0).
4. **Bewusste Grenze:** der echte main-Pfad (candidate→promote→verify) ist per Smoke nicht voll
   simulierbar (Smokes laufen nicht als main-Push). End-to-End-Beweis = FootballApp-Pilot
   (opt-in, separater user-gateter Schritt). Bis dahin: Logik-Beweis + Mechanik-Beweis + Review.

## 5. Rollout

- Build auf `dev`; neue interne Refs: keine nötig (kein neuer Sub-Reusable — promote ist ein
  normaler Job). Release `v1.7.0` + `@v1` force-move nach Verlust-Check (Muster v1.6.0).
- **Fleet-Wirkung bei Release:** `branch-policy` default AN (blockt nur Verstöße; regelkonforme
  dev→main-Merges unverändert). `gated-promotion` default AUS (kein Verhaltenswechsel).
- Danach (user-gated, einzeln): FootballApp-Caller `gated-promotion: true` als Pilot; nach Bewährung
  Rest der Fleet. Branch-Protection-API-Versuch auf den 4 App-Repos + Befund.

## 6. Risiken

- **R1 — Alt-Automationen, die nicht via dev auf main pushen** (z.B. RecyclageApps `release-please.yml`
  mergt `release-please--*`-Branches nach main): würden vom branch-policy-Gate geblockt. Befund beim
  Rollout prüfen; Lösung dann: Automation auf dev retargeten oder abschalten — KEIN Allow-Pattern im
  Gate (User-Entscheid: hart, keine Ausnahmen).
- **R2 — gated-promotion ohne staging-url** friert `:latest` ein (promote läuft nie). Mitigation:
  README-Pflicht + Risiko dokumentiert; Caller-Review beim Pilot.
- **R3 — Watchtower-Poll-Lag nach Promote:** verify-prod pollt bis 40×30s=20min — deckt den 5-min-Poll
  locker. C2-version-assert (wenn App-seitig aktiv) macht den Check scharf statt 200-only.
- **R4 — Erster gated Run einer App:** `:previous` existiert evtl. nicht (Backup no-op, wie heute
  continue-on-error) — harmlos, dokumentiert.
