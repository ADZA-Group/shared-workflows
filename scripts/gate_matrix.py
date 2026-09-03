#!/usr/bin/env python3
"""Deploy-Gate-Invariante fuer reusable-ci.yml (docker-build).

Liest den ECHTEN `if:`-Ausdruck und die `needs:` des docker-build-Jobs aus der
Workflow-Datei (kein handgeschriebenes Modell, das driften kann), uebersetzt den
GitHub-Expression-Teilsatz nach Python und prueft per Brute-Force:

    Ist ein hartes Gate `failure` oder `cancelled`, waehrend alle anderen
    Vorgaenger success/skipped sind, darf docker-build auf einem push NIE laufen.

Welche Gates hart sind, haengt vom Kontext ab (Risk-Gating, main/tags):
  immer hart .......... test-matrix, security, branch-policy, coverage, e2e, lint-python
  hart bei risky ...... lint-dockerfile, property-tests
  hart auf main/tags .. license-check
Sicherheitsnetz gegen vakuum-gruen: der Happy-Path (alles success, any_code) MUSS
auf push bauen. Exit 1 bei jedem Verstoss. Audit 2026-09-03, Funde A + X.
"""

from __future__ import annotations

import itertools
import pathlib
import re
import sys

import yaml

WF = (
    pathlib.Path(__file__).resolve().parents[1]
    / ".github"
    / "workflows"
    / "reusable-ci.yml"
)
RESULTS = ("success", "failure", "skipped", "cancelled")
OK = ("success", "skipped")
# Jedes harte Gate MUSS in docker-build.needs stehen — ein Gate, das fehlt, kann
# im if-Ausdruck gar nicht vorkommen (genau das war Fund A).
HARD_GATES = (
    "test-matrix",
    "security",
    "branch-policy",
    "coverage",
    "e2e",
    "lint-python",
    "lint-dockerfile",
    "property-tests",
    "license-check",
)
CHANGE_KEYS = ("light", "any_code", "docker", "ci", "risky")
EVENTS = ("push", "pull_request", "workflow_dispatch", "schedule")
REFS = ("refs/heads/main", "refs/heads/dev", "refs/tags/v1.2.3")


def to_python(expr: str) -> str:
    e = expr.strip()
    e = re.sub(r"^\$\{\{\s*|\s*\}\}$", "", e).strip()
    e = re.sub(r"needs\.changes\.outputs\.(\w+)", r"changes['\1']", e)
    e = re.sub(r"needs\.([\w-]+)\.result", r"needs['\1']", e)
    e = re.sub(r"inputs\.([\w-]+)", r"inputs['\1']", e)
    e = e.replace("github.event_name", "event").replace("github.ref", "ref")
    e = re.sub(r"startsWith\(([^,]+),\s*([^)]+)\)", r"(\1).startswith(\2)", e)
    e = e.replace("always()", "True").replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    # Gefalteter YAML-Block (>-) traegt Zeilenumbrueche: als EIN Ausdruck klammern.
    return "(" + " ".join(e.split()) + ")"


def is_hard(gate: str, changes: dict, ref: str) -> bool:
    if gate in (
        "test-matrix",
        "security",
        "branch-policy",
        "coverage",
        "e2e",
        "lint-python",
    ):
        return True
    if gate in ("lint-dockerfile", "property-tests"):
        return changes["risky"] == "true"
    if gate == "license-check":
        return ref == "refs/heads/main" or ref.startswith("refs/tags/")
    return False


def main() -> int:
    wf = yaml.safe_load(WF.read_text(encoding="utf-8"))
    job = wf["jobs"]["docker-build"]
    needs_names = [n for n in job["needs"] if n != "changes"]
    missing = [g for g in HARD_GATES if g not in needs_names]
    if missing:
        print(f"::error::harte Gates fehlen in docker-build.needs: {missing} (Fund A)")
        return 1
    code = compile(to_python(job["if"]), "docker-build.if", "eval")

    def runs(needs, changes, event, ref):
        # eval ist hier gewollt: Eingabe ist ausschliesslich der if-Ausdruck aus der
        # eigenen, versionierten Workflow-Datei (kein Fremd-Input), Namensraum leer.
        return bool(
            eval(
                code,
                {"__builtins__": {}},
                {
                    "needs": needs,
                    "changes": changes,
                    "event": event,
                    "ref": ref,
                    "inputs": {},
                },
            )
        )

    contexts = [
        (dict(zip(CHANGE_KEYS, flags)), event, ref)
        for flags in itertools.product(("true", "false"), repeat=len(CHANGE_KEYS))
        for event in EVENTS
        for ref in REFS
    ]

    # Sicherheitsnetz: Happy-Path muss bauen, sonst beweist die Matrix nichts.
    happy = {n: "success" for n in needs_names}
    happy_changes = {
        "light": "false",
        "any_code": "true",
        "docker": "true",
        "ci": "true",
        "risky": "false",
    }
    if not runs(happy, happy_changes, "push", "refs/heads/dev"):
        print("::error::Happy-Path baut nicht — Matrix waere vakuum-gruen")
        return 1

    # Positiv-Kontrolle je Gate: ein zulaessiges `skipped` (alle anderen success)
    # muss weiterhin bauen — sonst waere ein Gate still totgeschaltet (Codex R2).
    for gate in needs_names:
        needs = {n: "success" for n in needs_names}
        needs[gate] = "skipped"
        ch = dict(happy_changes, light="true" if gate == "security" else "false")
        if not runs(needs, ch, "push", "refs/heads/dev"):
            print(f"::error::zulaessiges skipped von {gate} blockiert den Build")
            return 1

    violations = 0
    checked = 0
    for gate in needs_names:
        others = [n for n in needs_names if n != gate]
        for bad in ("failure", "cancelled"):
            for vals in itertools.product(OK, repeat=len(others)):
                needs = dict(zip(others, vals))
                needs[gate] = bad
                for changes, event, ref in contexts:
                    if event != "push" or not is_hard(gate, changes, ref):
                        continue
                    checked += 1
                    if runs(needs, changes, event, ref):
                        violations += 1
                        if violations <= 12:
                            print(
                                f"VIOLATION {gate}={bad} ref={ref} changes={changes} others={needs}"
                            )
    print(f"docker-build needs: {needs_names}")
    print(f"checked={checked} violations={violations}")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
