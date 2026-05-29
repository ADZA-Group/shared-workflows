# Unified CI — Phase 3c: `reusable-frontend` (validatable now) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Checkbox (`- [ ]`) steps.

**Goal:** Build the frontend lane reusable (`reusable-frontend.yml`) needed by MitarbeiterApp + RecyclageApp, AND actually validate it **green** — it runs on `ubuntu-latest` (GitHub-hosted), which is NOT affected by the LXC-104 self-hosted dispatch block.

**Architecture:** A self-contained Node reusable (eslint + tsc + optional prettier + vitest + vite build + bundle-size gate). It uses `npm ci` when a lockfile exists, else `npm install` with a warning (gracefully handles MitarbeiterApp's missing lockfile). It depends on **none** of the Python composites under validation, so building + smoking it carries no risk to the blocked work. A minimal `tests/fixtures/frontend/` + `_smoke-frontend.yml` (ubuntu-hosted, temporary `push:[dev]` trigger) lets us prove it green.

**Tech Stack:** GitHub reusable workflow, `actions/setup-node@v6`, npm, eslint(flat)/typescript/vitest/vite, `actionlint`/`yamllint`.

**Spec:** `docs/superpowers/specs/2026-05-28-unified-ci-design.md` §5.2 (reusable-frontend).

## Pins (resolved 2026-05-28)
- `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4`
- `actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e  # v6.4.0`

## Environment & rules
- Work from `C:\Users\ADZArecaclage\Documents\Projekte\shared-workflows`, branch `dev`. npm 11 / node 24 available locally (for the fixture lockfile).
- Lint: `./bin/actionlint.exe <file>` (exit 0) + `python -m yamllint -d relaxed <file>` (or the yamllint.exe path).
- Git: NO `git config`; inline identity. Explicit `git add`. Conventional Commits.

---

### Task 1: Create `reusable-frontend.yml`

**Files:** Create `.github/workflows/reusable-frontend.yml`

- [ ] **Step 1: Write the file** (verbatim):

```yaml
# ═══════════════════════════════════════════════════════════════
# Reusable Frontend Lane — ADZA-Group
# eslint + tsc + (prettier) + vitest + vite build + bundle-size gate.
# Node toolchain — independent of the Python composites. Defaults to ubuntu-hosted.
# Install: npm ci when a lockfile exists, else npm install (+warning).
#
# Usage:
#   uses: adza-group/shared-workflows/.github/workflows/reusable-frontend.yml@v1
#   with: { frontend-dir: frontend }
# ═══════════════════════════════════════════════════════════════

name: "🎨 Frontend"

on:
  workflow_call:
    inputs:
      frontend-dir:
        required: false
        type: string
        default: "frontend"
      node-version:
        required: false
        type: string
        default: "20"
      runner-label:
        required: false
        type: string
        default: '["ubuntu-latest"]'
      run-lint:
        required: false
        type: boolean
        default: true
      run-typecheck:
        required: false
        type: boolean
        default: true
      run-format-check:
        required: false
        type: boolean
        default: false
      run-test:
        required: false
        type: boolean
        default: true
      run-build:
        required: false
        type: boolean
        default: true
      lint-script:
        required: false
        type: string
        default: "lint"
      typecheck-script:
        required: false
        type: string
        default: "typecheck"
      format-script:
        required: false
        type: string
        default: "format:check"
      test-script:
        required: false
        type: string
        default: "test"
      build-script:
        required: false
        type: string
        default: "build"
      build-output-dir:
        required: false
        type: string
        default: "dist"
      bundle-size-limit-kb:
        required: false
        type: number
        default: 0

permissions:
  contents: read

jobs:
  frontend:
    name: "🎨 Frontend Lane"
    runs-on: ${{ fromJSON(inputs.runner-label) }}
    timeout-minutes: 15
    defaults:
      run:
        working-directory: ${{ inputs.frontend-dir }}
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e  # v6.4.0
        with:
          node-version: ${{ inputs.node-version }}
          cache: npm
          cache-dependency-path: ${{ inputs.frontend-dir }}/package-lock.json

      - name: Install dependencies
        run: |
          if [ -f package-lock.json ]; then
            npm ci
          else
            echo "::warning::no package-lock.json — using 'npm install' (non-reproducible); commit a lockfile"
            npm install
          fi

      - name: Lint
        if: ${{ inputs.run-lint }}
        env:
          SCRIPT: ${{ inputs.lint-script }}
        run: npm run "$SCRIPT"

      - name: Typecheck
        if: ${{ inputs.run-typecheck }}
        env:
          SCRIPT: ${{ inputs.typecheck-script }}
        run: npm run "$SCRIPT"

      - name: Format check
        if: ${{ inputs.run-format-check }}
        continue-on-error: ${{ !(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) }}
        env:
          SCRIPT: ${{ inputs.format-script }}
        run: npm run "$SCRIPT"

      - name: Test
        if: ${{ inputs.run-test }}
        env:
          SCRIPT: ${{ inputs.test-script }}
        run: npm run "$SCRIPT"

      - name: Build
        if: ${{ inputs.run-build }}
        env:
          SCRIPT: ${{ inputs.build-script }}
        run: npm run "$SCRIPT"

      - name: Bundle size gate
        if: ${{ inputs.run-build && inputs.bundle-size-limit-kb > 0 }}
        env:
          OUT: ${{ inputs.build-output-dir }}
          LIMIT: ${{ inputs.bundle-size-limit-kb }}
        run: |
          if [ ! -d "$OUT" ]; then echo "::error::build output dir '$OUT' not found"; exit 1; fi
          TOTAL_KB=$(du -sk "$OUT" | cut -f1)
          {
            echo "## 🎨 Frontend bundle"
            echo "| Metric | Value |"
            echo "|--------|-------|"
            echo "| Build output | **${TOTAL_KB} KB** |"
            echo "| Limit | ${LIMIT} KB |"
          } >> "$GITHUB_STEP_SUMMARY"
          if [ "$TOTAL_KB" -gt "$LIMIT" ]; then
            echo "::error::bundle ${TOTAL_KB} KB > ${LIMIT} KB"; exit 1
          fi
```

- [ ] **Step 2:** `./bin/actionlint.exe .github/workflows/reusable-frontend.yml && python -m yamllint -d relaxed .github/workflows/reusable-frontend.yml` → exit 0.
- [ ] **Step 3:** Commit: `feat(frontend): add reusable-frontend lane (eslint/tsc/vitest/build + bundle gate, npm ci-or-install)`

---

### Task 2: Minimal fixture frontend

**Files (create under `tests/fixtures/frontend/`):**

- [ ] `package.json`:
```json
{
  "name": "smoke-frontend-fixture",
  "private": true,
  "type": "module",
  "scripts": {
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "build": "vite build"
  },
  "devDependencies": {
    "eslint": "^9.0.0",
    "typescript": "^5.4.0",
    "vite": "^5.4.0",
    "vitest": "^2.1.0"
  }
}
```

- [ ] `tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["vitest/globals"]
  },
  "include": ["src"]
}
```

- [ ] `eslint.config.js`:
```js
export default [
  { files: ["src/**/*.ts"], rules: {} }
];
```

- [ ] `vite.config.ts`:
```ts
import { defineConfig } from "vite";
export default defineConfig({ build: { outDir: "dist" } });
```

- [ ] `index.html`:
```html
<!doctype html>
<html><head><meta charset="utf-8"><title>fixture</title></head>
<body><div id="app"></div><script type="module" src="/src/main.ts"></script></body></html>
```

- [ ] `src/add.ts`:
```ts
export function add(a: number, b: number): number {
  return a + b;
}
```

- [ ] `src/add.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { add } from "./add";

describe("add", () => {
  it("sums", () => {
    expect(add(2, 3)).toBe(5);
  });
});
```

- [ ] `src/main.ts`:
```ts
import { add } from "./add";
document.getElementById("app")!.textContent = String(add(1, 2));
```

- [ ] **Generate the lockfile** (local, npm 11 available):
```bash
cd tests/fixtures/frontend && npm install --package-lock-only
```
Run: confirm `tests/fixtures/frontend/package-lock.json` exists.

- [ ] **Commit** the fixture (incl. the lockfile):
```bash
git add tests/fixtures/frontend/
git commit -m "test(frontend): minimal fixture frontend for reusable-frontend smoke"
```

---

### Task 3: Smoke caller (ubuntu-hosted, temporary push trigger)

**Files:** Create `.github/workflows/_smoke-frontend.yml`

- [ ] **Step 1: Write it** (note `push:[dev]` is TEMPORARY — reverted in Task 4 Step 4):
```yaml
# Smoke for reusable-frontend. Runs on ubuntu-hosted (NOT affected by the LXC-104
# self-hosted dispatch block), so it can validate GREEN now.
# The push:[dev] trigger is TEMPORARY (reverted after validation).
name: "🧪 Smoke — Frontend"

on:
  workflow_dispatch:
  push:
    branches: [dev]

permissions:
  contents: read

jobs:
  frontend:
    uses: ./.github/workflows/reusable-frontend.yml
    with:
      frontend-dir: tests/fixtures/frontend
      bundle-size-limit-kb: 2048
```

- [ ] **Step 2:** `./bin/actionlint.exe .github/workflows/_smoke-frontend.yml` → exit 0.
- [ ] **Step 3: Commit:** `ci(frontend): add _smoke-frontend (ubuntu-hosted, temp push trigger)`

---

### Task 4: Validate GREEN on ubuntu-hosted, then revert the trigger

- [ ] **Step 1:** `git push origin dev` → the `push:[dev]` trigger fires `_smoke-frontend` on `ubuntu-latest`.
- [ ] **Step 2:** Watch it: `gh run list --workflow=_smoke-frontend.yml --branch dev --limit 1 --json databaseId --jq '.[0].databaseId'` then `gh run watch <id> --exit-status`.
- [ ] **Step 3:** Confirm GREEN: the `frontend` job ran `npm ci` → lint → typecheck → vitest (1 test) → vite build → bundle gate, all passing. (If it fails, debug via `gh run view <id> --log-failed` — these are ubuntu-hosted, so the failure is real frontend logic, not the dispatch block.)
- [ ] **Step 4 (revert trigger):** once green, remove the `push:` block from `_smoke-frontend.yml` (back to `workflow_dispatch`-only), commit `ci(frontend): revert temp push trigger on _smoke-frontend (validated green)`, and push.

---

## Self-Review
**Spec coverage (§5.2 reusable-frontend):** eslint ✓, tsc ✓, prettier (optional) ✓, vitest ✓, vite build ✓, bundle-size gate ✓, npm-cache ✓, lockfile-handling (ci-or-install) ✓. Lighthouse deferred (needs a deployed URL — post-deploy, Phase 3b). **Placeholder scan:** none; pins concrete; fixture fully specified. **Consistency:** script-name inputs routed through `env` + quoted (matches the C1 injection-hardening fix); dual-gate on format-check matches the suite's pattern; `runner-label` via `fromJSON` consistent; `cache-dependency-path` is repo-root-relative (correct). **Independence:** uses only `checkout` + `setup-node` + npm — zero dependency on the under-validation Python composites, so this is safe to build + smoke now. **Validatable now:** runs `ubuntu-latest`, unaffected by the LXC-104 block.
