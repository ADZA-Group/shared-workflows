#!/usr/bin/env bash
# Watchtower HTTP-API auf einem Prod-Host aktivieren (Fleet-CI Prod-Trigger, 2026-09-08).
# Idempotent: Token nur anlegen, wenn er fehlt; Compose nur patchen, wenn die Zeilen fehlen.
# Aufruf: bash wt-prod-patch.sh <app-dir> <lxc-ip> <swap-image 0|1>
set -euo pipefail
APP_DIR="$1"; LXC_IP="$2"; SWAP="${3:-0}"
cd "$APP_DIR"
[ -f docker-compose.yml ] || { echo "kein docker-compose.yml in $APP_DIR"; exit 1; }

# 1) Token (nur ins .env, nie ausgeben). Rechte VOR dem Schreiben setzen (Security-Review 08.09.:
#    sonst liegt der Token kurz mit den alten .env-Rechten auf der Platte).
umask 077
touch .env && chmod 600 .env
if ! grep -q '^WATCHTOWER_HTTP_API_TOKEN=' .env; then
  printf 'WATCHTOWER_HTTP_API_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
  echo "token: neu angelegt"
else
  echo "token: vorhanden"
fi
# 2) Compose-Block patchen (Python: mehrzeilige, idempotente Edits)
python3 - "$LXC_IP" "$SWAP" <<'PY'
# Alle Pruefungen NUR im `watchtower:`-Service-Block (Codex-Fund 08.09.: globale Suche haette einen
# gleichnamigen Key in einem anderen Service als "vorhanden" gewertet und den Patch stumm uebersprungen)
# und NUR zeilenverankert (Runde 3: ein auskommentierter alter Service im Block enthaelt Port/Image als
# Substring — Substring-Checks liessen den Port stumm aus und schrieben den Kommentar um).
# Getestet durch scripts/tests/test_watchtower_compose_patch.py (Heredoc wird dort exakt so ausgefuehrt).
import pathlib, re, sys
ip, swap = sys.argv[1], sys.argv[2] == "1"
p = pathlib.Path("docker-compose.yml")
s = p.read_text(encoding="utf-8")
# Block = von "  watchtower:" bis zur naechsten Zeile, die (a) ein anderer Service ist (genau 2 Leerzeichen +
# Zeichen ausser #) oder (b) eine Top-Level-Sektion (Spalte 0, Zeichen ausser #: networks:/volumes:/x-*).
# Codex-Fund Runde 2: ohne (b) schluckte der Block eine folgende x-*-Sektion mit 4er-Einrueckung komplett,
# deren Keys/Port galten dann als watchtower-Konfiguration. Codex-Fund Runde 3: `  # kommentar` mitten im
# Service beendete den Block, eine danach stehende image:-Zeile blieb stumm ungeswappt. Leerzeilen und
# Kommentare (jede Einrueckung) gehoeren zum Block.
m = re.search(r"^  watchtower:\n(?:(?! {0,2}[^\s#]).*\n?)*", s, flags=re.M)
assert m, "kein Service-Block `watchtower:` in docker-compose.yml"
block_start, block_end = m.start(), m.end()
block = s[block_start:block_end]
changed = []

def find(pattern):  # zeilenverankert im aktuellen Block: Kommentarzeilen (#…) matchen nie
    return re.search(pattern, block, flags=re.M)

# jede Variable einzeln (Codex-Fund: Teil-Konfiguration darf nicht als komplett gelten)
for key, line in (
    ("WATCHTOWER_HTTP_API_UPDATE", '      WATCHTOWER_HTTP_API_UPDATE: "true"            # Fleet-CI: verify-prod stoesst POST /v1/update an (2026-09-08)\n'),
    ("WATCHTOWER_HTTP_API_TOKEN", '      WATCHTOWER_HTTP_API_TOKEN: ${WATCHTOWER_HTTP_API_TOKEN}   # aus .env, nie ins Repo\n'),
    ("WATCHTOWER_HTTP_API_PERIODIC_POLLS", '      WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"    # 300-s-Poll bleibt als Fallback\n'),
):
    if find(r"^      " + key + r":") is None:
        anchors = list(re.finditer(r'^      WATCHTOWER_LABEL_ENABLE: "true"[ \t]*(#.*)?\n', block, flags=re.M))
        assert len(anchors) == 1, "WATCHTOWER_LABEL_ENABLE-Anker im watchtower-Block nicht eindeutig"
        block = block[: anchors[0].end()] + line + block[anchors[0].end():]
        changed.append(key)
port_line = '      - "' + ip + ':8080:8080"   # nur LAN-IP, Token-geschuetzt\n'
if find(r'^      - "?' + re.escape(ip) + r':8080:8080\b') is None:
    ports = find(r"^    ports:[ \t]*(#.*)?\n")
    if ports:
        # vorhandene Liste ergaenzen — KEIN zweiter `ports:`-Key (Codex-Fund Runde 2: doppelter Mapping-Key)
        block = block[: ports.end()] + port_line + block[ports.end():]
    else:
        r = find(r"^    restart: unless-stopped[ \t]*(#.*)?\n")
        assert r, "restart-Zeile im watchtower-Block nicht gefunden"
        block = block[: r.end()] + "    ports:\n" + port_line + block[r.end():]
    changed.append("ports")
if swap:
    block, n = re.subn(r"^    image: containrrr/watchtower:latest\b.*$",
                       "    image: nickfedor/watchtower:1.17.2  # containrrr EOL seit 2024-09; Fork mit HTTP-API (wie Staging 190)",
                       block, count=1, flags=re.M)
    if n:
        changed.append("image")
if changed:
    p.write_text(s[:block_start] + block + s[block_end:], encoding="utf-8")
print("compose:", ", ".join(changed) if changed else "unveraendert")
PY

# 3) validieren, dann nur den Watchtower-Dienst neu erstellen
docker compose config -q && echo "compose config: ok"
docker compose up -d watchtower
sleep 4
docker ps --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}' | grep -i watchtower
# 4) Endpoint live + Auth erzwungen? POST mit falschem Token MUSS 401 liefern (loest kein Update aus);
#    alles andere (000 = kein Listener, 200 = Auth aus) ist ein Fehler (Codex-Fund: vorher GET + nicht asserted).
PROBE_TOKEN=wrong-token   # bewusst falsch: nur die 401-Probe, kein Secret
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -X POST -H "Authorization: Bearer ${PROBE_TOKEN}" "http://${LXC_IP}:8080/v1/update" || true)  # gitleaks:allow
echo "probe POST falscher Token -> HTTP ${STATUS}"
[ "$STATUS" = "401" ] || { echo "FEHLER: erwartet 401 (Listener + Auth), bekommen ${STATUS}"; exit 1; }
