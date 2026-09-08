"""Tests fuer den Compose-Patch in scripts/watchtower-http-api.sh (Pair-Runde 08.09., Codex-Fund).

Der Patch lebt als Python-Heredoc im Shell-Skript und wird hier EXAKT so ausgefuehrt, wie bash es
tut: `python3 - <ip> <swap>` mit dem Heredoc-Text auf stdin, cwd = Fixture-Verzeichnis. Kein Docker,
kein Netz. Geprueft: Erstlauf, Idempotenz, Teil-Konfiguration, gleichnamiger Key in einem ANDEREN
Service (darf den watchtower-Block nicht als konfiguriert gelten lassen), Image-Swap, fehlender Block.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

import pytest
import yaml

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "watchtower-http-api.sh"

BASE = """services:
  app:
    image: ghcr.io/adza-group/demo:latest
    restart: unless-stopped
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_POLL_INTERVAL: 300
    deploy:
      resources:
        limits:
          memory: 64M

networks:
  app-net: {}
"""


def _heredoc() -> str:
    text = SCRIPT.read_text(encoding="utf-8")
    m = re.search(
        r"python3 - \"\$LXC_IP\" \"\$SWAP\" <<'PY'\n(.*?)\nPY\n", text, flags=re.S
    )
    assert m, "Python-Heredoc im Skript nicht gefunden"
    return m.group(1)


def run_patch(
    tmp_path: pathlib.Path, compose: str, ip: str = "192.168.1.9", swap: str = "1"
):
    (tmp_path / "docker-compose.yml").write_text(compose, encoding="utf-8")
    r = subprocess.run(
        [sys.executable, "-", ip, swap],
        input=_heredoc(),
        text=True,
        capture_output=True,
        cwd=tmp_path,
    )
    return r, (tmp_path / "docker-compose.yml").read_text(encoding="utf-8")


def _watchtower_block(text: str) -> str:
    # gleiche Grenze wie im Skript: naechster Service (2 Leerzeichen + Zeichen ausser #) ODER Top-Level-
    # Sektion (Spalte 0, Zeichen ausser #) beendet den Block; Kommentare jeder Einrueckung bleiben drin
    m = re.search(r"^  watchtower:\n(?:(?! {0,2}[^\s#]).*\n?)*", text, flags=re.M)
    assert m
    return m.group(0)


def _wt_service(text: str) -> dict:
    """Semantische Gegenprobe: Ausgabe muss gueltiges YAML sein, Ergebnis = services.watchtower."""
    return yaml.safe_load(text)["services"]["watchtower"]


def test_indented_comment_inside_service_keeps_block_open(tmp_path):
    """Codex-Fund Runde 3: ein 2-Leerzeichen-Kommentar MITTEN im Service beendete den Block; die danach
    stehende `image:`-Zeile blieb beim Swap unangetastet — stumm ('compose: unveraendert'), und
    `docker compose config` bleibt gruen. Nur ein anderer Service (2 Leerzeichen + Zeichen ausser #)
    darf den Block beenden."""
    configured_then_comment_then_image = (
        BASE.replace(
            "  watchtower:\n    image: containrrr/watchtower:latest\n",
            "  watchtower:\n",
        )
        .replace(
            '      WATCHTOWER_LABEL_ENABLE: "true"\n',
            '      WATCHTOWER_LABEL_ENABLE: "true"\n'
            '      WATCHTOWER_HTTP_API_UPDATE: "true"\n'
            "      WATCHTOWER_HTTP_API_TOKEN: ${WATCHTOWER_HTTP_API_TOKEN}\n"
            '      WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"\n',
        )
        .replace(
            "    restart: unless-stopped\n    volumes:\n",
            '    restart: unless-stopped\n    ports:\n      - "192.168.1.9:8080:8080"\n    volumes:\n',
        )
        .replace(
            "          memory: 64M\n",
            "          memory: 64M\n  # runtime image\n    image: containrrr/watchtower:latest\n",
        )
    )
    r, out = run_patch(tmp_path, configured_then_comment_then_image, swap="1")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "compose: image"
    assert _wt_service(out)["image"] == "nickfedor/watchtower:1.17.2"
    assert "  # runtime image\n" in out


def test_top_level_section_after_watchtower_is_not_part_of_block(tmp_path):
    """Codex-Fund Runde 2: eine Top-Level-Sektion nach watchtower — hier ein x-*-Template mit 4er-Einrueckung,
    also ohne Zeile `^  \\S` — darf den Block nicht verlaengern. Mit der alten Grenze galten dessen Keys/Port
    als watchtower-Konfiguration und der Patch blieb stumm aus (GEMESSEN: 'compose: unveraendert')."""
    with_template = BASE.replace(
        "networks:\n  app-net: {}\n",
        "x-watchtower-template: &wt\n"
        "    ports:\n"
        '      - "192.168.1.9:8080:8080"\n'
        "    environment:\n"
        '      WATCHTOWER_HTTP_API_UPDATE: "true"\n'
        "      WATCHTOWER_HTTP_API_TOKEN: fremd\n"
        '      WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"\n'
        "# Kommentar in Spalte 0\n"
        "networks:\n  app-net: {}\n",
    )
    r, out = run_patch(tmp_path, with_template, swap="0")
    assert r.returncode == 0, r.stderr
    assert (
        "compose: WATCHTOWER_HTTP_API_UPDATE, WATCHTOWER_HTTP_API_TOKEN, WATCHTOWER_HTTP_API_PERIODIC_POLLS, ports"
        in r.stdout
    )
    block = _watchtower_block(out)
    assert "x-watchtower-template" not in block and "networks:" not in block
    wt = _wt_service(out)
    assert (
        wt["environment"]["WATCHTOWER_HTTP_API_TOKEN"] == "${WATCHTOWER_HTTP_API_TOKEN}"
    )
    assert wt["ports"] == ["192.168.1.9:8080:8080"]
    # fremde Sektion unveraendert
    assert (
        yaml.safe_load(out)["x-watchtower-template"]["environment"][
            "WATCHTOWER_HTTP_API_TOKEN"
        ]
        == "fremd"
    )


def test_commented_out_old_service_is_ignored(tmp_path):
    """Runde 3 (Claude): ein auskommentierter alter Service gehoert zum Block (Spalte-0-Kommentare) und
    enthaelt Port, containrrr-Image und LABEL_ENABLE-Anker als Substring. Substring-Checks liessen den Port
    stumm aus, swappten den Kommentar und zaehlten den Anker doppelt — alle Checks sind zeilenverankert."""
    commented = BASE.replace(
        "image: containrrr/watchtower:latest", "image: nickfedor/watchtower:1.17.2"
    ).replace(
        "\nnetworks:\n",
        "# alt, deaktiviert:\n"
        "#  watchtower-old:\n"
        "#    image: containrrr/watchtower:latest\n"
        "#    ports:\n"
        '#      - "192.168.1.9:8080:8080"\n'
        "#    environment:\n"
        '#      WATCHTOWER_LABEL_ENABLE: "true"\n'
        "\nnetworks:\n",
    )
    r, out = run_patch(tmp_path, commented, swap="1")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip().endswith(
        "PERIODIC_POLLS, ports"
    )  # kein "image": nichts zu swappen
    assert _wt_service(out)["ports"] == ["192.168.1.9:8080:8080"]
    assert "#    image: containrrr/watchtower:latest\n" in out  # Kommentar unangetastet
    assert out.count("nickfedor/watchtower:1.17.2") == 1


def test_existing_ports_list_is_extended_not_duplicated(tmp_path):
    """Codex-Fund Runde 2: vorhandenes `ports:` mit anderem Mapping darf keinen zweiten `ports:`-Key erzeugen."""
    with_ports = BASE.replace(
        "    restart: unless-stopped\n    volumes:\n",
        '    restart: unless-stopped\n    ports:\n      - "127.0.0.1:8080:8080"\n    volumes:\n',
    )
    r, out = run_patch(tmp_path, with_ports, swap="0")
    assert r.returncode == 0, r.stderr
    block = _watchtower_block(out)
    assert block.count("    ports:\n") == 1
    assert '- "127.0.0.1:8080:8080"' in block and '- "192.168.1.9:8080:8080"' in block
    assert re.search(
        r'    ports:\n      - "192\.168\.1\.9:8080:8080".*\n      - "127\.0\.0\.1:8080:8080"\n',
        block,
    )


def test_first_run_adds_env_ports_and_swaps_image(tmp_path):
    r, out = run_patch(tmp_path, BASE)
    assert r.returncode == 0, r.stderr
    assert (
        "compose: WATCHTOWER_HTTP_API_UPDATE, WATCHTOWER_HTTP_API_TOKEN, WATCHTOWER_HTTP_API_PERIODIC_POLLS, ports, image"
        in r.stdout
    )
    block = _watchtower_block(out)
    assert 'WATCHTOWER_HTTP_API_UPDATE: "true"' in block
    assert "WATCHTOWER_HTTP_API_TOKEN: ${WATCHTOWER_HTTP_API_TOKEN}" in block
    assert 'WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"' in block
    assert '- "192.168.1.9:8080:8080"' in block
    assert "image: nickfedor/watchtower:1.17.2" in block
    # ports direkt nach restart, innerhalb des Blocks; Rest der Datei unveraendert
    assert re.search(r"restart: unless-stopped\n    ports:\n", block)
    assert out.startswith(
        "services:\n  app:\n    image: ghcr.io/adza-group/demo:latest\n    restart: unless-stopped\n"
    )
    assert out.endswith("networks:\n  app-net: {}\n")


def test_second_run_is_noop(tmp_path):
    _, once = run_patch(tmp_path, BASE)
    r, twice = run_patch(tmp_path, once)
    assert r.returncode == 0, r.stderr
    assert "compose: unveraendert" in r.stdout
    assert twice == once


def test_partial_config_gets_completed(tmp_path):
    partial = BASE.replace(
        '      WATCHTOWER_LABEL_ENABLE: "true"\n',
        '      WATCHTOWER_LABEL_ENABLE: "true"\n      WATCHTOWER_HTTP_API_UPDATE: "true"\n',
    )
    r, out = run_patch(tmp_path, partial, swap="0")
    assert r.returncode == 0, r.stderr
    assert "WATCHTOWER_HTTP_API_UPDATE" not in r.stdout.split("compose:")[1]
    block = _watchtower_block(out)
    assert block.count("WATCHTOWER_HTTP_API_UPDATE:") == 1
    assert "WATCHTOWER_HTTP_API_TOKEN: ${WATCHTOWER_HTTP_API_TOKEN}" in block
    assert 'WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"' in block
    assert "image: containrrr/watchtower:latest" in block  # swap=0


def test_same_key_in_other_service_does_not_count(tmp_path):
    """Codex-Fund: ein anderer Service mit denselben Keys/Port darf den watchtower-Block nicht als
    konfiguriert erscheinen lassen."""
    other = BASE.replace(
        "  app:\n    image: ghcr.io/adza-group/demo:latest\n    restart: unless-stopped\n",
        "  app:\n    image: ghcr.io/adza-group/demo:latest\n    restart: unless-stopped\n"
        '    ports:\n      - "192.168.1.9:8080:8080"\n'
        '    environment:\n      WATCHTOWER_HTTP_API_UPDATE: "true"\n'
        '      WATCHTOWER_HTTP_API_TOKEN: x\n      WATCHTOWER_HTTP_API_PERIODIC_POLLS: "true"\n',
    )
    r, out = run_patch(tmp_path, other, swap="0")
    assert r.returncode == 0, r.stderr
    block = _watchtower_block(out)
    assert 'WATCHTOWER_HTTP_API_UPDATE: "true"' in block
    assert "WATCHTOWER_HTTP_API_TOKEN: ${WATCHTOWER_HTTP_API_TOKEN}" in block
    assert '- "192.168.1.9:8080:8080"' in block
    # der fremde Service bleibt unangetastet (Token-Wert x)
    assert "WATCHTOWER_HTTP_API_TOKEN: x" in out


def test_missing_watchtower_block_fails_loudly(tmp_path):
    r, out = run_patch(tmp_path, "services:\n  app:\n    image: x\n")
    assert r.returncode != 0
    assert "watchtower" in r.stderr
    assert out == "services:\n  app:\n    image: x\n"


@pytest.mark.parametrize("swap", ["0", "1"])
def test_swap_flag_only_touches_containrrr(tmp_path, swap):
    already = BASE.replace(
        "image: containrrr/watchtower:latest", "image: nickfedor/watchtower:1.17.2"
    )
    r, out = run_patch(tmp_path, already, swap=swap)
    assert r.returncode == 0, r.stderr
    assert "image" not in r.stdout.split("compose:")[1]
    assert "nickfedor/watchtower:1.17.2" in _watchtower_block(out)
