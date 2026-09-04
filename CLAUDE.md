# CLAUDE.md — `shared-workflows` (ADZA-Group Unified CI)

> **Für Claude (neue Session):** Dies ist der Wiederaufnahme-Handoff für die Unified-CI-Initiative.
> Stand **2026-07-21**, branch `dev`. **Released: floating `@v1` = `v1.10.1` (commit `c98ad45`, ls-remote-verifiziert).**
>
> **✅ RELEASED 2026-09-03 (User via release-v1.sh, ls-remote-verifiziert): `@v1` = `v1.10.7` = `98d49c7`** — Fix A+X ist fleet-live.
> Fleet-Beweis: rechnungsapp Run 33750934660 (Attempt 2 grün; Attempt 1 fiel im ALTEN zweiten buildx-Push an
> „failed to fetch anonymous token … ghcr.io/token … 403" — genau der Schritt, den die Audit-Welle unten abschafft).
>
> **🏗️ 2026-09-04 NACHMITTAGS — „Watchtower-Trigger + Entrümpelung + Autonomie" (Azad: „mach alle erwähnten Punkte sauber fertig,
> CI autonom wie es für uns gut ist"; Plan `docs/superpowers/plans/2026-09-04-ci-entruempelung-deploy-trigger.md`; Pair: Design-Runde
> 3 Funde, Etappe A 1 Runde, Etappe B 2 Runden 3 Funde, Trigger-Nachtrag 1 Fund — alle umgesetzt):**
> **A Deterministischer Deploy (v1.11.4 = 6d8323d):** Inputs `staging-/prod-watchtower-url` + Secrets `WATCHTOWER_STAGING_TOKEN`/
> `WATCHTOWER_PROD_TOKEN`; verify-* stoesst `POST /v1/update` an (fail-open, changes-Job erzwingt version-url + Token). Hosts: 203 + 190
> HTTP-API aktiv (Token nur in `.env`, Port nur LAN; 190 zugleich containrrr:latest → nickfedor 1.17.2). GEMESSEN recyclage Run 33855761270:
> Trigger HTTP 200, Versions-Match bei Versuch 1 (vorher 3); rechnungsapp Run 33855783178: Trigger lief 180 s ins Timeout (grosses Image),
> Flip trotzdem bei Versuch 4 (vorher 200-only, Poll 3600 s) ⇒ Trigger wartet seit dem Folge-Commit nicht mehr (max-time 20, rc 28 nur mit
> `remote_ip` = ausgeloest). rechnungsapp hat jetzt `staging-version-url` (Watchtower-Entscheid 07-10 obsolet).
> **Prod (Azad, LXC-Regel) — exakte Schritte je Host (103 rechnungsapp, 102 recyclage):** (1) `cd /opt/<app>` (103: `/opt/rechnungsapp`,
> 102: Compose-Verzeichnis der Prod-App); (2) `openssl rand -hex 32 | sed 's/^/WATCHTOWER_HTTP_API_TOKEN=/' >> .env; chmod 600 .env`;
> (3) Watchtower-Service in der Prod-Compose um die Zeilen aus `docker-compose.yml` im Repo ergaenzen (`WATCHTOWER_HTTP_API_UPDATE`,
> `WATCHTOWER_HTTP_API_TOKEN`, `WATCHTOWER_HTTP_API_PERIODIC_POLLS`, `ports: 192.168.1.<lxc>:8080:8080`; 102 zusaetzlich Image
> nickfedor/watchtower:1.17.2); (4) `docker compose up -d watchtower`; (5) Token als Secret: `ssh root@192.168.1.<lxc> "grep ^WATCHTOWER_HTTP_API_TOKEN= /opt/<app>/.env | cut -d= -f2-" | gh secret set WATCHTOWER_PROD_TOKEN -R ADZA-Group/<repo>`;
> (6) Caller: `prod-watchtower-url: "http://192.168.1.<lxc>:8080"` + `prod-version-url: "<prod-url>/health"` + Secret-Mapping
> `WATCHTOWER_PROD_TOKEN`. Danach beweist verify-prod den Prod-Deploy (Versions-Assert) statt 200-only.
> **B Entrümpelung (v1.12.0):** reusable-ci 1663 → 987 Zeilen, 56 → 36 Inputs, 17 Jobs. Raus: multi-arch, gated-promotion (+promote-prod,
> require-staging-green, candidate), api-contract, e2e, load-test, mutation, code-quality, dead-code, todo-tracker, telemetry, notify
> (Webhooks — in KEINEM Repo Secrets), pipeline-analytics, monitoring-dashboard, TIA + Flake-Radar/-Ledger (inkl. Plugin), OPA/Trivy-FS/
> dependency-review im Push-Scan, grype weekly, cloud-runner-label, environments, ghcr-prune, `_smoke-{api-contract,e2e,mutation,promotion,
> release}`. Verhalten: verify-staging NUR dev-Pushes (main pusht nie :staging — mit Versions-Assert waere main rot gewesen), verify-prod
> direkt an docker-build, Nightly = Security-only (Schedule-Override als LETZTE Normalisierung setzt PY/DK/FR/CI/RISKY/FULLCI=false;
> security.if hat `schedule ||`), cosign+SLSA nur main/tags (Staging unsigniert, kein Verifizierer). Caller: decide-runner in allen 4
> Repos entfernt (MitarbeiterApp `runner-label: ubuntu-latest`), tote Inputs + Webhook-Secrets raus, 5 Analytics-/Dashboard-Workflows
> geloescht; jarvis security.yml ohne `run-opa` (dev+main). **Vorfall:** Kommentar-Entferner riss den `branch-policy`-Header mit —
> actionlint fing es, aus HEAD wiederhergestellt.
> **C** Signaturen: nur main/tags; Verifizierer im Deploy-Pfad gibt es nicht (Kandidat: Jarvis fleet-check `cosign verify` nachts).
> **D** `scripts/check_docs.py` im actionlint-Gate: README-Input-Tabelle == reusable-ci-Inputs (36/36).
> **E** `weekly-release.yml`: Mo 06:00 UTC dev → @v1, nur wenn dev vor @v1, actionlint-Gate fuer den SHA gruen, keine offenen Laeufe
> (eigener Lauf ausgenommen), keine `.release-hold`; minor bei `feat`, sonst patch; RELEASE_TOKEN nur im Checkout dieses Jobs, keine
> `git config` (Hausregel). Betriebsmodell in README.
> **Werkzeug-Fallen dieser Runde:** Bash-Wrapper verschluckt Backslashes auch in Heredoc-Python (Skript per Write-Tool schreiben, dann
> ausfuehren); Klassifikator blockte ein Host-Skript mit Image-Pull auf 190 (in zwei enge Schritte geteilt → durch); `str.format` frisst
> `${VAR}`-Platzhalter in Compose-Templates (replace statt format).
> **✅ RELEASED 2026-09-04 NACHMITTAGS AUTONOM (Run 33853219123, Kandidat aus dev `057cdfa`, ls-remote-verifiziert): `@v1` = `v1.11.3` = `057cdfa`** —
> Semgrep-Zaehler (Stufe C) zaehlt per `nosemgrep` unterdrueckte SARIF-Treffer (`suppressions`, kind inSource) nicht mehr als Findings, sondern
> weist sie getrennt aus („+N per nosemgrep unterdrueckt"). Ausloeser GEMESSEN rechnungsapp Run 33850886225: SARIF 45 = 42 unterdrueckt + 3 aktiv,
> Konsole „3 findings", Summary sagte „45 Finding(s)". Gate/`--error` waren nie betroffen (Semgrep ignoriert nosemgrep-Treffer selbst).
> **✅ RELEASED 2026-09-04 MITTAGS AUTONOM (Run 33849447536, Kandidat aus dev `f92e6cf`, ls-remote-verifiziert): `@v1` = `v1.11.2` = `f92e6cf`** — Inhalt: Opt-in Dual-Gate, `dast-blocking`, grype-sha256, Dependabot-Bumps (PR #16), Doku. Kandidaten-Branch vom Workflow geloescht.
> **🧹 2026-09-04 MITTAGS — „alle offenen Punkte weiter" (Pair Claude+Codex, 2 Runden, 2 Doku-Funde umgesetzt), dev `f92e6cf`:**
> **Opt-in Dual-Gate pro App:** `security-blocking-scanners` (CSV aus semgrep,trivy-fs,pip-audit) + `dast-blocking` in reusable-ci; Default
> bleibt advisory (Policy-Entscheid liegt beim Caller). changes-Job normalisiert + validiert (unbekannter Name ⇒ exit 1), reusable-security-scan
> bekommt `blocking-scanners`; Semgrep `--error` nur im Blocking-Modus, Trivy-fs `exit-code` 1, pip-audit gibt den Exit erst NACH dem Summary
> weiter (`bash -e` brach das Summary bei Funden ab — war schon immer so), Summaries zaehlen im Blocking-Modus die SARIF auch bei Step-Failure.
> **Entscheidungsdaten GEMESSEN:** rechnungsapp main (Run 33517302434) Semgrep 2 Findings (dynamic-urllib, defused-xml), Nightly dev 3;
> pip-audit 0; Trivy-fs ohne Zaehler (vor Stufe C). recyclage/footballapp haben seit >30 Tagen keinen main-CI-Run (Cleanup-Retention) ⇒
> nicht messbar. Konsequenz: `semgrep` scharf = rechnungsapp-main sofort rot, bis die 2 Findings gefixt/ignoriert sind.
> **CoE-Messung (schliesst die ANNAHME des Audits):** Run 33847987446 in diesem Repo — Job mit `continue-on-error: true` und rotem Step hat
> API-Conclusion `failure`, aber `needs.<job>.result` == `success`, Run gruen ⇒ advisory Jobs koennen docker-build nie blocken.
> **grype:** Release-Tarball v0.115.0 mit sha256 `3fad9294…2b90e` nach `$RUNNER_TEMP` (Layout GEMESSEN: grype auf Top-Level). Damit ist Fund 7 komplett.
> **MitarbeiterApp (azad-ahmed/MitarbeiterApp, privat, inert):** Dependabot-Backlog aufgeloest — #35 (frontend minor/patch), #32 (pyjwt), #15
> (pillow) gemergt (CI gruen, kein Deploy); #13/#14 (setup-python/build-push-action) und #16 (flask-cors 6) von Dependabot selbst als obsolet
> geschlossen (Thin-Caller nutzt die Actions nicht mehr). Offen bleibt nur Azads eigener PR #19. Jarvis kann das Repo nicht bedienen (S1-Token).
> **104-Cron (P3 R) GEMESSEN:** `/opt/runner-backup/backup-credentials.sh` sichert woechentlich NUR die Runner-Registrierung (.runner/.credentials/
> .env/.service + controller-Skripte) GPG-symmetrisch (AES256, Key `/root/.runner-backup-key`), 4 Stueck à 14 KB, 84 KB gesamt. Empfehlung: behalten —
> kein Daten-Backup im Sinne der Fleet-Regel, sondern Re-Registrierungs-Sicherung nach LXC-Verlust. Entscheid Azad.
> **Org-Policy (P2 G Rest) GEMESSEN:** `allowed_actions: all`. Inventar aller `uses:` in allen 8 Org-Repos (default+main+dev): ausser `actions/*`,
> `github/*` und `./` nur: aquasecurity/trivy-action · dependabot/fetch-metadata · docker/{build-push,login,metadata,setup-buildx,setup-qemu}-action ·
> dorny/paths-filter · EnricoMi/publish-unit-test-result-action · googleapis/release-please-action · ossf/scorecard-action · sigstore/cosign-installer ·
> softprops/action-gh-release · trufflesecurity/trufflehog. Vorschlag (Azad, org-weit, reversibel):
> `gh api -X PUT orgs/ADZA-Group/actions/permissions -f enabled_repositories=all -f allowed_actions=selected` und
> `gh api -X PUT orgs/ADZA-Group/actions/permissions/selected-actions -F github_owned_allowed=true -F verified_allowed=true --input allowlist.json`
> mit `patterns_allowed` = obige Liste als `owner/repo@*` (MitarbeiterApp ist User-Repo, nicht betroffen). Nicht angewendet: Blast-Radius fleetweit.
> **cosign-Cache-Beweis:** footballapp taugt nicht (`sign-image: false`, Attestations = paid); recyclage-Dockerfile-Kommentar `a086bce` (risky ⇒
> nicht-light, self-hosted) ist der Beweistraeger. **GEMESSEN Run 33848959344 (proxmox-runner-3):** „Install cosign (self-hosted, cached +
> verified)" success, „Cosign sign (keyless)" success, „SLSA build provenance" success, Verify Staging success — der cosign-Cache-Pfad auf 104
> (Fund D) ist damit real durchlaufen; der letzte offene Beweis des Audits ist geschlossen.
> **Erste Opt-in-Aktivierung (Azad, 04.09. mittags):** rechnungsapp-Caller `security-blocking-scanners: "pip-audit"` (dev f173f80) — blockt
> auf main/tags und bei risky, advisory sonst; Stand 0 CVEs. GEMESSEN Push-Run 33850175205: changes-Job „Opt-in blocking scanners: pip-audit"
> (Validierung + Durchreichung). Semgrep bewusst nicht (2 Findings auf main). Das BLOCKING-Label erscheint erst beim naechsten main-Push.
> **Opt-in-Gate GEMESSEN (Wegwerf-Branch `proof-blocking` mit Semgrep-Kanarienvogel, `_smoke-security-scan` per Dispatch, danach geloescht):**
> (i) `blocking-scanners=semgrep` + `force-blocking=true` → Run 33849433971: Semgrep-Job ROT (`--error`), Summary „BLOCKING … 3 Finding(s)";
> Bandit ROT (Dual-Gate wie bisher), Trivy-fs gruen (nicht in der Liste). (ii) `force-blocking=true` ohne Liste → Run 33849512854: Semgrep
> gruen/advisory mit gezaehlten 3 Findings, Bandit ROT. (iii) `blocking-scanners=semgrep` ohne force auf Nicht-main → Run 33849588446: alles
> gruen (Dual-Gate greift ausserhalb main/tags nur mit force). Der Beweis nutzt das lokale `./…/reusable-security-scan.yml` = exakt dev f92e6cf.
> **✅ RELEASED 2026-09-04 AUTONOM (Run 33844735506, Kandidat aus dev `8fee14b`, ls-remote-verifiziert): `@v1` = `v1.11.1` = `8fee14b`.**
> Inhalt (Stufen 0–6 der „was machen wir noch besser"-Runde, Pair Claude+Codex, 3 Runden, keine offenen Funde):
> **0** Glob-Regression aus der env-Umstellung gefixt — `run-pytest-shard` expandiert `TEST_PATHS` wieder per Shell
> (`SELECT=($TEST_PATHS)`, `read -ra` globbt NICHT) + Existenz-Check je Token (`::error::test path '…' existiert nicht`);
> `_smoke-ci` shardet `tests/fixtures/app/test_*.py` als Dauer-Regressionstest. Fleet-Beweis: footballapp Dispatch 33845042565
> (Shard `ml` mit `tests/test_features_*.py` grün). **1** Verify beweist den Deploy: `health-check` liest `sha`→`commit`→`version`;
> recyclage-Caller `staging-version-url` (dev `f70ca87`; Watchtower 190 = 300 s, Budget 40×30 s). rechnungsapp bleibt 200-only
> (Watchtower 203 = 3600 s, dokumentierter Entscheid Audit 07-10); `prod-version-url` NIRGENDS (Prod-Watchtower 3600 s →
> falscher Rollback). **2** Dependabot für dieses Repo (`.github/dependabot.yml`, Gruppe `actions`), PR #16 (6 Bumps, alle Minor/
> Patch, Tag↔SHA je ls-remote geprüft) per Cherry-Pick auf dev `3d7ea24` gebracht (gh-Token ohne `workflow`-Scope kann PR-Merges
> mit Workflow-Dateien nicht; Dependabot schloss den PR selbst). **3** `release.yml` prüft `RELEASE_TOKEN` vor den Smokes (curl `/user`,
> Ablauf-Header → Warnung < 14 Tage); `_smoke-ci-v1tag.yml` wöchentlich So 05:00 gegen das echte `@v1`. **4** `gate_matrix.py`
> deckt die Deploy-Kette (verify-staging/promote-prod/verify-prod, 98304 Fälle) + Struktur von `require-staging-green`; verify-prod
> verlangt push-Event + `enable-push`. **5** rechnungsapp-Shards = MUSTER (`tests/test_[a-i]*.py` / `[j-z]` / `integration/ routes/` /
> `services/ pdf/`, 4 Shards ≈ 90 s statt 3 × 61–112 s) + Wächter expandiert Globs, lehnt Tokens ohne Treffer, Doppelabdeckung und
> doppelte Shard-Namen ab (Codex-Fund). **6** CodeQL nur `schedule`/main/tags (Passthrough `run-codeql`).
> Werkzeug-Fallen dieser Runde: der Bash-Tool-Wrapper verschluckt Backslashes (jq `\(` → Parse-Fehler, Heredoc-`
` bricht Python-
> Anchors) → Python-Edits ohne Backslashes bzw. Write/Edit-Tool; `FETCH_HEAD` ist per Worktree; eine Pipe (`| tail`) verschluckt den
> Exit-Code des Cherry-Picks — nie als Erfolgsbeleg lesen. `gh run list --commit` braucht die VOLLE SHA.
> **Fleet-Beweise GEMESSEN 04.09.:** recyclage Run 33845442375 grün, Verify-Staging-Log: Versuch 1–2 `running '8a96e6d' != expected
> 'f70ca87'`, Versuch 3 `version f70ca87 matches expected f70ca87` (Watchtower-Flip innerhalb ~60 s). footballapp Dispatch
> 33845042565 grün, ml-Shard-Log listet 8 expandierte `tests/test_features_*.py`. rechnungsapp: erster 4-Shard-Run 33846425564 wurde
> vom Folge-Push der Parallel-Session gecancelt (alle 4 Shards liefen an, `services` fertig mit 674 passed); Parallel-Session hatte
> den Rebase-Konflikt zu Gunsten der alten Listen aufgelöst (885950c) → Layout als 8c944c1 erneut angelegt, Session benachrichtigt.
> Run 33846824179 (8c944c1): alle 4 Muster-Shards grün — backend-a-i 90 s / 613 passed, backend-j-z 88 s / 497, services 60 s / 674,
> integration 75 s / 265 = 2049 (vorher 3 Shards max 112 s, 2034; +15 = 14 neue Testfunktionen der Fremd-Commits GEMESSEN + 1 ANNAHME),
> 0 Existenz-Fehler (der eine `::error::test path`-Treffer je Job ist das Skript-Echo). Run insgesamt rot durch `services/health.py:180
> F401` der Parallel-Session (nicht Teil der Shard-Änderung; deren eigener Run 885950c hat denselben Lint-Fehler).
> Folge-Run 33847040606 (978910e, Lint-Fix der Parallel-Session) komplett grün: Shards 62/76/92/87 s, Verify Staging success.
>
> **🤖 2026-09-03 „PERFEKT + AUTONOM"-WELLE (Stufen A–F, Pair Claude+Codex, Reihenfolge B→C→D→E→F→A):**
> **✅ RELEASED 2026-09-04 AUTONOM (Run 33762903054 Attempt 2 nach Secret `RELEASE_TOKEN`, ls-remote-verifiziert): `@v1` = `v1.11.0` = `61b1928`.**
> Kandidaten-Branch vom Workflow geloescht. Erster Fleet-Run auf v1.11.0 = rechnungsapp (Caller auf `full-ci-paths` umgestellt).
> Offen: cosign-Cache-Pfad auf 104 wird erst beim naechsten NICHT-light Push (risky oder main) real durchlaufen.
> **Ablauf kuenftig: `scripts/release-v1.sh <sha> vX.Y.Z --yes` — Agent darf; Tag-Push laeuft ueber RELEASE_TOKEN (Admin-PAT).**
> **STAND 03.09. ABENDS (historisch): Kandidat `release-v1.11.0` (Branch 00d14b1 = dev 61b1928 + Rewrite) — Release-Run 33762903054: prep + ALLE
> Smokes GRÜN auf Kandidaten-Refs (Orchestrator volle CI inkl. Security-Lane mit SARIF-Steps, Docker-Push ubuntu, Promotion/crane);
> Tag-Job ROT mit `GH013: Repository rule violations found for refs/tags/v1` (atomarer Push ⇒ auch v1.11.0 NICHT angelegt, @v1 =
> 98d49c7 = v1.10.7 unverändert). Branch bleibt stehen. NÄCHSTER SCHRITT (Azad): fine-grained PAT (nur dieses Repo, Contents
> read+write) als Secret `RELEASE_TOKEN` (`gh secret set RELEASE_TOKEN -R ADZA-Group/shared-workflows`), dann
> `gh run rerun 33762903054 --failed` ⇒ @v1 = v1.11.0. DANACH (Agent): rechnungsapp-Caller `templates/static/translations` von
> `risky-paths` nach `full-ci-paths`; Dispatch-Run rechnungsapp als Beweis fuer cosign-Cache auf 104; Vault/Memory nachziehen.**
> **A Release-Workflow:** `scripts/release-v1.sh <sha> vX.Y.Z [--yes|--dry-run|--no-wait]` baut im Wegwerf-Worktree den
> KANDIDATEN-Branch `release-vX.Y.Z` = sha + 1 Commit (alle internen Refs `@v1` → `@release-vX.Y.Z` — auf den BRANCH, nicht
> den SHA, sonst floaten verschachtelte Refs ab Ebene 2 wieder auf @v1 [Codex]; `.release-source` sha+version) und pusht ihn.
> `release.yml` (on push release-*, concurrency v1-release): prep (HEAD^==sha, Branch==release-<version>, kein `@v1` vor
> Whitespace/EOL, ≥1 Ref auf @branch, origin/branch==GITHUB_SHA, Tag frei, alter v1 Vorfahr) → 4 Smokes per `workflow_call`
> (`_smoke-ci`, `_smoke-docker-build` push=true ubuntu+self-hosted, `_smoke-promotion`; Ebenen-Limit 4 eingehalten) →
> release (Race-Recheck, Branch-HEAD unverändert, `git push --atomic refs/tags/vX.Y.Z +refs/tags/v1` — Force nur auf v1) →
> cleanup (Branch weg nur bei success). Getaggt wird der ORIGINAL-SHA. **Token-Realität GEMESSEN:** Ruleset-Bypass für die
> Actions-Integration ⇒ 422, Deploy-Keys org-seitig deaktiviert ⇒ ohne Repo-Secret `RELEASE_TOKEN` (fine-grained PAT eines
> Admins, contents:write → Checkout-Token → Admin-Bypass) endet der Job am Tag-Push mit klarer Meldung, Tags unberührt, Branch
> bleibt; `gh run rerun --failed` nach Secret-Anlage genügt. Classifier blockte das Abschwächen des Rulesets — Azad-Entscheid.
> **Runner-Realität GEMESSEN:** Org-Runner-Group „Default" `allows_public_repositories=false` ⇒ self-hosted Jobs aus diesem
> PUBLIC Repo hängen endlos (Runs 33754408340, 33757764577) — bewusst so belassen (Fork-PR-Risiko); kein self-hosted-Smoke
> im Release-Gate, cosign-Cache-Pfad wird nach Release per Dispatch-Run einer privaten App gemessen.
> **Release-Smoke = volle CI:** `_smoke-ci` setzt `full-ci-on-dev-push: true`, sonst liefe der Kandidaten-Push light (Security
> skipped, GEMESSEN Run 33757764577).
> **B** crane v0.22.0 (sha256 gepinnt, inline in docker-build/promote/verify/smoke-promotion — Composite wäre Henne-Ei):
> `crane digest`/`crane tag` byte-identisch; Backups + Promote (promote-verify-Tag hart, :latest zuletzt) + Rollbacks
> (MANIFEST_UNKNOWN/NAME_UNKNOWN ≠ Fehler); `imagetools create` NIRGENDS mehr; multi-arch fail-closed ohne
> `allow-multiarch-rebuild`. **C** Semgrep/Trivy/CodeQL: SARIF-Artefakte + Zähler im Summary, Tool-Fehler = „nicht auswertbar"
> (nur outcome==success zählt). **D** `full-ci-paths` (Test/Build-Lanes erzwingen ohne Gate-Härtung; Filter `fullci`, Platzhalter-
> Glob) — rechnungsapp-Caller NACH Release umstellen (templates/static/translations). **E** `tia-verdict` (complete/shards_missing/
> parse_errors) + TIA-Ledger in pipeline-analytics (nur complete zählt, FN-Rate, Ø Einsparung). **F** jarvis `routines/code-watch.md`
> a4d1459: Merge nur bei Lauf für exakt headRefOid, completed+success. Codex-Beiträge: B1/B2 (Promote-Reihenfolge, Rollback-
> Klassifikation), C1 (Semgrep-Zählung), E1 (Verdict-Vollständigkeit), A1–A3 (Branch-Ref, atomarer Push, Regex), A-R2 (issues:write,
> Dry-Run). Dissens: „hermetisch" — Branch-Ref bleibt beweglich (2× HEAD-Check, nicht kryptografisch).
>
> **🧹 2026-09-03 AUDIT-REST-WELLE auf dev (Pair Claude+Codex, 3 Etappen à 1–2 Runden; wartet auf User-Release v1.10.8):**
> **Fund 3 (Kern):** single-arch pusht das GESCANNTE lokale Image (`docker push` nach `:verify-<branch>` → Digest →
> `imagetools create` je Tag, NORMAL zuerst, Deploy-Tag `:staging/:latest/:candidate-*` als LETZTE Operation, jeder Retag
> per inspect gegen den Digest gemessen); Metadata-Step vor Build 1 (Labels im geprüften Image); multi-arch behält buildx-
> Rebuild (Caveat). **B** diff-cov: main-Push vergleicht `github.event.before`, Composite lehnt ungültigen/identischen Ref auf
> blocking ab (kein Fallback), Tags ⇒ diff-cov aus. **5** DAST: Parse-Fehler ⇒ exit 1. **6** Backups ohne CoE, Registry-404
> nur per `manifest unknown|MANIFEST_UNKNOWN|no such manifest|<ref>: not found`. **F** notify per `jq -n --arg` + Telegram
> `--data-urlencode`. **D** cosign self-hosted: `$HOME/.cache/adza/cosign-<ver>` + sha256 bei JEDER Nutzung, mktemp+mv;
> hosted weiter cosign-installer. **1+2** alle Caller-Inputs in Composites/Reusables via `env:` (Listen per `read -ra`).
> **7** sha256-Pins: gitleaks 8.21.2, hadolint 2.12.0, conftest 0.56.0, actionlint 1.7.12, osv 1.9.1, cosign v3.1.3;
> trufflehog install.sh auf v3.97.2; nuclei Digest-gepinnt; IMMER aus Tarball nach `$RUNNER_TEMP` (kein command-v-Shortcut).
> **C** weekly-cleanup: nur `retention-days` (30) + keep-runs-Floor, KEIN Status-Löschen mehr. **G** Ruleset `protect-v1-tag`
> (id 22190724: update/deletion/non_fast_forward auf refs/tags/v1, Bypass Repo-Admin). **H** recyclage-Caller cloud-runner-label.
> **README** = Code (Security-Gates ehrlich). `_smoke-docker-build` hat dispatch-Inputs `push`/`runner-label` für den echten
> Verify→Retag-Pfad in ghcr.io/adza-group/smoke-fixture. NICHT gemacht (bewusst): 8 (Perm-Split), Org allowed_actions,
> sha_pinning_required (verbietet interne @v1-Refs), 104-Cron, MitarbeiterApp-Dependabot. Codex-Beiträge: R1 Push-Reihenfolge,
> Tag-Push-Block, not-found-Regex; R2 Deploy-Tag-zuletzt, command-v-Bypass, nuclei-Pin.
> **🔬 2026-09-03 FLEET-CI-AUDIT (Pair Claude+Codex, 3 Runden) + FIX A+X (dev `dea4e6d`+`98d49c7`):**
> Vollbericht: Vault `45-reports/2026-09-03-ci-audit.md` + Windows-Memory `ci-audit-2026-09-03`. **P1 A:** `property-tests`
> (BLOCKING bei risky) und `license-check` (BLOCKING main/tags) standen NICHT in `docker-build.needs` → Rot färbte nur den
> Run, Image war gepusht + Watchtower hatte es gezogen. **P2 X (Codex):** harte Gates prüften `!= 'failure'` → `cancelled`
> (Teil-Cancel/Runner-Shutdown) ließ den Build unter `always()` durch. **Fix:** needs += beide; harte Gates auf
> `success||skipped`; property-tests/lint-dockerfile nur bei risky hart (`|| risky != 'true'`), license-check nur
> main/tags (`|| !main`) — advisory-Kontexte werden NICHT strenger. **Invariante als Gate:** `scripts/gate_matrix.py`
> liest den ECHTEN docker-build-`if:`+`needs:` (Mini-Übersetzer GH-Expression→Python), Brute-Force je hartes Gate ∈
> {failure,cancelled} × andere ∈ {success,skipped} × 32 changes × 4 Events × 3 Refs + Happy-Path/skipped-Positivkontrollen
> + Subset-Check „jedes harte Gate steht in needs"; läuft als 2. Step in `actionlint.yml` (paths inkl. Skript). GEMESSEN:
> Fix `checked=376832 violations=0`; Original-Datei rot (Subset-Fehler; ohne Subset-Check 14112 cancelled-Verstöße).
> Weitere Audit-P2 (noch NICHT gefixt): Diff-Coverage auf main vakuum (HEAD==origin/main) · weekly-cleanup löscht rote
> Runs → Analytics geschönt · gescanntes≠gepushtes Image · DAST `|| echo 0:0:0` · `:previous`-Backup CoE · curl-Downloads
> ohne Hash · Caller-Inputs direkt in Shell (Defense-in-Depth) · kein Tag-Ruleset für v1. **Gemessen sauber:** „1/4 Runner
> online" = `runner-controller.service`-Autoscaling auf 104 (12 GB RAM / 6 Kerne heute, nicht mehr 4 GB); buildx-gha-Cache
> auf 104 billig (Import 1 s / Export 3 s). **Vorfall:** Fehlalarm „MitarbeiterApp gh pr merge --auto" aus 7 Wochen altem
> Checkout — Caller-Audit NUR gegen Remote-Blob (`git hash-object` vs `gh api contents?ref=dev --jq .sha`).
> **ANNAHME (unbewiesen, 1305 Jobs in 110 grünen Runs = 0 failure):** job-level `continue-on-error` ⇒ `needs.X.result == 'success'`.
>
> **🧠 2026-08-13 MAX-WELLE auf dev (Pair-Codex, wartet auf Release — ⚠️ RELEASE-PREP nötig, s.u.):**
> Commits `76fe929..<tip>`: (1) **property-tests-Smoke-Rot GEFIXT** (Caller ohne requirements.txt → venv ohne
> pytest → rc=127; Fix `install-coverage:"true"` = pytest via pytest-cov + pytest-timeout; bewiesen Run
> 31710648055 rc=5-Pfad grün). (2) **Risk-Gating:** `changes` mit composed+validierten Filtern (Input
> `risky-paths` JSON-Array, UNION mit Defaults) + norm-Step (Filterfehler ⇒ alles+risky=true = fail-closed
> Richtung Härte, kein Kaskaden-Skip); risky ⇒ light aus + property/hadolint/bandit BLOCKING; hadolint neu in
> docker-build.needs+if; bandit via neuem `force-blocking`-Input in reusable-security-scan. (3) **Notify-
> Transitions:** Orchestrator berechnet Status aus 19 needs (license-check ist dual-gated = main-blocking —
> war die Lücke), notify meldet nur grün→rot (Alarm) / rot→grün (Recovery), Dauer-Zustände still,
> [PROD]-Präfix main/tags, API-Fehler fail-open; braucht `actions:read` (alle 4 App-Caller haben es, README-
> Beispiel ergänzt). Live bewiesen: `prev=success cur=success → send=false`. (4) **TIA observe-only:**
> naming-Heuristik berechnet would-have-selected (deselektiert NIE), Flake-Plugin trägt failed-nodeids,
> test-results-Verdict „hätte Auswahl alle roten enthalten?" — False-Negative-Ledger VOR jeder Aktivierung
> (Codex kippte Coverage-Map-TIA als zu schwer für die Fleet-Größe). (5) README-Caveats entdriftet.
> **✅ RELEASED 2026-08-14 (zweistufig, ls-remote-verifiziert): `@v1` = `v1.10.5` = `30ca00d`.**
> v1.10.4 = `f1b621e` (Flip + Welle ohne bandit-force-blocking), v1.10.5 = `30ca00d` (force-blocking
> aktiv) — die komplette Doppelwelle (Flake-Radar 07-30 + Max-Welle 08-13) ist fleet-live.
> Wellen-Smokes: 31710648055 (risky hart) · 31711921815 (light+notify+TIA) · 31712308434 (risky via
> Fixture-Löschung) · 31794672604 (Stufe A) · 31802107153 (Stufe B). **Release-Lehre:** die drei
> „gescheiterten" User-Releases starben ALLE an Gate 1 (dirty tree durch Agent-Hinterlassenschaften:
> __pycache__ aus lokalen Plugin-Tests, dann die eigene release-out.txt-Log-Umleitung IM Repo) bzw. an
> Bash-Syntax in PowerShell. Merke: User-Befehle als PowerShell-Zeile mit explizitem Git-Bash-Pfad,
> Logs NIE ins Repo, vor Release-Übergabe `git status --porcelain` prüfen. Agent-Moves von @v1 blockt
> der Classifier (verifiziert 2026-08-14) — Releases bleiben User-only, Gates im Skript sind die Sicherung. **Runner-Redundanz: am 2026-08-14 auf
> User-Entscheid RÜCKGEBAUT** (s2-runner deregistriert, LXC 114 destroyed, Watchdog entfernt — LXC 104
> ist wieder der einzige Runner-Host/SPOF). Setup-Wissen fürs Wiederherstellen: Windows-Memory
> `ci-max-welle-2026-08-13` (vzdump-Klon-Gotchas bleiben gültig).
>
> **📜 v1.10.2 VORBEREITET auf dev — dependency-review-Lügen-Rot (2026-07-21, wartet auf User-Release):**
> Der Job `dependency-review` in `reusable-security-scan.yml` war auf JEDEM PR privater Repos rot
> ("Dependency review is not supported on this repository" — braucht Dependency Graph = GHAS, das kein
> Fleet-Repo hat; `continue-on-error` machte nur den RUN grün, der CHECK blieb rot = Lügen-Rot, das
> rote Checks entwertet). Betroffen: recyclage-app (bewiesen, Runs 29738530616 + 29828760017) +
> footballapp (strukturell: PR-Trigger + @v1 ohne Opt-out). NICHT betroffen: rechnungsapp (kein
> PR-Trigger), adza-website/jarvis (kein reusable-ci), paperless/cloudflare (config-ci ohne dep-review).
> Fix: Job-`if` um `!github.event.repository.private` ergänzt → skipped statt rot; Abdeckung bleibt via
> Dependabot + cve-notify. ⚠️ recyclage-app pinnt reusable-ci@v1.8.9 (kennt den run-dependency-review-Input
> NICHT — Caller-Opt-out unmöglich), wird aber trotzdem geheilt, weil interne Refs auf @v1 floaten →
> der Fix greift dort mit dem @v1-Move. Falls je GHAS gekauft wird: private-Klausel wieder entfernen.
> Release: `scripts/release-v1.sh <dev-sha> v1.10.2` (User; Classifier blockt v1-Move durch Agent).
>
> **🚦 v1.10.1 — Nightly-Gate-Fix (2026-07-21, @v1 moved, User-Freigabe via release-v1.sh):**
> `require-staging-green` lief auch bei `schedule`/`workflow_dispatch`, obwohl `verify-staging` nur bei
> `push` läuft → `skipped != success` riss JEDE Nightly auf main mit staging-url rot (erster Treffer:
> footballapp Run 29809152965, 21.07. 07:05 — einziger roter Job war das Gate, Staging/Prod gesund).
> Fix: Gate-`if` um `github.event_name == 'push'` ergänzt; bei push unverändert hart. Beweis:
> footballapp main-dispatch 29818810697 grün, Gate+verify beide skipped. Mit-released (waren auf dev):
> Dependabot-Actions-Bump (PR #11) + `run-dependency-review`-Passthrough (91af07d).
>
> Alter Stand (2026-07-15): **Released: floating `@v1` = `v1.9.4` (commit `6428c11`, ls-remote-verifiziert).**
>
> **🥗 v1.9.4 — CI-Diät Teil 2 (Parallel-Session):** `code-quality` (2m43), `dead-code` (2m50), `license-check` (~4m) und `todo-tracker` skippen jetzt ebenfalls bei `light` — sie sind auf dev ohnehin `continue-on-error`, kosteten aber ~10 min Runner-104-Zeit pro Push, auf die niemand wartet. PR/main/dispatch/**schedule** fahren sie weiter voll (die Apps haben seit 15.07. nächtliche schedule-Läufe: rechnungsapp 03:10 dev, footballapp 04:30 main — der Ausgleich für die Diät). Smoke-validiert mit ECHTEM push-Event auf `release-v1.9.4` (Run `29428352616`: die 4 skipped, Test+Lint success).
> **⚠️ ZWEI FALLEN dabei (beide fast passiert):** (1) Ein pauschaler `if:`-Ersetzer traf **6 statt 4 Jobs**, inkl. `test-matrix` — Tests auf dev-Pushes zu skippen wäre fatal. Immer per Job-Anker ersetzen + danach `test-matrix`/`lint-python`/`coverage` gegenprüfen. (2) **`!needs.changes.outputs.light` ist FALSCH:** Job-Outputs sind STRINGS, `!'false'` ist in GH-Expressions `false` → die Jobs wären ÜBERALL aus gewesen, auch nachts und auf main. Schreibweise ist `light != 'true'` (wie security/property-tests).
>
> **🔧 v1.9.3 — zwei stille Defekte:** (1) **Flaky-Rerun war fleet-weit TOT:** `run-pytest-shard` installierte `pytest-rerun-failures` — das Paket gibt es auf PyPI NICHT (404; echt: `pytest-rerunfailures`). Install schlug still fehl (`|| echo ::warning`), der Import-Check griff nicht, `RERUN` blieb leer → der seit v1.5.0 als „released" dokumentierte `test-reruns`-Input war fuer JEDE App wirkungslos (stand als „OFFENER FLEET-FIX" schon in rechnungsapp-CLAUDE.md). dev hatte den Fix laengst — nie auf die v1-Linie gepickt. Beweis nach Fix: pytest-Zeile `plugins: timeout-2.4.0, rerunfailures-16.4, cov-7.1.0`. (2) **`python-version` war Deko:** `setup-python-deps` ignorierte den Input und nahm System-python3 (3.13), waehrend die Prod-Images auf `python:3.14.6-slim` bauen — eine 3.14-Inkompatibilitaet waere gruen durch die CI gegangen. Jetzt: `python<version>` vom PATH bevorzugt, sonst LAUTE Warnung statt stiller Abweichung; `reusable-ci` reicht den Input an den Test-Job durch (der einzige, der App-Verhalten validiert). Ohne passenden Interpreter = Verhalten wie bisher → keine Regression fuer andere Apps.
> **🐍 python3.14 auf Runner 104:** `/opt/python/cpython-3.14.6-linux-x86_64-gnu` + Symlink `/usr/local/bin/python3.14` (`UV_PYTHON_INSTALL_DIR=/opt/python uv python install 3.14`). **Gotcha 1:** der Runner-DIENST hat PATH `/usr/local/bin:/usr/bin:/bin` — `~/.local/bin` ist NICHT drin (systemd sourcet kein `.profile`) → uv's eigener Symlink dort ist fuer Jobs unsichtbar; der Interpreter MUSS unter `/usr/local/bin` haengen. **Gotcha 2:** `uv python install` legt `cpython-3.14-…` als SYMLINK auf `cpython-3.14.6-…` an — `cp -a` kopiert den Symlink, nicht den Baum (nach Loeschen der Quelle dangling). **Gleichwertigkeit belegt:** volle rechnungsapp-Suite auf 3.14.6 vs 3.13.5 = je 1613 passed, identischer Einzel-Fail (bekannte SQLite-Test-Isolation), 3.14 sogar 4s schneller; alle 53 Deps haben cp314-Wheels (0 Source-Builds).
> **📏 MESS-LEHRE (zweimal in einer Session gelernt):** Erst „208s Setup" → Hypothese „Install ist langsam" → Idle-Bench sagte 18s → echter Taeter war der Cache-Restore. Dann „Test faellt auf 3.14" → Kontrolle auf 3.13 mit IDENTISCHEN Bedingungen (VOLLE Suite, nicht Einzeltest!) → faellt dort genauso → kein 3.14-Problem. **Ein Vergleich mit zwei geaenderten Variablen ist kein Beweis.** Und: ein Skript, das „gruen" meldet, ohne eine positive Test-Zahl geprueft zu haben, luegt (mein Shard-Harness tat es zweimal: „no tests ran" und „1 xfailed" wurden als Erfolg gelesen).
>
> **⚡ 2026-07-15 v1.9.2 — DER pip-Cache-Befund (groesster CI-Hebel dieser Woche):** `setup-python-deps` machte `actions/cache/restore` von `~/.cache/pip` **auch auf self-hosted**. Dort ist das eine PERSISTENTE lokale Platte — der Restore lud pro Job **905 MB mit 5.3 MB/s = 173 s Download + 5 s untar**, um Dateien "wiederherzustellen", die längst lokal lagen. **178 s von 208 s Setup-Zeit für nichts**, ~8 GB Traffic pro CI-Lauf (9 Python-Jobs), Leitung dauersaturiert (erklärt auch ghcr.io-Latenz 3 s + „Flakes" unter Last). Beweis: Job `87319271043` Zeitstempel `09:44:41 -> 09:47:39`; pip-Install der 235 Pakete danach = **25 s** (Bench auf idle Runner: **18 s**). Fix = EINE Zeile: `if: runner.environment == 'github-hosted'`. Der Post-Run-SAVE war aus derselben Ursache laengst deaktiviert (Upload-Haenger) — nur den Restore hatte nie jemand hinterfragt.
> **🔑 LEHRE (fleet-weit gueltig):** `actions/cache` ist fuer EPHEMERE Runner gebaut. Auf self-hosted ist jeder Cache-Restore eines ohnehin persistenten Pfades reine Netzlast. **Vor jedem `actions/cache` auf self-hosted fragen: ist der Pfad hier nicht sowieso schon da?** Gleiches gilt fuer npm/node_modules/buildx-Caches, falls die je auf die self-hosted-Lane wandern.
> **📏 MESS-LEHRE:** „Setup dauert 208 s" hiess NICHT „Installation ist langsam". Der Bench auf idle Runner (18 s) hat die Hypothese gekillt, die Log-Zeitstempel haben den echten Verursacher gezeigt. Erst messen, dann fixen — `uv` waere hier die falsche (teure) Loesung fuer ein Netzproblem gewesen.
>
> **🥗 2026-07-15 v1.9.0 CI-DIÄT:** dev-/Feature-PUSHES laufen light — `changes`-Job berechnet Output `light` (push && !main && !`full-ci-on-dev-push`), `security` + `property-tests` skippen bei light. PR, main-Push, dispatch, schedule voll. Auf der v1-Linie gated docker-build NICHT auf security (needs: changes/lint/test) → kein Kaskadenrisiko. Opt-out pro App: `full-ci-on-dev-push: true`. Smoke-validiert (Run `29403582369`). Davor **v1.8.10**: `reusable-e2e.yml` auf die v1-Linie (dev-Smoke-Drift-Fix, verhaltensneutral). **v1.9.1** = ZAP-DAST-Fix (Parallel-Session).
> **⚠️ v1-TAG = GETEILTE RESSOURCE:** Am 15.07. haben zwei Sessions parallel released → `v1.9.1` war bereits vergeben, und ein Force-Move aus einem stale lokalen Ref haette den ZAP-Fix geloescht. **Vor JEDEM Move: `git fetch --tags --force` + `git ls-remote origin 'refs/tags/v1^{}'` + `git log <remote-v1> --not <mein-branch>` (muss leer sein) + ls-remote-Recheck unmittelbar vor dem Push.**
> Alter Stand: **Released: floating `@v1` = `v1.9.0` (commit `c783c8e`, ls-remote-verifiziert).**
>
> **🥗 2026-07-15 v1.9.0 CI-DIÄT (`@v1` moved, User-Freigabe):** dev-/Feature-PUSHES laufen light — `changes`-Job berechnet Output `light` (push && !main && !`full-ci-on-dev-push`), `security` + `property-tests` skippen bei light. PR, main-Push, dispatch, schedule voll. Auf der v1-Linie gated docker-build NICHT auf security (needs: changes/lint/test) → kein Kaskadenrisiko. Opt-out pro App: `full-ci-on-dev-push: true`. Smoke-validiert auf ubuntu (Run `29403582369`: security/property skipped + Build grün). Davor **v1.8.10**: `reusable-e2e.yml` auf die v1-Linie (dev-Smoke-Drift-Fix, verhaltensneutral). Release-Branch `release-v1.9.0` enthält zusätzlich Smoke-Fixes der v1-Linie (actions:read, cloud-runner-label ubuntu, api-Fixture F401).
> **⚠️ BEFUND dev-Drift (2026-07-15):** dev-`reusable-ci` ist gegen `@v1` NICHT lauffähig — referenziert `reusable-e2e.yml@v1` (seit v1.8.10 gefixt) UND übergibt `gated-promotion` an `reusable-docker-build.yml@v1`, das den Input nicht kennt (nie released, T7/b2 im Handoff unten weiter offen). Jeder dev-Smoke = startup_failure bis die Sub-Reusable-Releases nachgezogen sind. Die CI-Diät wurde deshalb DIREKT auf der v1-Linie implementiert (Commit `c783c8e`); dev trägt dieselbe Diät separat (Commit `80264b0`, inkl. fail-closed docker-build-Anpassung für die dev-Gate-Struktur).
>
> Alter Stand (2026-07-02):
> Stand **2026-07-02**, branch `dev`. **Released: floating `@v1` = `v1.8.9` (commit `50508f4`, ls-remote-verifiziert).** Lies das hier zuerst.
>
> **🏁 2026-07-02 v1.8.9 (`@v1` moved, User-Freigabe):** `test-results`-Job nutzt die **composite-Variante** von publish-unit-test-result-action (`…/composite@<sha>`, kein Docker-Image-Pull). Root-Cause: die Container-Action zog ihr Image vom geteilten Runner-Daemon, der während des PARALLELEN Build-Jobs mit dem repo-scoped GITHUB_TOKEN bei ghcr.io eingeloggt ist → Pulls FREMDER public Namespaces antworten „denied" (Incident rechnungsapp Run 28578768052; Zeitfenster-Beweis + anonymer Pull ok; frühere „Fixes" v1.8.3/d989ede hatten nur das Symptom stummgeschaltet). Empirisch grün BEI parallelem Build. Merke: v1-Linie = cherry-picks von dev (Historien divergieren); Release-Muster = Branch von v1 → cherry-pick → `v1.8.x`-Tag → `git tag -f -a v1` + `push -f` nach Verlust-Check `git log v1 --not dev`. CodeQL-js kann Runner 104 (4 GB) OOM-reissen → „runner has received a shutdown signal" + Kollateral-Fails → `gh run rerun <id> --failed` genügt.
>
> **🚀 CI-POWER-UP läuft** (Senior-Level „alles abdecken", Umbrella-Spec `docs/superpowers/specs/2026-06-03-senior-ci-powerup-design.md`, 6 Phasen, Reihenfolge A✅→B→F→C→E→D):
> **Phase A ✅ released (v1.5.0):** diff-coverage-gate (changed-line, default 80%, dual-gate, in `coverage-gate`-Composite + reusable-ci coverage-job `fetch-depth:0`) + `pytest-rerun-failures` flaky-auto-rerun (`test-reruns`-Input in `run-pytest-shard`). Composites live; empirische coverage-job-Validierung läuft beim nächsten App-Push mit Python-Code-Änderung. Plan: `docs/superpowers/plans/2026-06-03-ci-powerup-phaseA-test-depth.md`.
> **Phase B ✅ released (v1.5.1):** cosign keyless + SLSA attest fleet-weit AN — `sign-image`-Default in `reusable-docker-build.yml` von `false`→`true` (Konsistenz mit `reusable-ci.yml`, das es seit 2026-05-28 schon hatte) + FootballApp-Caller `sign-image: false` Override entfernt → alle 4 Apps signieren by default. Steps bleiben `continue-on-error: true` (Sigstore-Outage/Org-Limit advisory). README hat neue Sektion "Image signing & verification" mit `cosign verify` + `gh attestation verify` Snippets + opt-in `require-signed-images`-Gate. Empirische Validierung (Plan-Task 6, pending): FootballApp dev-Run nach v1.5.1-Release erwartet `Cosign sign (keyless)` + `SLSA build provenance` Steps grün; wenn Sigstore-Outage oder Org-Limit → advisory rot, kein Blocker. Plan: `docs/superpowers/plans/2026-06-03-ci-powerup-phaseB-cosign-fleet-wide.md`.
> **Phase F ✅ released (v1.5.3):** `reusable-config-ci.yml` (yamllint + `docker compose config` + gitleaks + OPA/conftest, dual-gate, runner-label-driven) für die compose-only Infra-Repos `paperless` + `cloudflare`; je ~20-Zeilen `ci.yml`-Thin-Caller. **Empirisch validiert:** cloudflare dev+**main** GRÜN (Run `26935409227`), paperless dev GRÜN. **Lektion (dev≠main):** yamllint-Step nutzte `pip --user` → PEP-668 `externally-managed` → auf dev advisory (still grün), auf main BLOCKING → cloudflare-main-Run `26935300119` rot. Fix `874a42b`: yamllint in throwaway-venv (ubuntu+self-hosted), fallback `--user`→`--break-system-packages`. **v1.5.2 war transienter Mistag (vor PEP-668-Fix); echter Release = `v1.5.3` = `@v1`.** Smoke `_smoke-config-ci.yml` grün auf ubuntu. Plan: `docs/superpowers/plans/2026-06-03-ci-powerup-phaseF-config-ci.md`.
> **Phase C ✅ released (v1.5.4):** pa11y-ci a11y-Gate in `reusable-frontend.yml` (`a11y-*`-Inputs: scan URL ODER lokal-served Build-Output, headless-Chrome `--no-sandbox`, dual-gate) + `lighthouse-config`-Input für `lighthouserc.json`-Budget (Template in `tests/fixtures/frontend/`). Smoke `_smoke-frontend.yml` grün auf ubuntu (a11y-Step `success` gegen served Fixture-Build). Für Jinja/HTMX-Apps: `a11y-url` auf Staging zeigen; SPAs: leer lassen → lokaler Build-Scan. Plan: `docs/superpowers/plans/2026-06-04-ci-powerup-phaseC-frontend-a11y.md`.
> **Phase E ✅ released (v1.5.5):** (1) **PR-concurrency-Fix** in allen Callern — `group` von `…-${{ github.sha }}` auf `…-${{ github.ref }}` (sha gedroppt, sonst war jede SHA eigene Group → cancel feuerte NIE) + `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` (superseded PR-Runs canceln, push/main-Deploys nie unterbrechen). Config-Caller (paperless/cloudflare) + 3 stabile App-Caller (rechnungsapp/recyclage-app/MitarbeiterApp) angewendet; FootballApp übersprungen (NO-SHIP v3 auf dev — nachziehen bei nächstem dev→main). (2) **Opt-in `prod-environment`/`staging-environment`-Inputs** auf verify-prod/verify-staging (default '' = kein Gate; empty-env via `_smoke-env` bewiesen ungefährlich → kein startup_failure). Gibt freies Deployment-Tracking. **⚠️ Befund: required-reviewer-Approval ist auf PRIVATEN Repos PAID** (`gh api`→`422 billing plan`), `production`-Env anlegbar aber Reviewer-Regel braucht Team/Pro. Watchtower-pull-Deploy hat eh keinen gate-baren Job → echtes pre-deploy-Approval würde `:latest`-Push gaten (separates Design, nicht gebaut). Plan: `docs/superpowers/plans/2026-06-04-ci-powerup-phaseE-deploy-env-concurrency.md`.
> **Phase D ✅ released (v1.5.6):** `reusable-api-contract.yml` (schemathesis property-based fuzzing; `start-app` composite + dual-gate). Opt-in `openapi-spec`-Input in `reusable-ci.yml` → `api-contract`-Job, **skip wenn leer** (alle aktuellen Apps → skipped, kein OpenAPI-Spec). Smoke `_smoke-api-contract.yml` grün auf ubuntu gegen Flask-Fixture mit `/openapi.json` (schemathesis-Step `success`). **⚠️ App-Code-Folgearbeit (NICHT CI):** Apps müssen erst ein OpenAPI-Spec emittieren (flask-smorest/apispec) bevor api-contract greift. Plan: `docs/superpowers/plans/2026-06-04-ci-powerup-phaseD-api-contract.md`.
> **🏁 CI-POWER-UP KOMPLETT (A–F alle released):** A=v1.5.0 (diff-cov+flaky) · B=v1.5.1 (cosign fleet) · C=v1.5.4 (a11y) · D=v1.5.6 (api-contract) · E=v1.5.5 (env+concurrency) · F=v1.5.3 (config-CI). `@v1`=v1.5.6.
>
> **✅ 2026-06-09 VERIFIZIERT (Audit + git) + AUDIT-HÄRTUNG auf `dev`:** `git tag` zeigt v1.5.0–v1.5.7,
> `v1`→v1.5.7 → A–F sind real released; api-contract (Phase D) ist gebaut+verdrahtet (skippt nur mangels
> App-OpenAPI-Spec). **Neu auf `dev` (Spec/Plan `2026-06-09-ci-deploy-gate-c2-e2e`), empirisch ubuntu-validiert:**
> B1 (`pytest-rerunfailures`-Fix), C1-It.1 (security+coverage+e2e in `docker-build.needs`, coverage dual,
> fail-closed), C2 (opt-in version-assert), **Phase G** (`reusable-e2e.yml`, opt-in). Audit-Befunde M1
> (SHA-Pin Floating-Actions) + N1 (toter `setup-python-env`) wurden parallel in `baaddff` erledigt; zusätzlich
> `_smoke-ci` `actions:read` + 2 api-Fixture-Lint-Fixes. (a) **v1.6.0 RELEASED** (`@v1`=`f9e6c56`, ls-remote-verifiziert).
> **🏁 2026-06-09 C1-It.2 GEBAUT auf `dev`** (Spec/Plan `2026-06-09-ci-candidate-promotion-branch-policy*`,
> Review approve, Smokes grün: `_smoke-promotion` policy-3-Fälle + GHCR-Digest-Retag, `_smoke-ci`-Regression
> branch-policy/promote korrekt skipped): **`branch-policy`** default AN (main nur via dev — ff oder
> --no-ff/PR-Merge mit dev als ^2; Verstoß ⇒ docker-build geblockt, fail-closed) + **`gated-promotion`**
> opt-in (`:candidate-<sha>` → `promote-prod` nach require-staging-green → digest-stabiles Retag `:latest`;
> verify-prod skippt bei nicht-promotetem gated-Run gegen False-Rollback; REQUIRES staging-url).
> **Branch-Protection-API-Befund 2026-06-09:** Org-Repos (footballapp/recyclage-app/rechnungsapp) → HTTP 403
> paid; MitarbeiterApp (User-Repo) → Force-Push+Deletion-Block AKTIVIERT. **OFFEN (Resume):** (b2) **T7-Release
> v1.7.0**: docker-build-Ref in `reusable-ci.yml` von `@dev`→`@v1` zurückflippen VOR dem Tag (TEMP-Kommentar
> markiert die Stelle), dann v1.7.0 + `@v1`-move nach Verlust-Check; (b3) **FootballApp-Pilot**
> `gated-promotion: true` = echter main-E2E-Beweis (danach Fleet); (b4) **Candidate-Tag-Cleanup** in prune-ghcr
> (Review-Befund: `:candidate-*` akkumuliert, prune löscht nur untagged) — VOR Pilot-Aktivierung; (c) C2/e2e
> App-Aktivierung pro Repo (`/health`-SHA bzw. Playwright-Specs); (R1) Alt-Automationen prüfen, die nicht via
> dev auf main pushen (z.B. RecyclageApp `release-please.yml`) — würden vom branch-policy-Gate geblockt.
>
> **🏁 2026-06-11 WELLE 1 (Fleet-Endausbau, Umbrella `2026-06-10-ci-fleet-endausbau-design.md`): `@v1`=`v1.8.0` (`9475e3c`, ls-remote-verifiziert).**
> Node-24-Pins (alle 20 Familien; Majors: checkout v6, cache v5, artifact v7/v8 PAARWEISE, buildx v4, dep-review v5,
> attest v4, CodeQL-Bundle; 8 Familien waren aktuell) + `GIT_SHA`-Default-Build-Arg (C2-Voraussetzung; Apps: `ARG GIT_SHA`
> →`ENV APP_SHA`→`/health` sha) + `enable-candidate-prune` (referenced-safe: löscht NUR Versionen mit ausschließlich
> candidate-*/main-<sha>-Tags >14d; Review approve; Probelauf gegen echtes recyclage-Paket = leer ✓) + pip retries 5/
> timeout 90. Alle 4 Smokes grün (composites/ci/docker-build/promotion). **Gotcha (Henne-Ei):** Node-20-Warnungs-Check
> ist erst NACH dem @v1-Move beweisbar — Smokes ziehen Composites @v1, der gebumpte Pin liegt bis zum Release nur auf dev.
> **NÄCHSTE WELLEN:** 2 = C2 `/health`-SHA je App (Recyclage→Football→Rechnungsapp(dev)→Mitarbeiter(inert)) + a11y 12→0
> + e2e RecyclageApp · 3 = OpenAPI+Playwright-Smoke je App · 4 = Watchtower-Flotte (DT4). Grenzen: kein FootballApp-Staging
> (B abgewählt), Rechnungsapp-gated nach Debt-Merge.
>
> **▶️ RESUME-PUNKT (2026-06-03) — Self-Hosted-CI-Umbau IMPLEMENTIERT (v1.4.1+v1.4.2):** GitHub-Actions-Gratis-Minuten waren
> erschöpft (`ADZA-Group` 2126/2000, $0 Spend) → hosted-Runner org-weit geblockt. **Fix = Fleet-CI voll self-hosted-fähig gemacht:**
> 1. `decide-runner`-Fallback invertiert (kein-PAT / Billing-unlesbar / Minuten-niedrig → **self-hosted** statt hosted) in allen 4 App-Callern + dev→main.
> 2. **ALLE hardkodierten hosted-Stellen in `reusable-ci`/`reusable-security-scan` entfernt** (v1.4.1: codeql + dependency-review `runs-on`→runner-label;
>    v1.4.2: `frontend` + `dast` `runner-label`-Input war `'["ubuntu-latest"]'` hardkodiert → forwardet jetzt `${{ inputs.runner-label }}`). `grep ubuntu-latest reusable-ci.yml` = 0.
> 3. RecyclageApp `multi-arch:false` (amd64-only, kein QEMU-OOM auf 4 GB self-hosted).
> **Empirisch bewiesen:** `decide-runner`→self + `Detect Changes` success auf self-hosted, **0 Billing-Blocks** für runner-label-Jobs.
> **OFFEN (Queue/Versions-Realität):** 3× LXC-104-Runner (runner-4 AUS = 4 GB-OOM-Linie) verarbeiten den Validierungs-Backlog LANGSAM.
> Die main-Runs der 2 Frontend-Apps (RecyclageApp/MitarbeiterApp), die auf **v1.4.1** starteten, tragen noch den frontend-Billing-Block →
> brauchen einen **frischen Run auf @v1=v1.4.2** (proven-by-construction grün; Rechnungsapp/FootballApp ohne Frontend sind schon entsperrt).
> **Nächster Schritt:** Queue abwarten/abräumen → fresh v1.4.2-Runs der Frontend-Apps grün verifizieren. **Alternativ (sofort):** Spending-Limit > $0 → hosted frei.
> **Deploy-Tail (v1.4.0) noch offen:** DT4 (watchtower `--cleanup` Composes + RecyclageApp `containrrr→nickfedor`, SSH-LXC) + DT5 (rollback-Test). Plan: `docs/.../plans/2026-06-01-deploy-tail-rollback-cleanup.md`.
> Self-Hosted-Spec/Plan: `docs/.../specs|plans/2026-06-03-self-hosted-ci-runner-selection*.md`.
> Globale Arbeitsregeln: `~/.claude/CLAUDE.md`. Detail-Memory: `~/.claude/projects/.../memory/project_unified_ci.md`.
>
> **TL;DR Endstand:** Die CI-Bibliothek ist FERTIG, hermetisch, released. Apps pinnen `@v1`.
> Interne Refs der Reusables zeigen auf floating `@v1` (NICHT @dev/exact) → kein Drift, kein Re-Pin-Churn.
> Lint-Gates (ruff/dockerfile/eslint/tsc) advisory auf PR/dev, hart auf main/tags; **Tests immer hart**.
>
> **🔴 ROOT-CAUSE-INCIDENT 2026-06-01 (`@v1`-Mispoint):** `@v1` zeigte real auf die **stale v1.3.1-Linie**
> (`894dabb`→`8d08c4e`, NICHT auf der `dev`-Historie), während die Doku „v1.3.6" behauptete. Folge: ALLE
> `@v1`-Apps liefen wochenlang auf **v1.3.1** — die v1.3.2–v1.3.6-Verbesserungen (Semgrep/pip-audit von
> dual-gate → **immer advisory**) kamen NIE an → **`main` rot** (Semgrep/pip-audit blockten auf main).
> **Fix:** `git tag -f v1 93c06b4` + `push -f` (verifiziert). **Lehre:** `@v1`-Ziel NIE aus Doku/Memory glauben
> — immer `git ls-remote origin refs/tags/v1` + `git log -1 <sha>`. Force-Move nur nach `git log v1 --not dev` (Verlust-Check).
>
> **🔴 ROOT-CAUSE-INCIDENT 2026-06-01 (CodeQL „immer rot" — ZWEI Schichten):** v1.3.7 (`upload:false` +
> hadolint `--failure-threshold error`) war die **falsche Ebene** + lief gar nicht. Echte Ursachen (via
> systematic-debugging + Web-Verifikation gegen `github/codeql-action#2117`):
> **(1) Orchestrator-Drift:** `reusable-ci.yml` pinnte ALLE 18 internen Refs auf `@v1.3.1` (stale), während
> alle anderen Reusables längst `@v1` floateten → reusable-ci@v1 zog **security-scan@v1.3.1** → mein
> `upload:false`-Edit (in security-scan@dev) **wurde nie ausgeführt**.
> **(2) Fehlendes `actions: read`:** CodeQL ruft auf PRIVATEN Repos `GET /actions/runs/{id}` → ohne den Scope
> `Resource not accessible by integration` → „configuration error". Pflicht-Scope laut codeql-action#2117
> (NICHT GHAS — `advanced_security: null` auf allen Repos, daher bleibt `upload:false` korrekt).
> **v1.3.8-Fix (verifiziert GRÜN auf RecyclageApp dev):** (a) reusable-ci interne Refs `@v1.3.1`→`@v1` (de-staled);
> (b) `actions: read` durch die **3-Schicht-Kette** App-Caller → reusable-ci `security`-Job → `codeql`-Job;
> (c) `upload:false` + hadolint-threshold bleiben (aus v1.3.7).
> **🔑 LEHRE:** Wenn du eine genestete Reusable editierst, prüf IMMER die **Pins im Orchestrator** (`grep '@v1\.' reusable-ci.yml`)
> — ein stale `@v1.3.x` heißt deine Edits an @v1/@dev laufen nicht. Permissions müssen durch JEDE Caller-Schicht (App→orchestrator-job→nested-job).
> **Rollout (2026-06-01):** `actions: read` in alle 4 App-Caller (Pflicht-Scope, sonst greift v1.3.8 nicht).
> **CodeQL verifiziert GRÜN** (lief, NICHT skipped): RecyclageApp dev+**main**, Rechnungsapp dev, MitarbeiterApp dev
> (je py+js `success`). FootballApp dev queued (Caller gefixt, identische Config → erwartet grün, noch nicht empirisch bestätigt).
> **Rechnungsapp/FootballApp/MitarbeiterApp `main`-Merge VERSCHOBEN** (User-Entscheidung 2026-06-01: kein zusätzlicher
> Prod-Rebuild jetzt). Diff ist CI-only (build.yml `actions:read`, nicht im Image) → fließt risikolos beim nächsten
> normalen dev→main-Flow auf `main`. RecyclageApp `main` ist bereits grün gemergt (`22261b7`).

---

## 🎯 Ziel der Initiative

EINE kanonische `reusable-ci.yml` + Composite-Actions in diesem Repo ersetzen die vier
unabhängig driftenden `build.yml` der ADZA-Apps (Rechnungsapp, RecyclageApp, FootballApp,
MitarbeiterApp). Jede App wird zum **~25-Zeilen-Caller** → null Drift. Domain-Spezifika
sind **Inputs (Daten)**, keine eigenen Jobs (z.B. `test-shards` JSON).

Entstanden via `superpowers` brainstorming → writing-plans → subagent-driven-development.
**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` (lies §8 für Per-App-Caller-Configs).
**Pläne:** `docs/superpowers/plans/2026-05-28-unified-ci-*.md`.

---

## ✅ Stand: was GEBAUT + VALIDIERT ist

**Alles actionlint-clean + GRÜN auf ubuntu-hosted validiert** (das self-hosted LXC-104
Dispatch hängt — ubuntu-hosted umgeht das und beweist die Logik end-to-end):

| Stück | Status |
|---|---|
| Composites: `setup-python-deps`, `run-pytest-shard`, `coverage-gate`, `start-app`, `opa-policy`(+Rego) | ✅ grün (ubuntu) |
| `reusable-frontend` (eslint/tsc/vitest/vite build/bundle-gate) | ✅ grün (ubuntu) |
| `reusable-security-scan` (gitleaks/bandit/semgrep/trivy/pip-audit/CodeQL/dep-review/OPA, dual-gate) | ✅ grün (ubuntu) |
| `reusable-docker-build` (buildx/size-gate/trivy-gate/SBOM/smoke/+push+cosign+SLSA+multi-arch) | ✅ grün (ubuntu) |
| **`reusable-ci.yml` Orchestrator (FULL chain, alle ~17 Jobs inkl. postgres+redis-Matrix)** | ✅ grün (ubuntu) |
| `reusable-load-test` (k6 p95/error-gate) | gebaut, NICHT validiert (braucht Live-Ziel) |
| `reusable-notify` / `-monitoring-dashboard` / `-pipeline-analytics` / `-weekly-cleanup` | vorbestehend |
| **Cycle B — ALL new reusables** (`reusable-dast`, `reusable-mutation`, `reusable-release`, `reusable-security-weekly`) + Lighthouse in `reusable-frontend` | ✅ grün (ubuntu) |

2 Code-Reviews (opus) + 6+ echte Bugs gefangen & gefixt (Permissions-Eskalation,
coverage-false-green, opa-rego-cross-fire, eslint-parser, fehlende checkouts, conftest-import).

## ❌ Was OFFEN ist (Wiederaufnahme-Punkte, Stand 2026-06-01)

1. **App-Test-Remediation (3 Apps)** — RecyclageApp/MitarbeiterApp/Rechnungsapp sind auf `@v1` migriert, die Pipeline LÄUFT korrekt (kein startup_failure mehr), Lint ist advisory — ABER ihre **Test-Suites scheitern am harten Test-Gate**. RecyclageApp verifiziert: postgres+redis starten sauber → **kein CI-/Config-Bug, echte App-Test-Fails**. Das ist App-Code-Arbeit PRO REPO (je App: `systematic-debugging` der Test-Fails bis grün), getrennt von der CI. **Nächster Schritt wenn gewünscht:** eine App vornehmen (RecyclageApp zuerst), Tests grün machen.
2. **MitarbeiterApp + Rechnungsapp**: ihre CI-Migration-Commits sind lokal committed aber teils noch nicht gepusht (+ fremde Feature-WIP im Working-Tree dieser Repos — NICHT mit-pushen!). Vor App-Arbeit: pro Repo `git status` prüfen, fremde WIP respektieren.
3. **FootballApp** pinnt `@v1.3.0` (exakt, grün); fleet-konsistenter wäre `@v1` — optionaler Angleich.
4. **LXC-104 self-hosted Runner** sind FLAKY + 4 GB RAM (OOM-Risiko bei 4 parallel schweren Jobs). Apps ohne `runner-label`-Override laufen dort. Für stabile self-hosted-Läufe ggf. Re-Registrierung / mehr RAM. Validierung lief deshalb auf ubuntu (`runner-label: '["ubuntu-latest"]'`).
5. **`reusable-load-test` + DAST/Lighthouse** brauchen Live-Staging-Ziele → noch nicht runtime-validiert.

---

## 🧩 Repo-Struktur

```
.github/workflows/
  reusable-ci.yml              # DER Orchestrator (changes→lint→security→test-matrix→coverage→docker-build→telemetry)
  reusable-security-scan.yml   # +CodeQL +dep-review +OPA, dual-gate (advisory PR/dev, blocking main/tag)
  reusable-docker-build.yml    # build+scan+SBOM+smoke (+ push+cosign+SLSA+multi-arch wenn push=true)
  reusable-load-test.yml       # k6 p95/error budget
  reusable-frontend.yml        # node lane, ubuntu-default
  reusable-notify / -monitoring-dashboard / -pipeline-analytics / -weekly-cleanup
  _smoke-*.yml                 # workflow_dispatch Smokes (composites, -ubuntu, security-scan, docker-build, frontend, ci)
.github/actions/
  setup-python-deps/           # System-python3 + per-job venv + cached deps (Debian-13-safe; ersetzt legacy setup-python-env)
  run-pytest-shard/ coverage-gate/ start-app/ opa-policy/(+policy/*.rego) health-check/
tests/fixtures/{app,docker,frontend}/   # Smoke-Fixtures
docs/superpowers/{specs,plans}/         # Design + Pläne
README.md                    # Asset-Liste + Caller-Contract + Caveats
```

## 📞 Caller-Contract (so ruft eine App `reusable-ci` auf)

Siehe `README.md` „Consuming reusable-ci.yml". **Kritisch: der App-Caller MUSS diesen
`permissions`-Block setzen** (sonst `startup_failure`):
```yaml
permissions: { contents: read, packages: write, id-token: write, attestations: write, security-events: write, checks: write }
```
Pflicht-Inputs: `app-name`, `test-shards` (JSON `[{name,paths,markers?,cov?}]`). DB-URL in `test-env` (JSON).

---

## ⚠️ GOTCHAS (hart erarbeitet — nicht nochmal reinlaufen)

1. **`uses: ./...` in einem reusable workflow löst gegen das CALLER-Repo auf**, nicht shared-workflows.
   → Composites/Sub-Reusables per VOLLEM Pfad + literalem Ref referenzieren:
   `adza-group/shared-workflows/.github/actions/<name>@<ref>` (keine `${{ }}` im `uses:`-Ref).
   Build-out: `@dev`; bei Release → `@v1`.
2. **Ein CALLED workflow GITHUB_TOKEN kann NICHT mehr als der Caller** → sonst `startup_failure`
   ("workflow file issue"). Caller muss die Scopes oben gewähren; `reusable-ci` claimt per-job.
3. **`gh workflow run` dispatcht nur Workflows auf dem DEFAULT-Branch** (dev-only Smokes → 404).
   Validieren via temporärem `push:[dev]`-Trigger im Smoke (danach zurücknehmen).
4. **LXC-104 Runner-Dispatch hängt:** Runner sind laut GitHub `online`+`idle`, nehmen aber keine
   Jobs an (Zombie-Dispatch). Ausgeschlossen: runner-group (=all repos), labels (match Apps),
   Konnektivität (curl=200), GitHub-Incident, Code. `systemctl restart actions.runner.*` half NICHT.
   Wahrscheinlich **Voll-Re-Registrierung nötig** (`config.sh remove` + neu). SSH: `ssh root@192.168.1.20`
   → `pct exec 104 -- ...`. **Bis dahin: alles ubuntu-hosted validieren** (`runner-label: '["ubuntu-latest"]'`).
5. **eslint flat config** braucht `typescript-eslint`; `tseslint.configs.base` ist ein EINZELNES
   Objekt (NICHT spreaden).
6. **opa-policy:** dockerfile.rego + compose.rego teilen `package main` → conftest wendet alle
   Regeln auf jeden Input an → dockerfile-Regeln mit `is_dockerfile`-Guard schützen (sonst Cross-Fire auf compose).
7. **Coverage portabel:** `relative_files = true` in run-pytest-shard (sonst absolute Pfade →
   coverage-gate-Job kann sie nicht auflösen).
8. **Git in diesem Clone hat KEINE user-config** → committen mit
   `NAME=$(git log -1 --format='%an'); EMAIL=$(git log -1 --format='%ae'); git -c user.name="$NAME" -c user.email="$EMAIL" commit -m ...`
   (NIE `git config` setzen — globale ADZA-Regel).
9. **Offene Review-Items (Design-Entscheidungen, in README CAVEATS):** M4 (Multi-Shard
   postgres-Port-Kollision auf den 4 same-host Runnern → dynamische Ports vor FootballApps 6 Shards);
   arm64 nicht separat Trivy-gescannt; frontend-only docker-build-Gate.

---

## 🔧 Wie man ein Stück auf ubuntu validiert (das Muster dieser Session)

1. Im Smoke-Caller `runner-label: '["ubuntu-latest"]'` setzen (Override; reusable-ci reicht es an
   nested Reusables durch) + temporär `on: { push: { branches: [dev] } }` hinzufügen.
2. `./bin/actionlint.exe <wf>` (exit 0) — actionlint.exe liegt in `bin/` (nicht committet); yamllint via `python -m yamllint -d relaxed`.
3. committen + `git push origin dev` → der push-Trigger feuert den Smoke auf ubuntu (NICHT vom LXC-104-Block betroffen).
4. `gh run watch <id> --exit-status` → grün?
5. Bei Fehler: `gh run view <id> --log-failed` → fixen (systematic-debugging) → re-push.
6. Nach grün: den temporären `push:[dev]`-Trigger wieder rausnehmen (Smoke = `workflow_dispatch`-only).

## ▶️ Empfohlener nächster Schritt

**Option A (entblockt alles):** LXC-104 Runner-Dispatch fixen (GOTCHA #4, Voll-Re-Registrierung)
→ dann self-hosted-Validierung + P4-Pilot (FootballApp zuerst, dev-first).
**Option B:** P3b (Deploy-Tail) + neue Reusables bauen (gegen Live-Staging validieren).
**Option C:** P4-Pilot-Migration vorbereiten (FootballApp build.yml → reusable-ci@dev-Caller, Config aus Spec §8).

> **2026-06-10 v1.7.1 RELEASED** (`@v1`=`50666b2`, ls-remote-verifiziert): changes-Job forciert auf main-PUSHES alle Filter-Outputs auf true — policy-konforme dev->main-Merges haben oft LEEREN dev...main-Diff (merge-base=dev-HEAD) -> Kaskaden-Skip -> require-staging-green las verify-staging=skipped und blockte den Promote hart (Incident Rechnungsapp Run 27258300405). Path-Filter bleiben dev/PR-Optimierung. E2E-bewiesen: Rechnungsapp-Promote `b2a6226` voll validiert + deployed.
