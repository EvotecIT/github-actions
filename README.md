Evotec Reusable GitHub Actions
================================

Goal
----
- One central place to maintain CI/CD for all your PowerShell modules and .NET libraries (e.g., DbaClientX.*).
- Keep per-repo YAML minimal while allowing custom tweaks via inputs.
- Ship the “only failed tests” experience, coverage artifacts, PSD1 refresh, and optional publishing.

What’s included
---------------
- Reusable workflows (call via `uses:`):
  - `.github/workflows/unified-ci.yml` – one-switch CI for .NET + PowerShell + Claude.
  - `.github/workflows/ci-dotnet.yml` – build/test/coverage for .NET.
  - `.github/workflows/ci-powershell.yml` – refresh PSD1 and run Pester (5.1/7).
  - `.github/workflows/release-dotnet.yml` – pack and push NuGet packages.
  - `.github/workflows/release-powershell.yml` – publish module to PowerShell Gallery.
  - `.github/workflows/review-claude.yml` – PR code review with Claude.
  - `.github/workflows/maintenance-cleanup.yml` – artifacts/cache cleanup core.

- Composite actions (reused internally and usable directly if needed):
  - `.github/actions/dotnet-test-summary` – print only failing .NET tests (TRX parser).
  - `.github/actions/pester-summary` – print only failing Pester tests.
  - `.github/actions/ps-refresh-psd1` – install PSPublishModule and refresh PSD1; optional commit.
  - `.github/actions/enforce-encoding` – check/fix encoding (e.g., `utf8NoBOM`).

Quick start (copy one file)
---------------------------
- Unified CI: see `templates/unified-ci.yml` or use directly in your repo with a single job calling:
  - `EvotecIT/github-actions/.github/workflows/unified-ci.yml@v1`
  - Minimal toggles: `run_tests`, `run_pester`, `collect_coverage`, `rebuild_psd1`, `summarize_failures`, `upload_artifacts`, and optional `claude_review` + `claude_model`.

- .NET CI: see `templates/ci-dotnet.yml` or use directly in your repo:

  - `.github/workflows/ci.yml`
    jobs.ci.uses: `evotecit/github-actions/.github/workflows/ci-dotnet.yml@main`

- PowerShell Module CI: see `templates/ci-powershell.yml`.
- Releases: `templates/release-dotnet.yml`, `templates/release-powershell.yml`.
- Claude review: `templates/review-claude.yml`.
- Cleanup (scheduled): `templates/cleanup.yml`.

Templates (examples)
--------------------
- `templates/unified-ci-windows.yml` — Windows public runners, .NET + PowerShell.
- `templates/unified-ci-multi-os.yml` — Simple three-job layout (Windows/Ubuntu/macOS) without matrix.
- `templates/unified-ci-selfhosted.yml` — Self-hosted Windows labels.
- `templates/unified-ci-powershell-only.yml` — PowerShell-only with PSD1 refresh.
- `templates/unified-ci-dotnet-only.yml` — .NET-only with multi-SDK + Codecov.
- `templates/unified-ci-pr-claude.yml` — PR-only with Claude review enabled.
- `templates/unified-ci-pr-summary-comment.yml` — PR sticky failing-tests comment (no Issues needed).

Key inputs (high level)
-----------------------
- Unified CI (`.github/workflows/unified-ci.yml`):
  - `run_tests` (bool) – run .NET tests; `dotnet_versions` JSON; `frameworks` JSON; `solution` glob or path.
  - `build_configuration` for .NET build/test (default `Debug`).
  - `run_pester` (bool) – run Pester; optional `test_script`; `ps_versions` JSON.
  - `rebuild_psd1` (bool) – refresh manifest via PSPublishModule; `module_manifest`, `build_script`.
  - `collect_coverage`, `summarize_failures`, `upload_artifacts`, `runs_on` JSON.
  - `enable_codecov` + `codecov_token`/`secrets.CODECOV_TOKEN`.
  - `claude_review` (bool), `claude_model`, `claude_prompt`, `claude_use_sticky_comment` (default true).
  - Failing-tests comment options (default off):
    - `post_summary_issue`: true/false to enable posting.
    - `post_summary_destination`: 'issue' or 'pr' (default 'issue').
    - `sticky_summary_comment`: true/false (default true) – reuse/update the same comment via a hidden marker.
    - `summary_comment_tag`: custom marker; default 'evotec-ci-summary'.
    - `summary_issue_title`, `summary_issue_label` – when destination is 'issue'.

- .NET CI (`.github/workflows/ci-dotnet.yml`):
  - `solution` (default `**/*.sln`), `dotnet_versions` JSON (e.g. `["8.0.x"]`), `os` JSON (e.g. `["windows-latest"]`).
  - `frameworks` JSON to test specific TFMs (empty = test all in solution).
  - `summarize_failures` true/false – prints only failed tests on failure.
  - `enable_codecov` true/false and `codecov_token`/`secrets.CODECOV_TOKEN` if needed.

- PowerShell CI (`.github/workflows/ci-powershell.yml`):
  - `module_manifest` and `build_script` (defaults to `Module/Build/Build-Module.ps1`).
  - `commit_psd1` true/false – commit refreshed manifest (safe for pushes and same-repo PRs).
  - `ps_versions` JSON (e.g. `["5.1","7"]`) and `runs_on` JSON (e.g. `["windows-latest"]`).
  - Optional `solution` to build .NET bits before tests, and optional `test_script` to run custom tests.

- .NET Release (`.github/workflows/release-dotnet.yml`):
  - Packs all csproj (excluding `*.Tests`) by default and pushes to `nuget_source`.
  - Version is taken from tag `v1.2.3` or override via `version`.

- PowerShell Release (`.github/workflows/release-powershell.yml`):
  - Runs your build script and calls `Publish-Module` from `publish_from_path`.

Runner flexibility
------------------
- All reusable workflows accept `runs_on` as JSON, so you can use GitHub-hosted (e.g. `["windows-latest"]`) or self-hosted (e.g. `["self-hosted","windows"]`).

“Only failed tests” experience
------------------------------
- .NET: TRX parsing via `.github/actions/dotnet-test-summary` prints only failing tests to logs and the job Summary on failures.
- PowerShell: NUnit XML parsing via `.github/actions/pester-summary`.

Encoding checks
---------------
- Use `.github/actions/enforce-encoding` to check or fix encodings across files. Example step:

  - name: Enforce utf8NoBOM
    uses: evotecit/github-actions/.github/actions/enforce-encoding@main
    with:
      patterns: |
        **/*.ps1
        **/*.psm1
        **/*.psd1
      mode: check
      encoding: utf8NoBOM

Secrets
-------
- NuGet: `NUGET_API_KEY` for `.NET` release.
- PowerShell Gallery: `PSGALLERY_API_KEY` for module release.
- Claude review: `CLAUDE_CODE_OAUTH_TOKEN`.

Migration from per-repo YAML
----------------------------
- Replace your custom test/build steps with a `uses:` call to the matching reusable workflow and pass the key inputs.
- Keep any repo-specific logic (special scripts, extra checks) in separate steps before/after the `uses:` call.

Notes
-----
- Pin to a tag (e.g. `@v1`) once you create a release of this repo for extra safety.
- If your `Build-Module.ps1` in `PSPublishModule` already handles encoding or manifest generation, continue using it; the CI wraps around those semantics.
