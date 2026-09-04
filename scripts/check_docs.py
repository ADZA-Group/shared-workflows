#!/usr/bin/env python3
"""Doku-Drift-Waechter (Etappe D, 2026-09-04): README-Input-Tabelle == reusable-ci-Inputs.

Drei Doku-Luegen an einem Tag (Audit 04.09.: „always advisory", „bandit ALWAYS", Input-Tabelle
ohne neue Inputs) waren der Ausloeser. Regel: jeder Input von reusable-ci.yml steht in der
README-Tabelle (`| `name` |` oder `| `a` / `b` |`), und jede Tabellenzeile nennt nur existierende
Inputs. Laeuft im actionlint-Gate; Exit 1 bei Drift.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github" / "workflows" / "reusable-ci.yml"
README = ROOT / "README.md"


def main() -> int:
    wf = yaml.safe_load(WF.read_text(encoding="utf-8"))
    on = wf.get("on") or wf.get(True)
    inputs = set(on["workflow_call"]["inputs"])
    text = README.read_text(encoding="utf-8")
    # Nur die Tabelle unter "### Key inputs (`reusable-ci.yml`)" bis zur naechsten Ueberschrift;
    # andere Tabellen (Composites, Frontend-Lane) dokumentieren andere Vertraege.
    m = re.search(
        r"^### Key inputs \(`reusable-ci\.yml`\)\n(.*?)(?=^#{2,3} )", text, re.S | re.M
    )
    if not m:
        print("::error::README: Abschnitt '### Key inputs (`reusable-ci.yml`)' fehlt")
        return 1
    documented: set[str] = set()
    for line in m.group(1).splitlines():
        if not line.startswith("| `"):
            continue
        first_cell = line.split("|")[1]
        documented.update(re.findall(r"`([a-z0-9-]+)`", first_cell))
    missing = sorted(inputs - documented)
    ghosts = sorted(documented - inputs)
    rc = 0
    if missing:
        print(
            f"::error::README: {len(missing)} reusable-ci-Input(s) nicht in der Tabelle: {', '.join(missing)}"
        )
        rc = 1
    if ghosts:
        print(
            f"::error::README: Tabellenzeile(n) fuer nicht existierende Inputs: {', '.join(ghosts)}"
        )
        rc = 1
    print(
        f"check_docs: {len(inputs)} inputs, {len(documented)} dokumentiert, missing={len(missing)}, ghosts={len(ghosts)}"
    )
    return rc


if __name__ == "__main__":
    sys.exit(main())
