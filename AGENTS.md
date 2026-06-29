# Repository Guidelines

## Project Structure & Module Organization

This repository publishes a composite GitHub Action for running OpenCode from GitHub Actions. The main action definition is `action.yml`; keep all action inputs, environment mappings, and composite steps there. User-facing setup and examples live in `README.md`. CI and repository automation are under `.github/`, including `.github/workflows/ci.yml`, Dependabot, and Renovate configuration. Agent helper skills are stored under `.agents/skills/`. There is currently no application source tree or test fixture directory.

## Build, Test, and Development Commands

There is no package manager build step. Validate changes with the same checks used by CI:

```bash
test -f action.yml
grep -q '^runs:' action.yml
grep -q 'using: composite' action.yml
grep -q 'opencode github run' action.yml
test -f README.md
grep -q 'dceoy/opencode-action@main' README.md
grep -q 'model:' README.md
```

For local end-to-end testing, reference this checkout from a temporary workflow or use the README example with `uses: dceoy/opencode-action@main` after pushing changes to a branch.

## Coding Style & Naming Conventions

Use YAML for action and workflow configuration with two-space indentation. Prefer clear, snake_case input names matching existing inputs such as `use_github_token` and `oidc_base_url`. Keep shell snippets compatible with `bash` and use strict mode in workflows where possible (`bash -euo pipefail`). Pin third-party actions by full commit SHA in workflows when practical, and annotate the intended version in a comment.

## Testing Guidelines

Tests are metadata and documentation checks rather than unit tests. When changing `action.yml`, verify that required inputs, defaults, environment variables, and the `opencode github run` delegation remain documented in `README.md`. When editing workflows, ensure `.github/workflows/ci.yml` still passes the reusable GitHub Actions lint and scan workflow.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, lowercase subjects, for example `add opencode github action`. Follow that style and keep each commit focused. Pull requests should explain the action behavior changed, list any input or documentation updates, and link related issues when applicable. Include workflow screenshots or run links when changing CI behavior.

## Security & Configuration Tips

Do not commit provider API keys or GitHub tokens. Document required secrets in `README.md` and pass them through workflow `env`. Keep the default token path explicit: `use_github_token: true` requires `GITHUB_TOKEN` and suitable workflow permissions.
