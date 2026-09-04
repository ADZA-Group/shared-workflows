# Plan 2026-09-04 — Deterministischer Deploy + Entrümpelung + Autonomie (v1.12.0)

Auftrag Azad: „mach den watchtower-api-trigger und entrümple die ci, mach alle erwähnten
punkte sauber fertig und mach meine CI autonom so wie es für uns (ich und du) gut ist".
Pair Claude + Codex, volles Verfahren (Design-Runde, dann Etappen, max 3 Runden je Etappe).

## Messbasis (GEMESSEN 04.09.)

- reusable-ci: 1663 Zeilen, 56 Inputs, davon 28 von keinem Caller gesetzt.
- Nightly rechnungsapp (Run 33850886225): 1264 Runner-Sekunden; CodeQL 332 s, Trivy-FS 120 s,
  Advisory-Jobs (Code-Quality, Dead-Code, TODOs, Licenses, OPA) ~70 s, Tests 319 s, Build 163 s.
- Webhook-Secrets (Discord/Slack/Telegram): in KEINEM Repo gesetzt → Notify-Kanäle tot.
- reusable-pipeline-analytics: 3 Caller, reusable-monitoring-dashboard: 2 Caller — Jarvis
  `/jarvis/ci` liest dieselben Daten direkt aus der GitHub-API.
- Watchtower: 203 nickfedor 1.17.2, Poll 3600 s, keine HTTP-API; 190 containrrr:latest (EOL),
  Poll 300 s, keine HTTP-API; Prod 102/103 Poll 3600 s (Juni-Messung).
- Semgrep aktiv: rechnungsapp 0 (nach Fix), recyclage 2, footballapp 16 → Semgrep-Gate bleibt
  Opt-in pro App; Bandit bleibt der fleetweite SAST-Gate bei risky.
- decide-runner: in 3 Org-Repos ohne RUNNER_SWITCH_PAT ⇒ immer self-hosted; nur
  MitarbeiterApp (User-Repo, kein Org-Runner) hat den PAT.

## Etappe A — Watchtower HTTP-API-Trigger (Deploy wird deterministisch)

Host-Seite (Staging 203 + 190: Claude; Prod 102 + 103: Azad per Kommando, LXC-Regel):
- Watchtower-Env: `WATCHTOWER_HTTP_API_UPDATE=true`, `WATCHTOWER_HTTP_API_TOKEN` (aus `.env`
  neben der Compose, `openssl rand -hex 32`, chmod 600), `WATCHTOWER_HTTP_API_PERIODIC_POLLS=true`
  (Polling bleibt Fallback), Port nur LAN: `192.168.1.<lxc>:8080:8080`.
- 190 zusätzlich: containrrr/watchtower:latest → nickfedor/watchtower:1.17.2 (EOL-Fix DT4).
- Repo-Composes (rechnungsapp staging/prod, recyclage staging/prod) spiegeln die Env, Token nur
  als `${WATCHTOWER_HTTP_API_TOKEN}`-Referenz.
CI-Seite (reusable-ci):
- Inputs `staging-watchtower-url`, `prod-watchtower-url` (default ""), Secrets
  `WATCHTOWER_STAGING_TOKEN`, `WATCHTOWER_PROD_TOKEN` (optional).
- verify-staging / verify-prod: Step „Trigger Watchtower" vor dem Health-Check:
  `POST $URL/v1/update` mit Bearer-Token, max 180 s; HTTP ≠ 2xx oder Timeout ⇒ `::warning::`
  und weiter (Polling-Fallback), nie ein Gate. Der Versions-Assert bleibt das Gate.
- Caller: rechnungsapp `staging-watchtower-url` + `staging-version-url` (jetzt sinnvoll, weil der
  Flip nicht mehr bis 3600 s dauert); recyclage `staging-watchtower-url`; Prod-URLs sobald Azad
  die Prod-Hosts umgestellt hat, dann `prod-version-url` überall.
Beweis: dev-Push recyclage + rechnungsapp → Trigger 2xx im Log, Versions-Assert bei Versuch 1–2
(vorher Versuch 3 bei 300 s bzw. gar nicht messbar bei 3600 s).

## Etappe B — Entrümpelung (Ziel: reusable-ci < 1000 Zeilen, ≤ 30 Inputs)

Raus (kein Caller / advisory ohne Konsument / toter Kanal):
- multi-arch (platforms, allow-multiarch-rebuild, QEMU, zweiter Build)
- gated-promotion (promote-prod, candidate-Tags, enable-candidate-prune, `_smoke-promotion`
  inkl. Release-Gate)
- api-contract, e2e, load-test, mutation (Jobs, Inputs, Reusables, Smokes)
- code-quality, dead-code, todo-tracker (Jobs)
- OPA-Job in security-scan (Composite bleibt für config-ci), dependency-review (privat = skip),
  Trivy-FS/IaC (Doppelung zu pip-audit + Trivy-Image; `trivy-fs` aus blocking-scanners)
- grype in security-weekly (Doppelung zu Trivy weekly + osv)
- Notify-Webhooks Discord/Slack/Telegram (nur GitHub-Issue bleibt), Caller-`secrets:`-Blöcke
- telemetry-Job, reusable-pipeline-analytics, reusable-monitoring-dashboard + die 5 Caller-
  Workflows (Jarvis-Cockpit ersetzt sie)
- prod-/staging-environment, ghcr-prune (Job + Inputs), cloud-runner-label (ein Runner-Label)
- TIA-observe + Flake-Ledger (kein Konsument); pytest-rerunfailures bleibt
- decide-runner in den 4 Callern (MitarbeiterApp: `runner-label: '["ubuntu-latest"]'`)
Bleibt: changes/light, lint (ruff, hadolint), tests + coverage (+diff-cov), test-results,
property-tests (Opt-out), license-check (main-Gate), commit-lint/pr-summary (PR), security
(gitleaks, bandit, semgrep, pip-audit, CodeQL nightly/main), frontend (a11y), dast (recyclage),
docker-build (Trivy-Image-Gate, SBOM, Smoke, cosign+SLSA NUR main/tags), branch-policy,
verify-staging/require-staging-green/verify-prod (+ Trigger), notify (Issue, Transitions),
weekly-cleanup, security-weekly (pip-audit, trivy, osv, trufflehog, nuclei), config-ci.
Nightly = Security-only: bei `schedule` setzt changes python/docker/frontend=false, security läuft.
Sicherheitsnetze: gate_matrix (angepasst: e2e/promote raus), Smokes, Release-Smokes.
Reihenfolge: Caller-Inputs zuerst entfernen (v1.11.x kennt sie noch), dann Release v1.12.0.

## Etappe C — Signaturen ehrlich

cosign + SLSA nur auf main/tags (Etappe B). Kein Verifizierer im Deploy-Pfad (Watchtower prüft
nichts) — dokumentiert. Kandidat später: Jarvis fleet-check verifiziert nachts den laufenden
Prod-Digest per `cosign verify`.

## Etappe D — Doku-Drift-Test

`scripts/check_docs.py` im actionlint-Gate: jeder reusable-ci-Input steht in der README-Tabelle,
jede Tabellenzeile existiert als Input.

## Etappe E — Autonomie

- `weekly-release.yml` (Mo 06:00 + Dispatch): dev ≠ @v1 und keine `.release-hold` ⇒ nächste
  Version (minor bei `feat`, sonst patch) ⇒ `scripts/release-v1.sh … --yes --no-wait` mit
  RELEASE_TOKEN als Push-Credential (GITHUB_TOKEN-Pushes lösen keine Workflows aus).
- Betriebsmodell in README: dev = Claude + Codex nach Gate, @v1 = Montag automatisch,
  Hold-Datei pausiert, Notfall-Release manuell, Dependabot nachts via Jarvis.

## Offen / Azad

- Prod-Hosts 102/103: Watchtower-Env + Token + Port (Kommandos im Handoff), danach Prod-Trigger
  und `prod-version-url` aktivieren.
- Semgrep-Findings recyclage (2) und footballapp (16): eigene Aufträge.
- Org-Allowlist, 104-Cron: unverändert Entscheide.
