# ADZA-Group Shared Workflows

Reusable CI/CD workflows and composite actions for all ADZA-Group repositories.

## Reusable Workflows

| Workflow | Purpose |
|----------|---------|
| `reusable-notify.yml` | Discord / Slack / Telegram alerts |
| `reusable-security-scan.yml` | gitleaks, Bandit, Semgrep, Trivy, pip-audit |
| `reusable-docker-build.yml` | Buildx + Trivy scan + SBOM + size gate |

## Composite Actions

| Action | Purpose |
|--------|---------|
| `setup-python-env` | Python + pip + optional system deps |
| `health-check` | Endpoint polling + security header validation |
