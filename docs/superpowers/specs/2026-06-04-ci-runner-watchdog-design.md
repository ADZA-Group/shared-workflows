# CI-Runner-Watchdog (M1: Robustheit) — Design

- **Datum:** 2026-06-04
- **Status:** Approved (brainstorming) → bereit für writing-plans
- **Kontext-Memory:** `project_runner_cost_switch.md`, `project_unified_ci.md`
- **Modul-Kontext:** M1 von 3 (M2 = Proaktiv/Kapazität, M3 = Routing-pro-Job) — siehe „Out of Scope".

## 1. Problem / Motivation

Der bestehende **CI-Runner-Kosten-Switch** (`decide-runner`-Job in allen 4 ADZA-App-`build.yml`)
routet pro Lauf auf **hosted ubuntu** solange GitHub-Gratis-Minuten da sind, sonst auf
**self-hosted LXC104** (proxmox, gratis). Damit ist LXC104 **load-bearing**: sobald die
Gratis-Minuten aufgebraucht sind, hängt die gesamte CI an diesem einen Host.

**Fehlerfall (heute ungelöst):** LXC104 / der `runner-controller` ist tot **und** das
Gratis-Kontingent ist leer → `decide-runner` wählt self-hosted → es ist aber kein Runner da →
**alle Jobs stauen sich still**, ohne Signal. Der `decide-runner`-Job selbst läuft auf
self-hosted, kann also im Fehlerfall **nicht** alarmieren (beide Runner-Typen weg).

## 2. Entscheidungen (aus Brainstorming)

| # | Entscheidung | Begründung |
|---|---|---|
| D1 | **Cost-hart: nie auf hosted ausweichen** | User-Vorgabe absolut „nie zahlen". Über Limit ⇒ immer lokal, auch wenn lokal down ist. |
| D2 | **Auto-Heal zuerst, dann Alarm** | Häufige Fälle (hängender Controller, Zombie) sollen sich selbst reparieren; Mensch nur bei echtem Problem. |
| D3 | **Alarm-Kanal: E-Mail** (one.com) | Push an den User; sieht „CI staut" sofort, auch ohne ins Repo zu schauen. Kein externer Chat-Kanal (ADZA-Policy). |
| D4 | **Wächter läuft EXTERN auf dem Proxmox-Host** (192.168.1.20) | Muss überleben, wenn LXC104 tot ist. In-Actions oder in-LXC104 kann sich nicht selbst heilen/melden. |

## 3. Architektur

- **Ort:** Proxmox-Host `192.168.1.20`, außerhalb LXC104.
- **Form:** `systemd`-Service + Timer (konsistent mit dem bestehenden `runner-controller`, der
  ebenfalls systemd/bash ist). **Kein** GitHub-Actions-Job, **kein** Cron-in-LXC104.
- **Takt:** alle **5 Minuten** (Timer `OnUnitActiveSec=5min`, plus `OnBootSec`).
- **Dateien:**
  - `/opt/runner-watchdog/watchdog.sh` — die Logik
  - `/opt/runner-watchdog/.env` — Secrets (root-only `chmod 600`): one.com-SMTP + read-only GH-Token
  - `/etc/systemd/system/runner-watchdog.service` (Type=oneshot)
  - `/etc/systemd/system/runner-watchdog.timer`
  - State: `/var/lib/runner-watchdog/state` (für idempotente Alarme)

## 4. Detektions-Logik

Pro Tick, in Reihenfolge:

1. **Container:** `pct status 104` == `running`?
2. **Dienst:** `pct exec 104 -- systemctl is-active runner-controller.service` == `active`?
3. **Kapazität:** GitHub-API `GET /orgs/ADZA-Group/actions/runners` → Anzahl Runner mit
   `status == online` (egal ob busy).

**Health-Definition (entscheidend — „down" vs „busy"):**
- **HEALTHY:** Container running **und** Controller active **und** ≥1 Runner online (der
  `runner-controller` hält `MIN_RUNNERS=1`, im gesunden Zustand ist also dauerhaft ≥1 Runner
  online — 0 online ist daher ein verlässliches Down-Signal). Reiner Stau (Runner online, alle
  `busy`) = **healthy, keine Aktion.**
- **DOWN:** Container ≠ running **oder** Controller ≠ active **oder** (0 Runner online **für
  ≥ 2 aufeinanderfolgende Ticks**, um eine kurze Skalierungs-Lücke nicht als Ausfall zu werten).
- **UNKNOWN (KEIN Down-Signal):** Runner-API unlesbar (z.B. Token fehlt/abgelaufen → Count `-1`)
  ⇒ **keine Eskalation, kein Heal/Reboot** — nur Container/Controller-Signale zählen dann.
  Verhindert einen Fehl-Reboot, der einen gesunden Runner bei reinem Token-Problem abwürgen würde.

> Die „2 Ticks"-Hysterese verhindert Fehlalarm, während der Controller gerade einen Runner
> hoch-/runterfährt.

## 5. Auto-Heal-Leiter (nur bei bestätigtem DOWN)

- **Stufe 1 — Dienst:** Controller inaktiv, Container aber running →
  `pct exec 104 -- systemctl restart runner-controller.service`; 60 s warten; neu prüfen.
- **Stufe 2 — Container:** Container nicht running **oder** weiter 0 Runner nach Stufe 1 →
  `pct reboot 104`; 90 s warten; neu prüfen.
  - **🔒 Sicherheits-Guard:** Reboot **nur**, wenn aktuell **kein Runner `busy`** ist
    (`busy=0` in der Runner-API) — niemals einen laufenden CI-Job abwürgen. Läuft ein Job →
    **kein Reboot**, direkt Alarm „down während Job läuft, kein sicherer Reboot möglich".
- **Stufe 3 — Eskalation:** immer noch DOWN nach Heilung → **E-Mail-Alarm** (Abschnitt 6).

## 6. Alarmierung (E-Mail, idempotent)

- **Transport:** SMTP one.com via `msmtp` (oder `curl --url smtps://…`), Creds aus `.env`.
- **Empfänger:** `aazad.aahmed@hotmail.com` (konfigurierbar in `.env`).
- **Anti-Spam (State-Machine über `/var/lib/runner-watchdog/state`):**
  - Übergang `healthy → down` (nach fehlgeschlagener Heilung): **1 Mail** „🔴 down".
  - Bleibt down: **Re-Alarm erst nach 6 h**.
  - Übergang `down → healthy`: **1 Mail** „✅ wieder gesund" (inkl. was geheilt hat).
- **Inhalt:** geprüfte Signale, versuchte Heil-Stufen, aktueller Zustand, Anzahl wartender
  Workflow-Runs (optional via `GET /repos/.../actions/runs?status=queued`).

## 7. Logging & Beobachtbarkeit

- Alles nach **journald** (`journalctl -u runner-watchdog`), gleiche Konvention wie
  `runner-controller`. Jede Aktion (check/heal/alert) mit Zeitstempel + Ergebnis.

## 8. Setup-Abhängigkeiten (einmalig, User-seitig)

1. **one.com SMTP-Creds** in `/opt/runner-watchdog/.env` (Host, `chmod 600`).
2. **Read-only GitHub-Token** in derselben `.env` (Scope: `read:org` für Runner-Status; optional
   `repo` read für queued-runs). Idealerweise dedizierter fine-grained PAT „read-only Actions/Org".

## 9. Test- / Verifikationsplan

- **Unit (Logik):** `watchdog.sh` mit gemockten Funktionen (`pct`/`gh`-Stubs) — Tabelle aus
  Zuständen (running/active/online-Counts/busy) → erwartete Aktion (none/restart/reboot/alert).
  Inklusive: busy-Stau ⇒ keine Aktion; 1-Tick-0-Runner ⇒ keine Aktion (Hysterese);
  Reboot-Guard ⇒ kein Reboot bei busy.
- **Integration (kontrolliert, am Host):**
  1. `systemctl stop runner-controller` in 104 → Wächter muss Stufe 1 (restart) ausführen, Recovery-Mail.
  2. (Wartungsfenster) `pct stop 104` mit `busy=0` → Wächter Stufe 2 (reboot) + Recovery.
  3. SMTP-Fehlpfad: falsche Creds → Wächter loggt Fehler, crasht nicht.
- **Idempotenz:** zweiter Tick im selben down-Zustand ⇒ keine zweite Mail (Cooldown).

## 10. Non-Goals / Bewusst NICHT

- **Kein** Ausweichen auf hosted (D1, cost-hart).
- **Kein** Abwürgen laufender Jobs (Reboot-Guard).
- **Kein** Eingriff bei normalem Stau/`busy` (nur bei echtem down).
- **Kein** Ersatz für den `runner-controller` (der skaliert weiter; der Wächter überwacht ihn nur).

## 11. Out of Scope (spätere Module)

- **M2 — Proaktiv/Kapazität:** Runner vorwärmen bei knappen Minuten; optional Cloud-Spot 3. Tier.
- **M3 — Routing pro Job:** schwere Jobs immer lokal, leichte hosted; berührt `reusable-ci.yml@v1`.

## 12. Risiken / offene Punkte

- **R1:** `pct reboot 104` bei fälschlich erkanntem down während eines Jobs → durch
  `busy=0`-Guard + 2-Tick-Hysterese gemindert.
- **R2:** SMTP-Creds/Token auf dem Host = Secret-Fläche → root-only `.env`, least-privilege Token.
- **R3:** Wächter selbst fällt aus (Proxmox-Host down) → außerhalb des Scopes (wenn der
  Proxmox-Host weg ist, ist alles weg); `Restart=on-failure` am Service mindert Prozess-Crashes.
- **R4 (gefunden + gefixt bei Implementierung):** Fehlender/abgelaufener `GH_TOKEN` → Runner-API
  liefert `-1`; naiv als „0 Runner" gewertet hätte das zu **Fehl-Reboot eines gesunden Runners**
  geführt. Gemindert: `classify` unterscheidet `unknown:online_api` (eskaliert NICHT) von echtem
  `0` (eskaliert). Test: `unknown tick1..3 -> healthy`, `unknown keeps ticks=0`.
