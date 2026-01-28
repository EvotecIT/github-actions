# AGENTS.md

This repo contains reusable GitHub Actions workflows and templates.

Guidelines
- Prefer updating templates in `templates/` and reusable workflows in `.github/workflows/` instead of per-repo YAML.
- Keep inputs stable and backward-compatible; document new inputs in `README.md`.
- When adding new workflow inputs, wire them through to environment variables explicitly.
- Avoid secrets in templates; use `secrets:` in reusable workflows only.
- Use PowerShell only when required; default to bash for cross-platform steps.
- Keep YAML minimal and readable; preserve existing naming conventions.

Testing
- Validate YAML syntax and required inputs manually; there are no automated tests in this repo.
