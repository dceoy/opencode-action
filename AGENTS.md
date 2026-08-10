# Repository Guidelines

## Project Structure & Module Organization

This repository publishes a composite GitHub Action for running OpenCode in GitHub Actions. `action.yml` defines the action contract, inputs, outputs, install flow, environment mappings, and `opencode github run` delegation. User-facing setup and examples live in `README.md` and `docs/`. GitHub automation is under `.github/`.

Reusable local QA skills live under `.agents/skills/`. Composite-step entrypoints and sourceable libraries live under `scripts/`. The bundled OpenCode toolkit lives under `.opencode/`: `.opencode/opencode.jsonc` is the bundled provider/model registry and permission policy; `.opencode/commands/review-pr.md` is a thin compatibility wrapper that routes `/review-pr` to `review-pr-orchestrator`; that orchestrator loads the canonical `.opencode/skills/pr-review/SKILL.md` and delegates to approved reviewer agents under `.opencode/agents/`.

Trusted PR review helpers live under `.opencode/scripts/` in the action bundle and are installed into `~/.config/opencode/scripts/`. `review-pr-gh.sh` performs constrained GitHub reads, `review-pr-submit.sh` validates and submits structured reviews, `review-pr-context.sh` centralizes trusted repository/PR/head-SHA validation for both helpers, and `resolve-app-token.sh` resolves and verifies review credentials. OpenCode directly invokes only the fixed read/submission helpers; their source-only libraries are loaded from installed sibling paths and are not separately exposed through broader shell permissions. The review payload state is restricted to `~/.config/opencode/review-state/`.

## Build, Test, and Development Commands

There is no build step. Validate local changes with the repository QA script:

```bash
.agents/skills/local-qa/scripts/qa.sh
```

The script formats and lints the repository and can mutate files in place: it runs Prettier on tracked documentation/config formats, yamllint on tracked YAML, shfmt and ShellCheck on tracked shell/Bats files, zizmor and actionlint on GitHub Actions, Checkov across the repository, and every tracked `*.bats` suite discovered through `git ls-files`. Review the resulting diff before committing. CI also runs the shell, GitHub Actions, Bats, and CodeQL checks through the reusable workflows in `.github/workflows/ci.yml`.

## Coding Style & Naming Conventions

Use YAML with two-space indentation for action and workflow files. Keep action inputs in `kebab-case`, matching existing names such as `use-github-token`, `oidc-base-url`, and `cache-hit`. Prefer explicit `bash -euo pipefail` shell declarations for composite steps. Keep third-party actions pinned by full commit SHA when practical, with a comment naming the intended upstream version.

Keep review plumbing small and fail closed. Reuse the shared trusted-context helper instead of duplicating event/repository/head validation. Do not add repository-relative fallbacks for trusted review helpers, and do not broaden orchestrator shell or external-directory permissions to make a helper easier to call.

## Testing Guidelines

When changing `action.yml`, update `README.md` in the same change if inputs, outputs, defaults, permissions, or secrets change. Review-routing changes must update the skill, orchestrator allow-list, agent files, regression tests, and user documentation together. Trusted-context changes must cover valid event parsing, repository/PR mismatches, stale heads, and the second live-head check around token verification. Run the full QA script before submitting.

## Commit & Pull Request Guidelines

Use short, focused, imperative commit subjects. Keep each pull request scoped to one coherent behavior or maintenance objective. Pull requests should describe the behavior changed, security implications when relevant, documentation updates, validation performed, and linked issues.

## Security & Configuration Tips

Do not commit provider API keys, GitHub tokens, or generated credentials. Document required secrets in `README.md` and pass them through workflow `env`. If `use-github-token: true` is used, grant only the workflow permissions required by the requested task.

For `/review-pr`, the checkout, project OpenCode configuration, PR content, and unverified git credentials are untrusted. The runner host remains part of the trust boundary: managed OpenCode configuration, macOS MDM preferences, persisted authentication, and associated remote organization state can survive or override the action's project-level isolation. Keep the detailed precedence rules in `docs/custom-providers.md`; `docs/pull-request-reviews.md` documents the review-specific boundary and invariants.
