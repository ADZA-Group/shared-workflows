# AGENTS.md — shared-workflows (ADZA-Group Unified CI)

Reusable GitHub Actions workflows + composite actions consumed by 6 ADZA app repos.
One canonical `reusable-ci.yml` orchestrator replaces the per-app pipelines. Branch: `dev`.

## What lives here
- `.github/workflows/reusable-*.yml` — reusable (`workflow_call`) pipelines. `reusable-ci.yml` is the 1188-line orchestrator.
- `.github/workflows/_smoke-*.yml` — `workflow_dispatch` smoke harnesses that exercise the reusables on ubuntu.
- `.github/actions/*/action.yml` — composites (setup-python-deps, run-pytest-shard, coverage-gate, start-app, opa-policy, health-check).

## Validate a change
- YAML: `yamllint -d relaxed <file>` (pip install yamllint if missing).
- Actions: `actionlint <file>` (Go tool; `go install github.com/rhysd/actionlint/cmd/actionlint@latest` if missing).
- Logic smoke on ubuntu: set `runner-label: '["ubuntu-latest"]'` in the `_smoke-*` caller + a temp `push:[dev]` trigger, push, `gh run watch <id> --exit-status`, then remove the temp trigger.

## Hard rules (do not violate)
- **Commit identity via `-c` only, never `git config`**: `git -c user.name="$(git log -1 --format=%an)" -c user.email="$(git log -1 --format=%ae)" commit …`.
- **The `@v1` tag is a shared release pointer moved ONLY by the human** via `scripts/release-v1.sh`. Agents never move it / never `git tag -f v1`.
- **`uses: ./…` inside a reusable resolves against the CALLER repo**, not this one → reference siblings by full path `adza-group/shared-workflows/.github/…@<ref>` (literal ref, no `${{ }}`).
- **A called workflow's GITHUB_TOKEN cannot exceed the caller's** → over-claiming a permission = `startup_failure`. Permissions pass through every caller layer.
- Internal refs of the reusables float on `@v1` (not @dev/exact) → no drift.

## Role in pair-work (Codex ⇄ Claude)
See `~/.codex/AGENTS.md` §6. You review anything that changes logic; stay silent on pure formatting. Disagreement is settled by a reproducible failing example, not opinion.
