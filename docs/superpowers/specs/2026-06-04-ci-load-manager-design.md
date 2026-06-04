# CI-Load-Manager (M2: Proaktiv/Kapazität) — Design

- **Datum:** 2026-06-04
- **Status:** Approved (brainstorming) → bereit für writing-plans
- **Kontext-Memory:** `project_runner_cost_switch.md`, `project_unified_ci.md`
- **Modul-Kontext:** M2 von 3 (M1 = Watchdog ✅ live; M3 = Routing-pro-Job). Folgt dem M1-Muster
  (externe systemd-Einheiten auf dem Proxmox-Host, klein, testbar).

## 1. Problem / gemessene Realität

Der Cost-Switch schickt CI auf LXC104, sobald GitHub-Gratis-Minuten leer sind. Bei Last war der
Backlog langsam. **Messung (2026-06-04) zeigt die echte Ursache — nicht die vermutete:**

| Signal | Wert | Folgerung |
|---|---|---|
| LXC104 RAM | **22 %** (930/4096 MB) bei 4 Runnern | RAM ist KEIN Engpass |
| LXC104 CPU | loadavg **4.46/7.04/9.92** auf 4 Cores; `us=54% sy=26% iowait=0%` | **compute-bound, oversubscribed** |
| Host | **6 physische Cores**, 18 Cores über 10 LXCs verteilt (3× oversubscribed) | kaum CPU-Reserve |
| cgroup | v2 (PVE 9.2.3); **alle LXCs `cpuunits=100`** (104 == Prod gleichberechtigt) | CI verdrängt Prod unter Last |

**Konsequenz:** „Mehr Kapazität" geht NICHT (6-Core-Host, geteilt mit Produktiv-Apps 103/105/102).
M2 macht CI **nicht schneller** (das bräuchte mehr Kerne). M2 verbessert zwei *andere* Dinge.

## 2. Entscheidungen

| # | Entscheidung | Begründung |
|---|---|---|
| D1 | **KEIN RAM-Bump, KEINE Extra-Cores, KEINE Extra-Runner, KEIN Cloud-Tier** | RAM frei (22 %); Host hat keine Core-Reserve; mehr Runner = mehr CPU-Contention; Cloud = cost-hart-Verstoß |
| D2 | **Komp. 1 — Prod-Schutz via cgroup-CPU-Weight** | CI darf Produktiv-Apps auf dem geteilten Host nie aushungern |
| D3 | **Komp. 2 — Pre-Warm via min-floor** | Idle-Runner kosten nur RAM (~0 CPU) → kollidiert nicht mit der CPU-Decke; spart Kaltstart-Latenz |
| D4 | **Build-Reihenfolge: Komp. 1 zuerst (kollisionsfrei), Komp. 2 später (Controller-Koordination)** | Komp. 2 berührt die runner-controller.sh der Parallel-Session |

## 3. Komponente 1 — Prod-Schutz (CPU-Priorität)

- **Mechanismus:** LXC104 (CI) bekommt **niedrigeres `cpuunits`** als die Prod-App-LXCs (die bei
  `100` bleiben). Empfohlen: **`pct set 104 -cpuunits 50`** (Prod doppelt so prioritär unter Last;
  tunbar runter auf 20 falls Prod weiter gedrückt wird).
- **Schlüssel-Eigenschaft (cgroup-Weight):** greift **nur unter Contention**. Ist Prod idle, bekommt
  CI weiterhin **volle CPU** — kein Durchsatz-Verlust ohne Konkurrenz. Nur ein CI-Burst, der auf
  aktive Prod trifft, weicht zurück.
- **Eigenschaften:** host-`pct set`, **idempotent**, **reversibel** (`-cpuunits 100`), **persistent**
  (in der LXC-Config, übersteht Reboot), **live** (cgroup-Weight, kein Reboot), **unabhängig vom
  runner-controller** → kollisionsfrei zur Parallel-Session.
- **Verifikation:** `cat /sys/fs/cgroup/lxc/104/cpu.weight` == gesetzter Wert; unter einem CI-Burst
  bleibt die Prod-CPU-Quote adäquat (Stichprobe loadavg/Prod-Health während Last).

## 4. Komponente 2 — Pre-Warm (min-floor) — Build später

- **Ziel:** Wenn Gratis-Minuten knapp werden (Switch kippt bald auf self-hosted), proaktiv mehr
  Runner **warm** halten → kein Kaltstart-Stau beim ersten Burst. Idle-Runner = nur RAM (frei).
- **`runner-prewarmer`** (neu, *meiner*): systemd-Timer auf dem Host (M1-Watchdog-Muster), fragt die
  Billing-Usage-API (gleiche Logik wie `decide-runner`), berechnet `remain`, und schreibt einen
  **min-floor** in eine Datei `/run/runner-controller/min-floor` (z.B. `remain ≤ 400 → 3`, sonst `1`).
- **runner-controller** (Parallel-Session, *1 Zeile koordinieren*): liest beim Skalieren den
  min-floor und hält **≥ floor** Runner warm (überschreibt sein internes MIN nach oben, nie nach unten).
- **Warum kein CPU-Problem:** warm-idle Runner verbrauchen ~0 CPU; CPU entsteht erst, wenn ein Job
  läuft (wie heute). Pre-Warm spart nur die **Pickup-Latenz**, nicht CPU.
- **Token:** der prewarmer braucht denselben read-only Billing-Token wie M1/decide-runner
  (`/opt/runner-watchdog/.env` mitnutzen oder eigene `.env`).

## 5. Architektur

```
Komp.1 (Prod-Schutz):   pct set 104 -cpuunits 50      [host-config, idempotent, jetzt baubar]
Komp.2 (Pre-Warm):      /opt/runner-prewarmer/prewarmer.sh + .timer  (Host, systemd, M1-Muster)
                          └─ billing → /run/runner-controller/min-floor ──┐
                        runner-controller.sh (Parallel-Session)  ←─────────┘ liest floor (1 Zeile)
```

Beide folgen M1: extern auf dem Host, systemd, klein, mit gemockten Unit-Tests (Komp. 2) bzw.
Verify-Schritt (Komp. 1).

## 6. Testplan

- **Komp. 1:** nach `pct set` → `cpu.weight == 50` prüfen; (optional) künstlicher CPU-Burst in 104
  während Prod-Last → Prod-loadavg/Health bleibt adäquat. Reversibilität: `-cpuunits 100` → `100`.
- **Komp. 2:** `prewarmer.sh` mit gemocktem Billing (Zustandstabelle remain→floor) → korrekter
  floor-Wert in die Datei; Edge: kein Token → floor=1 (sicherer Default, kein Über-Warmen).
  Integration: floor=3 setzen → Controller hält 3 warm (nach Koordination).

## 7. Non-Goals / Risiken

- **Non-Goals:** mehr Cores/RAM/Runner/Cloud (D1); CI-Lauf-Speed (Core-Decke, nicht lösbar);
  den runner-controller umschreiben (nur 1-Zeilen-floor-Hook).
- **R1:** Komp. 1 zu aggressiv (cpuunits zu niedrig) → CI unnötig langsam auch ohne Prod-Last.
  Gemindert: Weight greift nur unter Contention; Start bei 50 (moderat), tunbar.
- **R2:** Komp. 2 koordiniert mit Parallel-Session → floor-Contract muss abgestimmt sein (sonst no-op).
- **R3:** prewarmer ohne Token → floor=1 (kein Über-Warmen, kein Schaden).

## 8. Out of Scope

- **M3 — Routing-pro-Job** (schwere Jobs lokal, leichte hosted; berührt `reusable-ci.yml@v1`).
- Host-Hardware-Upgrade (mehr Cores) = User-Infra-Entscheidung, kein Code.
