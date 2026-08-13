# ADZA CI Flake Radar — observe-only pytest plugin.
#
# Detects TRUE flakes: a test that failed an attempt, got rerun by
# pytest-rerunfailures, and then finished GREEN (the whole test passed).
#
# EMPIRICALLY GROUNDED (pytest 9.1.1 + pytest-rerunfailures 16.4): the rerun
# signal does NOT appear in --junitxml (verified xunit1 + xunit2 — a recovered
# test is a clean <testcase>). It IS visible via pytest_runtest_logreport as
# outcome == "rerun" followed by a final outcome. So we listen at the source.
#
# Module name is deliberately unique (_adza_ci_flake_radar) so `-p` can never
# shadow an app-local module. It ONLY observes — every hook is exception-isolated
# and none change pytest's exit status, so it can never turn a green shard red.
import json
import os
import sys

_reruns = {}  # nodeid -> number of rerun reports (any phase)
_call_passed = set()  # nodeid -> the call phase finished "passed"
_failed = set()  # nodeid -> a real (non-rerun) failure in ANY phase


def pytest_runtest_logreport(report):
    # pytest-rerunfailures relabels each failed attempt as outcome "rerun", then
    # emits a FINAL report with the real outcome. A test is only a flake if it
    # recovered: it was rerun, its call passed, and NO phase ended in a genuine
    # failure (a permanent setup/teardown failure ⇒ the test is red, not flaky).
    try:
        nid = report.nodeid
        if report.outcome == "rerun":
            _reruns[nid] = _reruns.get(nid, 0) + 1
        elif report.outcome == "failed":
            _failed.add(nid)
        elif report.outcome == "passed" and report.when == "call":
            _call_passed.add(nid)
    except Exception as e:  # never let an observer break the run
        print(f"::warning::flake radar logreport: {e}", file=sys.stderr)


def pytest_sessionfinish(session, exitstatus):
    try:
        out = os.environ.get("FLAKE_OUT")
        if not out:
            return
        shard = os.environ.get("FLAKE_SHARD", "")
        flaky = [
            {"nodeid": nid, "reruns": n, "shard": shard}
            for nid, n in sorted(_reruns.items())
            if n > 0 and nid in _call_passed and nid not in _failed
        ]
        payload = {
            "shard": shard,
            "flaky": flaky,
            "flaky_count": len(flaky),
            "total_reruns": sum(_reruns.values()),
            # TIA-observe cross-check: exact failed nodeids let test-results verify
            # whether the would-have-selected test set contains every red test.
            "failed": sorted(_failed),
        }
        with open(out, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
    except Exception as e:  # observe-only guarantee: nothing escapes this hook
        print(f"::warning::flake radar could not write report: {e}", file=sys.stderr)
