# Repository Guidelines

## Project Structure & Module Organization

This repository publishes a composite GitHub Action for running OpenCode in GitHub Actions. The action contract, inputs, outputs, environment mappings, install steps, and `opencode github run` delegation live in `action.yml`. User-facing setup, examples, inputs, outputs, and secret requirements live in `README.md`. GitHub automation is under `.github/`, including `.github/workflows/ci.yml`, `.github/workflows/opencode.yml`, Dependabot, and Renovate configuration. Agent helper skills are under `.agents/skills/`. Bundled OpenCode agents/commands live under `.opencode/`, including `.opencode/scripts/resolve-app-token.sh`, a sourceable library the `/review-pr` command uses to resolve the OpenCode GitHub App token from git credential configuration, and `.opencode/opencode.jsonc`, which denies `external_directory` tool permission by default so a non-interactive CI run cannot hang on an unanswerable "ask" prompt, with a single narrow allow rule for `resolve-app-token.sh`'s own path so `/review-pr` can still source it from outside the checked-out repository once the toolkit is copied into a consumer's `~/.config/opencode` — both separate from the `.opencode/` tree that gets copied there. There is no package manager project or application source tree beyond these shell scripts.

## Build, Test, and Development Commands

There is no build step. Validate local changes with the repository QA script:

```bash
.agents/skills/local-qa/scripts/qa.sh
```

The script formats and lints the repository and mutates files in place: it runs `prettier --write` on markdown files, `yamllint` on tracked YAML, `shellcheck` on tracked shell scripts, `zizmor --fix=safe` and `actionlint` on `.github/workflows`, `checkov` across the repo, and every `bats` regression suite: `validate-opencode.bats` (validates `.opencode/` agent frontmatter, the agent references in `.opencode/commands/review-pr.md`, that `.opencode/opencode.jsonc` still parses once its `//` comments are stripped, and that its `external_directory` permission still allow-lists the exact resolver path `.opencode/commands/review-pr.md` sources behind a catch-all deny) and `test-resolve-app-token.bats` (App token candidate extraction from local, urlmatch, and includeIf/global-style git extraheader configurations with exact `github.com` host matching, `opencode-agent[bot]` identity verification via a stubbed `gh`, rejection of checkout-style/PAT-like credentials and malformed/non-JSON identity-probe responses that fail verification, resilience to a failing throwaway-review DELETE cleanup, fail-fast behavior when no token verifies, and preservation of the caller's explicit `use-github-token: true` workflow token — `opencode_prepare_gh_token` never overwrites it with an unverified candidate, and a verified `opencode-agent[bot]` candidate still takes precedence over it when one is found). Review the diff it produces before committing. For end-to-end testing, run the action from a temporary workflow or push a branch and reference it from a test repository workflow.

## Coding Style & Naming Conventions

Use YAML with two-space indentation for action and workflow files. Keep action inputs in `kebab-case`, matching existing names such as `use-github-token`, `oidc-base-url`, and `cache-hit`. Prefer explicit `bash -euo pipefail` shell declarations for composite steps. Keep third-party actions pinned by full commit SHA when practical, with a comment naming the intended upstream version.

## Testing Guidelines

Treat metadata and documentation checks as the primary test suite. When changing `action.yml`, update `README.md` in the same change if inputs, outputs, defaults, permissions, or secrets change. Run the QA script before submitting. When editing workflows, verify `.github/workflows/ci.yml` still covers the relevant checks.

## Commit & Pull Request Guidelines

Recent commits use short, focused, imperative subjects such as `improve action inputs and version handling`. Follow that style and keep each commit scoped to one behavior or documentation change. Pull requests should describe the action behavior changed, list any input or README updates, link related issues when available, and include workflow run links for CI or action-behavior changes.

## Security & Configuration Tips

Do not commit provider API keys, GitHub tokens, or generated credentials. Document required secrets in `README.md` and pass them through workflow `env`. If `use-github-token: true` is used, ensure the workflow grants the minimum required `GITHUB_TOKEN` permissions for the requested task.
