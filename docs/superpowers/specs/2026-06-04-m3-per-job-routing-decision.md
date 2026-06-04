# M3 „Routing-pro-Job" — Decision Record (PARKED, kein Build)

- **Datum:** 2026-06-04
- **Status:** ⛔ **PARKED** — bewusst NICHT gebaut. Dies ist ein Entscheidungs-Dokument, kein
  Bau-Auftrag. Es transitioniert NICHT zu writing-plans.
- **Entscheid:** brainstorming (User wählte „Decision-Record / parken").
- **Kontext:** M3 von 3 im CI-Runner-Cost-Switch-Ausbau (M1 Watchdog ✅ live, M2 ✅ Komp.1 live /
  Komp.2 Code fertig). Memory: `project_runner_cost_switch.md`.

## 1. Die Idee (was M3 wäre)

Statt eines `runner-label` für den **ganzen** Lauf → **pro Job** routen: schwere Jobs
(Docker-Build, multi-arch, ML-Test-Shards) immer **self-hosted** (gratis lokal); leichte
(Lint, Smoke, Format) **hosted ubuntu** solange Gratis-Minuten da → schnelles PR-Feedback.
**Ziel:** Gratis-Minuten *strecken*, weil die teuren (minuten-fressenden) Jobs sie nicht verbrennen.

## 2. Warum PARKED — 4 Befunde (gemessen diese Session)

1. **Hoher Preis, contested:** Apps rufen `reusable-ci.yml@v1` mit **einem** `runner-label` auf →
   ALLE Jobs nutzen es. Per-Job-Routing braucht zwei Label-Pfade (heavy/light) quer durch
   `reusable-ci.yml` — die **released, parallel-aktiv betreute** @v1-Datei (CI-Power-up-Session).
   Eingriff = Kollision + Re-Release-Risiko.
2. **Greift selten:** Org ist über dem Gratis-Limit (**2130/2000** am 4. Juni) und verbraucht das
   2000er-Kontingent früh im Monat → die meiste Zeit läuft cost-hart **eh alles lokal**. Das
   Free-Minuten-Fenster, in dem M3s Split überhaupt etwas ändert, ist **klein** → Nutzen marginal.
3. **Schadet dem Engpass:** Der lokale Host hat **6 physische Cores** und ist schon compute-bound
   (M2-Messung: loadavg 4.46–9.92 auf 4 Cores, `us=54%`). „Schwere Jobs IMMER lokal" **verschärft**
   die CPU-Sättigung, und schwere Jobs laufen lokal **langsamer** als auf dediziertem hosted-ubuntu.
   M3 ist ein **Minuten-vs-Speed-Tradeoff**, der bei 6 Cores schlecht ausfällt.
4. **Teil schon erledigt:** Die Parallel-Session hat RecyclageApp `multi-arch:false` gesetzt
   (amd64-only, kein QEMU-OOM lokal) — das größte „schwerer-Job-killt-lokal"-Risiko ist weg.

**Fazit:** M3 kostet am meisten (contested @v1) für den geringsten, seltensten Nutzen — und
arbeitet teils GEGEN den realen Engpass (lokale CPU). Klassischer YAGNI-Fall.

## 3. Revisit-Trigger — wann M3 sich DOCH lohnt

Dieses Dokument neu bewerten, sobald **einer** davon eintritt:

- **Mehr lokale Cores:** Der Runner-Host bekommt deutlich mehr CPU (z.B. ≥ 12 Cores oder ein 2.
  Runner-Host). Dann verschwindet Befund #3 (heavy-lokal schadet nicht mehr) → Split wird attraktiv.
- **Dauerhaft viel Gratis-Kontingent:** Org wechselt auf einen Plan mit deutlich mehr inkludierten
  Minuten (oder der Verbrauch sinkt), sodass das Free-Fenster **groß** ist → Befund #2 entfällt,
  Minuten-Strecken bringt real etwas.
- **Sauberer Extension-Point in reusable-ci:** Die CI-Power-up-Session ist fertig + `reusable-ci.yml`
  ist stabil, und es gibt (oder lässt sich kollisionsfrei einführen) einen pro-Job-Label-Hook →
  Befund #1 (Kollision) entschärft.

## 4. Falls revisited — die EMPFOHLENE Light-Variante (nicht Voll-Routing)

Nicht das volle per-Job-Routing bauen, sondern **minimal-invasiv + opt-in**:
- Ein **optionaler** Input `heavy-runner-label` in `reusable-ci.yml`, **default = `inputs.runner-label`**
  (= der normale decide-Label → **null Verhaltensänderung**, außer eine App opt-in't).
- Nur die wenigen wirklich schweren Jobs (docker-build, ggf. der `ml`-Shard) nutzen
  `heavy-runner-label`; alles andere bleibt auf `runner-label`.
- So bleibt die Änderung an `reusable-ci` klein + rückwärtskompatibel, und Apps schalten es
  bewusst pro schwerem Job frei.

## 5. Was JETZT gilt (kein Handlungsbedarf)

Der bestehende `decide-runner` (M-Switch) + M2-Komp.1 (Prod-CPU-Schutz) decken das Praktische ab:
über Limit → alles lokal (gratis), CI weicht Prod via cpu-weight. Kein per-Job-Routing nötig.

## 6. Out of Scope

Host-Hardware-Upgrade (mehr Cores) = reine User-Infra-Entscheidung. M1/M2 sind separat dokumentiert.
