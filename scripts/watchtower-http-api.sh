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
import pathlib, re, sys
ip, swap = sys.argv[1], sys.argv[2] == "1"
p = pathlib.Path("docker-compose.yml")
s = p.read_text(encoding="utf-8")
changed = []
anchor = '      WATCHTOWER_LABEL_ENABLE: "true"\n'
# jede Variable einzeln (Codex-Fund: Teil-Konfiguration darf nicht als komplett gelten)
for key, line in (
    ("WATCHTOWER_HTTP_API_UPDATE", '      WATCHTOWER_HTTP_API_UPDATE: "true"            # Fleet-CI: verify-prod stoesst POST /v1/update an (2026-09-08)\n'),
    ("WATCHTOWER_HTTP_API_TOKEN", '      WATCHTOWER_HTTP_API_TOKEN: ${WATCHTOWER_HTTP_API_TOKEN}   # aus .env, nie ins Repo\n'),
    ("WATCHTOWER_HTTP_API_PERIODIC_POLLS", '      WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"    # 300-s-Poll bleibt als Fallback\n'),
):
    if key + ":" not in s:
        assert s.count(anchor) == 1, "WATCHTOWER_LABEL_ENABLE-Anker nicht eindeutig"
        s = s.replace(anchor, anchor + line, 1)
        changed.append(key)
if f"{ip}:8080:8080" not in s:
    m = re.search(r"(  watchtower:\n(?:.*\n)*?    restart: unless-stopped\n)", s)
    assert m, "watchtower-Block/restart-Zeile nicht gefunden"
    s = s[: m.end()] + '    ports:\n      - "' + ip + ':8080:8080"   # nur LAN-IP, Token-geschuetzt\n' + s[m.end():]
    changed.append("ports")
if swap and "containrrr/watchtower:latest" in s:
    s = s.replace("image: containrrr/watchtower:latest",
                  "image: nickfedor/watchtower:1.17.2  # containrrr EOL seit 2024-09; Fork mit HTTP-API (wie Staging 190)", 1)
    changed.append("image")
if changed:
    p.write_text(s, encoding="utf-8")
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
