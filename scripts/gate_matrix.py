#!/usr/bin/env python3
"""Deploy-Gate-Invarianten fuer reusable-ci.yml.

Liest die ECHTEN `if:`-Ausdruecke und `needs:` der Deploy-Kette aus der
Workflow-Datei (kein handgeschriebenes Modell, das driften kann), uebersetzt den
GitHub-Expression-Teilsatz nach Python und prueft per Brute-Force.

Teil 1 — docker-build (Audit 2026-09-03, Funde A + X):
    Ist ein hartes Gate `failure` oder `cancelled`, waehrend alle anderen
    Vorgaenger success/skipped sind, darf docker-build auf einem push NIE laufen.
    immer hart .......... test-matrix, security, branch-policy, coverage, e2e, lint-python
    hart bei risky ...... lint-dockerfile, property-tests
    hart auf main/tags .. license-check

Teil 2 — Deploy-Kette (Stufe 4, 2026-09-04): verify-staging, promote-prod,
verify-prod duerfen nur laufen, wenn ihre harten Vorgaenger success sind:
    verify-staging  nur bei docker-build success UND push-Event UND enable-push
    promote-prod    nur bei docker-build success UND require-staging-green success
    verify-prod     nur bei docker-build success UND (promote success ODER
                    nicht-gated + promote skipped)

Sicherheitsnetze gegen vakuum-gruen: Happy-Paths MUESSEN laufen. Exit 1 bei
jedem Verstoss.
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


def compile_if(job: dict, name: str):
    return compile(to_python(job["if"]), f"{name}.if", "eval")


def evaluate(code, needs, changes, event, ref, inputs) -> bool:
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
                "inputs": inputs,
            },
        )
    )


def check_docker_build(wf: dict) -> int:
    job = wf["jobs"]["docker-build"]
    needs_names = [n for n in job["needs"] if n != "changes"]
    missing = [g for g in HARD_GATES if g not in needs_names]
    if missing:
        print(f"::error::harte Gates fehlen in docker-build.needs: {missing} (Fund A)")
        return 1
    code = compile_if(job, "docker-build")

    def runs(needs, changes, event, ref):
        return evaluate(code, needs, changes, event, ref, {})

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
    print(f"docker-build: checked={checked} violations={violations}")
    return 1 if violations else 0


def check_deploy_chain(wf: dict) -> int:
    """Stufe 4: verify-staging / promote-prod / verify-prod gegen ihre Vorgaenger."""
    jobs = wf["jobs"]
    codes = {
        n: compile_if(jobs[n], n)
        for n in ("verify-staging", "promote-prod", "verify-prod")
    }
    needs_of = {n: [x for x in jobs[n]["needs"]] for n in codes}
    input_space = [
        {
            "staging-url": su,
            "prod-url": pu,
            "deploy-prod": dp,
            "gated-promotion": gp,
            "enable-push": ep,
        }
        for su in ("", "https://staging/health")
        for pu in ("", "https://prod/health")
        for dp in (True, False)
        for gp in (True, False)
        for ep in (True, False)
    ]
    violations = 0
    checked = 0
    happy_seen = {n: False for n in codes}
    for inputs in input_space:
        for event in EVENTS:
            for ref in REFS:
                for res in itertools.product(RESULTS, repeat=4):
                    needs = dict(
                        zip(
                            (
                                "docker-build",
                                "verify-staging",
                                "require-staging-green",
                                "promote-prod",
                            ),
                            res,
                        )
                    )
                    chg = {"light": "false"}
                    run = {
                        n: evaluate(codes[n], needs, chg, event, ref, inputs)
                        for n in codes
                    }
                    checked += 1
                    # verify-staging: nur bei docker-build success, push-Event, enable-push
                    if run["verify-staging"] and not (
                        needs["docker-build"] == "success"
                        and event == "push"
                        and inputs["enable-push"]
                    ):
                        violations += 1
                        if violations <= 8:
                            print(
                                f"VIOLATION verify-staging needs={needs} event={event} inputs={inputs}"
                            )
                    # promote-prod: nur bei docker-build success + require-staging-green success
                    if run["promote-prod"] and not (
                        needs["docker-build"] == "success"
                        and needs["require-staging-green"] == "success"
                        and event == "push"
                        and ref == "refs/heads/main"
                    ):
                        violations += 1
                        if violations <= 8:
                            print(
                                f"VIOLATION promote-prod needs={needs} event={event} ref={ref} inputs={inputs}"
                            )
                    # verify-prod: nur bei docker-build success + (promote success | non-gated skipped)
                    # + push-Event + enable-push (Codex: schedule/dispatch auf main deployt nichts,
                    # ein Health-Flake haette sonst einen falschen Rollback ausgeloest)
                    if run["verify-prod"] and not (
                        needs["docker-build"] == "success"
                        and (
                            needs["promote-prod"] == "success"
                            or (
                                not inputs["gated-promotion"]
                                and needs["promote-prod"] == "skipped"
                            )
                        )
                        and ref == "refs/heads/main"
                        and event == "push"
                        and inputs["enable-push"]
                    ):
                        violations += 1
                        if violations <= 8:
                            print(
                                f"VIOLATION verify-prod needs={needs} ref={ref} inputs={inputs}"
                            )
                    for n in codes:
                        happy_seen[n] = happy_seen[n] or run[n]
    for n, seen in happy_seen.items():
        if not seen:
            print(
                f"::error::{n} laeuft in KEINER Konstellation — Invariante waere vakuum-gruen"
            )
            return 1
    print(f"deploy-chain needs: {needs_of}")
    print(f"deploy-chain: checked={checked} violations={violations}")
    return 1 if violations else 0


def check_require_staging_green(wf: dict) -> int:
    """Stufe 4 (Codex): das Gate sitzt im run:-Skript, nicht im if: — strukturell pruefen,
    sonst koennte das Skript entfernt werden, ohne dass diese Matrix rot wird."""
    job = wf["jobs"]["require-staging-green"]
    problems = []
    if list(job.get("needs", [])) != ["verify-staging"]:
        problems.append(f"needs != ['verify-staging']: {job.get('needs')}")
    cond = " ".join(str(job.get("if", "")).split())
    for must in (
        "inputs.staging-url != ''",
        "inputs.deploy-prod",
        "github.ref == 'refs/heads/main'",
        "github.event_name == 'push'",
    ):
        if must not in cond:
            problems.append(f"if: fehlt '{must}'")
    script = "\n".join(s.get("run", "") for s in job.get("steps", []))
    # EINE zusammenhaengende Regex (Codex R2): Vergleich, `then` und `exit 1` muessen im
    # selben if-Zweig liegen — zwei getrennte Treffer liessen `if … then echo; fi` +
    # `if false; then exit 1; fi` als fail-open durch.
    gate = re.compile(
        r'if\s+\[\s*"\$\{\{\s*needs\.verify-staging\.result\s*\}\}"\s*!=\s*"success"\s*\];\s*then'
        r"(?:(?!\bfi\b).)*?\bexit\s+1\b(?:(?!\bfi\b).)*?\bfi\b",
        re.S,
    )
    if not gate.search(script):
        problems.append(
            "run: kein if-Zweig `[ needs.verify-staging.result != success ] → … exit 1 … fi`"
        )
    for p in problems:
        print(f"::error::require-staging-green: {p}")
    print(
        f"require-staging-green: structural checks {'ok' if not problems else 'FAILED'}"
    )
    return 1 if problems else 0


def main() -> int:
    wf = yaml.safe_load(WF.read_text(encoding="utf-8"))
    rc = check_docker_build(wf)
    rc |= check_deploy_chain(wf)
    rc |= check_require_staging_green(wf)
    return rc


if __name__ == "__main__":
    sys.exit(main())
