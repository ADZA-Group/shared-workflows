#!/usr/bin/env python3
"""Caller-Vertragswaechter (2026-09-04): jeder Fleet-Caller uebergibt nur Inputs/Secrets, die die
referenzierte Reusable auf dem lokalen Stand deklariert.

Ausloeser: v1.12.0 entfernte 20 Inputs; der rechnungsapp-Caller uebergab noch `enable-ghcr-prune`
und lief nach dem @v1-Move in startup_failure (Run 33858079440) — ohne Log, ohne Job. Dieser
Check laeuft lokal (braucht `gh` mit Repo-Lesezugriff) VOR jedem Release, das Inputs entfernt:

    python scripts/check_callers.py            # alle Fleet-Repos, dev + main
    python scripts/check_callers.py --ref dev  # nur ein Ref

Exit 1 bei unbekannten Inputs/Secrets oder nicht lesbaren Callern.
"""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
# Repo -> erwartete Refs (GEMESSEN 2026-09-04). Statisch, weil GitHub fehlenden Zugriff auf private
# Repos als HTTP 404 maskiert (Codex-Fund Runde 2): ein 404 auf einem ERWARTETEN Ref ist ein Problem,
# kein "Ref gibt es halt nicht". Neues Repo / neuer Branch = Eintrag hier.
FLEET = {
    "ADZA-Group/rechnungsapp": ["dev", "main"],
    "ADZA-Group/recyclage-app": ["dev", "main"],
    "ADZA-Group/footballapp": ["dev", "main"],
    "ADZA-Group/jarvis": ["dev", "main"],
    "ADZA-Group/adza-website": ["dev", "main"],
    "ADZA-Group/paperless": ["dev", "main"],
    "ADZA-Group/cloudflare": ["main"],
    "azad-ahmed/MitarbeiterApp": ["dev", "main"],
}
PREFIX = "adza-group/shared-workflows/.github/workflows/"


class NotFound(Exception):
    """Bestaetigtes HTTP 404 (Ref oder Datei existiert nicht) — der einzige Fehler, der uebersprungen wird."""


def gh_json(path: str):
    """gh api <path> als JSON. Codex-Fund (04.09.): jeder andere Fehler (Auth abgelaufen, Netz, Rechte,
    kaputtes JSON) muss ein Problem sein, sonst meldet der Waechter bei Ausfall falsch-gruen."""
    try:
        r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    except FileNotFoundError as e:
        raise RuntimeError(f"gh nicht gefunden: {e}") from e
    if r.returncode != 0:
        if "HTTP 404" in r.stderr:
            raise NotFound(path)
        raise RuntimeError(f"gh api {path}: rc={r.returncode} {r.stderr.strip()[:200]}")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"gh api {path}: kein JSON ({e})") from e


def contract(name: str) -> tuple[set[str], set[str]] | None:
    f = WORKFLOWS / name
    if not f.exists():
        return None
    wf = yaml.safe_load(f.read_text(encoding="utf-8"))
    on = wf.get("on") or wf.get(True)
    call = (on or {}).get("workflow_call") or {}
    return set(call.get("inputs") or {}), set(call.get("secrets") or {})


def check_caller(repo: str, ref: str, path: str, text: str) -> list[str]:
    problems: list[str] = []
    try:
        y = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return [f"{repo}@{ref}:{path}: YAML-Fehler {e}"]
    for job, spec in ((y or {}).get("jobs") or {}).items():
        uses = str((spec or {}).get("uses", ""))
        if not uses.lower().startswith(PREFIX):
            continue
        name = uses[len(PREFIX):].split("@", 1)[0]
        c = contract(name)
        if c is None:
            problems.append(f"{repo}@{ref}:{path} job {job}: referenziert {name}, das lokal nicht existiert")
            continue
        inputs, secrets = c
        bad_in = sorted(set((spec.get("with") or {}).keys()) - inputs)
        sec = spec.get("secrets")
        bad_sec = sorted(set(sec.keys()) - secrets) if isinstance(sec, dict) else []
        if bad_in:
            problems.append(f"{repo}@{ref}:{path} job {job} -> {name}: unbekannte Inputs {bad_in}")
        if bad_sec:
            problems.append(f"{repo}@{ref}:{path} job {job} -> {name}: unbekannte Secrets {bad_sec}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", action="append", help="nur diese Refs (Default: alle erwarteten je Repo)")
    args = ap.parse_args()
    problems: list[str] = []
    checked = 0
    for repo, expected in FLEET.items():
        for ref in expected:
            if args.ref and ref not in args.ref:
                continue
            try:
                listing = gh_json(f"repos/{repo}/contents/.github/workflows?ref={ref}")
            except NotFound:
                problems.append(f"{repo}@{ref}: erwarteter Ref fehlt oder kein Zugriff (HTTP 404)")
                continue
            except RuntimeError as e:
                problems.append(f"{repo}@{ref}: nicht lesbar — {e}")
                continue
            for entry in listing:
                if not entry["name"].endswith((".yml", ".yaml")):
                    continue
                try:
                    blob = gh_json(f"repos/{repo}/contents/{entry['path']}?ref={ref}")
                except (NotFound, RuntimeError) as e:
                    problems.append(f"{repo}@{ref}:{entry['path']}: nicht lesbar — {e}")
                    continue
                text = base64.b64decode(blob["content"]).decode("utf-8", "replace")
                if PREFIX not in text.lower():
                    continue
                checked += 1
                problems.extend(check_caller(repo, ref, entry["path"], text))
    if checked == 0:
        problems.append("0 Caller-Workflows geprueft — gh-Auth/Netz pruefen (ein leerer Lauf ist kein Beweis)")
    for p in problems:
        print(f"::error::{p}")
    print(f"check_callers: {checked} Caller-Workflows geprueft, {len(problems)} Problem(e)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
