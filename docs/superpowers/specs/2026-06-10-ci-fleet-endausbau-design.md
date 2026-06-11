# Design: CI-Fleet-Endausbau — Programm in 4 Wellen (Umbrella)

> **Stand:** 2026-06-10 · Library `@v1` = `v1.7.2` · Pilot gated-promotion E2E bewiesen (RecyclageApp #391/#395)
> **User-Entscheidungen:** Scope = A (Fleet-Aktivierung) + C (Smoke-first-Contracts) + D (Infra-Härtung).
> B (FootballApp-Staging-LXC) ABGEWÄHLT. C-Tiefe = Smoke-first (kein flask-smorest-Refactor).
> Rechnungsapp-gated-promotion = separater Schritt NACH dem user-gated Debt-Merge.
> **Arbeitsmodus:** Jede Welle = eigener Plan-Zyklus (writing-plans → subagent-driven-development),
> einzeln shipbar, Validierung nach Repo-Muster (actionlint + Ubuntu-Smokes + dev→Staging→main).

## 0. Ausgangslage

Die CI-Bibliothek ist fertig (A–F, C1-It.1+It.2, C2, Phase G; dreifach bewiesener gated-promotion-Pilot).
Was fehlt, ist **Aktivierung** (Apps nutzen gebaute Features nicht) und **Infra-Hygiene**. Live demonstrierte
Lücken: verify-prod grün während Prod alt lief (C2 inaktiv), `:candidate-*`-Akkumulation, Watchtower-EOL+
Doku-Drift, Runner-pip-Flakes, Node-20-Deprecation (Force-Switch 2026-06-16).

## 1. Welle 1 — Library-Abschluss (`shared-workflows` → Release `v1.8.0`)

1. **Node-24-Pins (DEADLINE 2026-06-16):** alle SHA-gepinnten Actions (checkout, cache,
   upload-/download-artifact, setup-node, setup-buildx/qemu/login/build-push/metadata, cosign-installer,
   delete-package-versions, paths-filter, publish-unit-test-result, …) auf aktuelle Node-24-taugliche
   Releases heben — über ALLE reusable-*.yml + Composites. Per `gh api` die neuesten Release-SHAs holen
   (keine Floating-Tags; Pin-Policy bleibt).
2. **`GIT_SHA`-Default-Build-Arg** in `reusable-docker-build.yml`: beide build-push-Steps bekommen
   zusätzlich `GIT_SHA=${{ github.sha }}` in `build-args` (append an Caller-build-args). Voraussetzung
   für C2-App-Aktivierung (Welle 2) — Apps konsumieren via `ARG GIT_SHA` / `ENV APP_SHA`.
3. **Candidate-Tag-Cleanup (referenced-safe):** Erweiterung in `prune-ghcr` (eigener Step, eigener
   Opt-in `enable-candidate-prune`, default false → Pilot RecyclageApp): löscht GHCR-Versionen NUR wenn
   (a) ALLE Tags der Version matchen `^(candidate-|main-[0-9a-f]{7})`, (b) KEINES von
   `latest|previous|staging|staging-previous|main|dev` dabei ist, (c) älter als 14 Tage.
   Promotete Candidates tragen `latest`/`main` am selben Digest → automatisch geschützt.
   Bewusst NICHT das untagged-Prune (dokumentiert UNSAFE, Risk #2 bleibt offen).
4. **Runner-pip-Härtung** in `setup-python-deps`: `--retries 5` + `PIP_DEFAULT_TIMEOUT=90`-Env
   (IncompleteRead-Klasse; pips parallele Batch-Downloads respektieren das Retry-Flag nur teilweise —
   mehr Versuche + längeres Timeout senken die Flake-Rate, Heilung bleibt Re-Run).

Validierung: `_smoke-composites-ubuntu` + `_smoke-ci` + `_smoke-docker-build` + `_smoke-promotion`;
Release `v1.8.0` + `@v1`-Move nach Verlust-Check (Muster v1.6.0/v1.7.x; bekanntes Parallel-Session-Risiko →
IMMER frisch fetchen + Loss-Check direkt vor dem Move).

## 2. Welle 2 — Sicherheits-Aktivierung pro App

**A1 — C2 `/health`-SHA** (Pattern identisch je Flask-App):
- Dockerfile: `ARG GIT_SHA=dev` → `ENV APP_SHA=${GIT_SHA}` (Runtime-Stage).
- `/health`-Route: `{"status":"ok","sha":APP_SHA}` (bestehende Response erweitern, nicht ersetzen).
- Caller: `staging-version-url`/`prod-version-url` auf die `/health`-URL.
- Reihenfolge: **RecyclageApp** (bewährter Pilot; macht gated-promotion-verify scharf) →
  **FootballApp** (nur `prod-version-url`; kein Staging) → **Rechnungsapp** (App-Code+Caller auf dev;
  wird mit dem user-gated Debt-Merge aktiv) → **MitarbeiterApp** (nur `/health`-Code; kein Deploy-Ziel
  konfiguriert → inert, dokumentiert).
- Test je App: Unit-Test auf `/health`-sha-Feld; E2E-Beweis = verify-staging/prod-Assert im echten Run.

**A5 — a11y 12→0 (RecyclageApp Login-Seite):** Kontrast-Fixes (muted-Text `#94a3b8`→dunkler auf hellem
Grund; Logo-„A" Hintergrund-Grün Richtung empfohlenem `#09ac45`-Bereich bzw. Textgewicht). Minimaler
visueller Eingriff, KEIN Redesign; pa11y-Verifikation über den dev-Run (advisory zeigt Count), Ratchet
im Caller schrittweise 12→0. UI-Review-Skill (audit/polish) nach dem Fix.

**A3 — e2e RecyclageApp aktivieren:** vorhandene Playwright-Specs an den `reusable-e2e`-Contract anpassen
(eigenes `e2e/`-Verzeichnis mit package.json `@playwright/test@1.60.0`, baseURL localhost; boot via
gunicorn + gebautem Frontend — Boot-Detail klärt der Wellen-Plan) + Caller `enable-e2e: true` +
`e2e-boot-command`/`e2e-health-url`.

## 3. Welle 3 — Smoke-first-Contracts (pro App)

- **OpenAPI minimal:** statisch/semi-generiert `openapi.json` (Kern-Endpoints: health, Auth, 3–6
  wichtigste API-Routen) + Flask-Route `GET /openapi.json`; Caller `openapi-spec` + `api-boot-command` +
  `api-health-url` → **api-contract (Phase D) läuft real** (schemathesis fuzzt die deklarierte Fläche).
- **Playwright-Smoke** für FootballApp, Rechnungsapp, MitarbeiterApp (Login + 1–2 Kern-Flows; Muster aus
  Welle-2-RecyclageApp wiederverwenden) + `enable-e2e` je Caller.
- Je App eigener dev→Staging→main-Zyklus; MitarbeiterApp ohne Deploy-Tail (Tests laufen, kein verify).

## 4. Welle 4 — Infra-Härtung (SSH/Proxmox, parallelisierbar zu 2/3)

- **DT4:** Watchtower-Inventur ALLER App-LXCs (102, 103, 105, 190, 203): Image (containrrr EOL?),
  `WATCHTOWER_POLL_INTERVAL`, Creds-Mount, label-enable. Migration containrrr→`nickfedor/watchtower:latest`
  wo nötig (zuerst Staging-LXC als Probe, dann Prod; Compose auf LXC editieren + Repo-Compose nachziehen,
  Drift-Warnung in RecyclageApp-CLAUDE.md beachten).
- **Doku-Abgleich:** reale Poll-Intervalle/Configs in die jeweiligen CLAUDE.mds (Muster der
  2026-06-10-Korrektur).
- Verifikation je LXC: Watchtower-Container healthy, ein beobachteter Pull-Tick, App healthy.

## 5. Bewusste Grenzen (dokumentiert, NICHT vergessen)

- **Kein FootballApp-Staging** (B abgewählt) → FootballApp bleibt beim Direkt-`:latest`-Deploy mit
  C1-It.1-Gates; gated-promotion dort unmöglich bis ein Staging-LXC existiert.
- **Rechnungsapp gated-promotion**: erst NACH dem user-gated Audit-Debt-Merge, als separater kleiner Schritt.
- **MitarbeiterApp**: kein Prod-/Staging-Ziel konfiguriert → C2/verify inert; nur Code+Tests.
- **GHCR untagged-Prune** bleibt UNSAFE/aus (Risk #2); Welle 1 räumt nur candidate-Tags referenced-safe.

## 6. Definition of Done (Programm)

1. `@v1` = `v1.8.x`, hermetisch, alle Smokes grün, 0 Node-20-Action-Warnungen in einem Fleet-Run.
2. Alle 4 Apps grün auf main; RecyclageApp + FootballApp verifizieren Deploys per SHA-Assert
   (Rechnungsapp ab Debt-Merge; MitarbeiterApp n/a dokumentiert).
3. api-contract + e2e laufen bei allen 4 Apps real (nicht skipped) und sind grün.
4. RecyclageApp a11y-Ratchet = 0.
5. Candidate-Prune aktiv (mind. RecyclageApp) und nachweislich nur unreferenzierte candidate-Versionen löschend.
6. Watchtower-Flotte: kein containrrr mehr, reale Configs dokumentiert.

## 7. Risiken

- **R1 Node-Pin-Bumps** können Verhaltensänderungen der Actions mitbringen (v4→v5-Majors) → pro Action
  Changelog prüfen, Smokes als Gate, ein Bump-Commit pro Action-Familie für leichtes Bisect.
- **R2 a11y-Farbfixes** berühren die Marken-Optik → minimal-invasiv, Screenshot im PR/Step-Summary,
  User kann veto-en.
- **R3 e2e-Boot der Flask+React-Apps** im Playwright-Container (Frontend-Build nötig) → Wellen-Plan
  klärt Boot-Pattern; Fallback: e2e gegen `a11y-url`-Staging statt lokalem Boot (schwächer, dokumentieren).
- **R4 Parallel-Sessions** (2× erlebt) → vor jedem Release fetch+Loss-Check; vor jedem App-Push rebase.
- **R5 Watchtower-Migration** auf Prod-LXCs = kurzer Watchtower-Neustart (App läuft weiter); Staging zuerst.
