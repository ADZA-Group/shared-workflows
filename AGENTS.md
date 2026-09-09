# AGENTS.md — shared-workflows (ADZA-Group Unified CI)

Reusable GitHub Actions workflows + composite actions consumed by 6 ADZA app repos.
One canonical `reusable-ci.yml` orchestrator replaces the per-app pipelines. Branch: `dev`.

## What lives here
- `.github/workflows/reusable-*.yml` — reusable (`workflow_call`) pipelines. `reusable-ci.yml` is the 1188-line orchestrator.
- `.github/workflows/_smoke-*.yml` — `workflow_dispatch` smoke harnesses that exercise the reusables. Runner varies per harness, see "Validate a change".
- `.github/actions/*/action.yml` — composites (setup-python-deps, run-pytest-shard, coverage-gate, start-app, opa-policy, health-check).

## Validate a change
- YAML: `yamllint -d relaxed <file>` (pip install yamllint if missing).
- Actions: `actionlint <file>` (Go tool; `go install github.com/rhysd/actionlint/cmd/actionlint@latest` if missing).
- Logic smoke: add a temp `push:[dev]` trigger to the right `_smoke-*` harness, push, `gh run watch <id> --exit-status`, then remove the temp trigger.
- **Check the harness's own `runs-on` before assuming a runner.** Most harnesses take a `runner-label` input you can set to `'["ubuntu-latest"]'`, but `_smoke-composites.yml` is hardcoded to `[self-hosted, linux, proxmox]`; its ubuntu counterpart is the separate file `_smoke-composites-ubuntu.yml`.
- **A smoke does NOT exercise a composite or sub-reusable you just changed.** `reusable-ci.yml` pulls them in by `@v1` (14 internal refs), i.e. the released state — your branch's version is never loaded, so the run is green on code you did not touch. Use `scripts/smoke-release.sh`: it bends the internal refs to the current branch, pushes, and restores them via `trap` even on Ctrl-C or error. Never bend them by hand — a forgotten restore ships a broken `@v1` to every consuming repo.

## Hard rules (do not violate)
- **Commit identity via `-c` only, never `git config`**: `git -c user.name="$(git log -1 --format=%an)" -c user.email="$(git log -1 --format=%ae)" commit …`.
- **The `@v1` tag is a shared release pointer moved ONLY by the human** via `scripts/release-v1.sh`. Agents never move it / never `git tag -f v1`.
- **`uses: ./…` inside a reusable resolves against the CALLER repo**, not this one → reference siblings by full path `adza-group/shared-workflows/.github/…@<ref>` (literal ref, no `${{ }}`).
- **A called workflow's GITHUB_TOKEN cannot exceed the caller's** → over-claiming a permission = `startup_failure`. Permissions pass through every caller layer.
- Internal refs of the reusables float on `@v1` (not @dev/exact) → no drift.

## Role in pair-work (Codex ⇄ Claude)
See `~/.codex/AGENTS.md` §6. You review anything that changes logic; stay silent on pure formatting. Disagreement is settled by a reproducible failing example, not opinion.
