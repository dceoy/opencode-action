# Repository Guidelines

## Project Structure & Module Organization

This repository publishes a composite GitHub Action for running OpenCode in GitHub Actions. The action contract, inputs, outputs, environment mappings, install steps, and `opencode github run` delegation live in `action.yml`. User-facing setup, examples, inputs, outputs, and secret requirements live in `README.md`. GitHub automation is under `.github/`, including `.github/workflows/ci.yml`, `.github/workflows/opencode.yml`, Dependabot, and Renovate configuration. Agent helper skills are under `.agents/skills/`. There is no application source tree, package manager project, or dedicated test fixture directory.

## Build, Test, and Development Commands

There is no build step. Validate local changes with the repository QA script:

```bash
.agents/skills/local-qa/scripts/qa.sh
```

The script checks core action metadata and README examples, including the composite action declaration, `opencode github run`, and documented usage. For end-to-end testing, run the action from a temporary workflow or push a branch and reference it from a test repository workflow.

## Coding Style & Naming Conventions

Use YAML with two-space indentation for action and workflow files. Keep action inputs in `kebab-case`, matching existing names such as `use-github-token`, `oidc-base-url`, and `cache-hit`. Prefer explicit `bash -euo pipefail` shell declarations for composite steps. Keep third-party actions pinned by full commit SHA when practical, with a comment naming the intended upstream version.

## Testing Guidelines

Treat metadata and documentation checks as the primary test suite. When changing `action.yml`, update `README.md` in the same change if inputs, outputs, defaults, permissions, or secrets change. Run the QA script before submitting. When editing workflows, verify `.github/workflows/ci.yml` still covers the relevant checks.

## Commit & Pull Request Guidelines

Recent commits use short, focused, imperative subjects such as `improve action inputs and version handling`. Follow that style and keep each commit scoped to one behavior or documentation change. Pull requests should describe the action behavior changed, list any input or README updates, link related issues when available, and include workflow run links for CI or action-behavior changes.

## Security & Configuration Tips

Do not commit provider API keys, GitHub tokens, or generated credentials. Document required secrets in `README.md` and pass them through workflow `env`. If `use-github-token: true` is used, ensure the workflow grants the minimum required `GITHUB_TOKEN` permissions for the requested task.
