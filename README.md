# opencode-action

Enhanced GitHub Action to run OpenCode GitHub agent

[![CI](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml/badge.svg)](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml)

## Usage

Create `.github/workflows/opencode.yml` in the repository where you want OpenCode to respond to issue and pull request comments.
By default, the action exchanges the workflow OIDC token for an OpenCode GitHub App token, so the workflow must grant `id-token: write`.

```yaml
---
name: OpenCode
on:
  issue_comment:
    types:
      - created
  pull_request_review_comment:
    types:
      - created
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write
jobs:
  opencode:
    if: contains(github.event.comment.body, '/oc') || contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v7
        with:
          fetch-depth: 1
          persist-credentials: false
      - name: Run OpenCode
        uses: dceoy/opencode-action@v0
        env:
          OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
          GITHUB_TOKEN: ${{ github.token }}
        with:
          model: opencode-go/glm-5.2
```

Then comment `/opencode` or `/oc` on an issue, pull request, or pull request review comment.

`@v0` tracks the latest `v0.x.y` release. Pin to an exact release tag (e.g. `@v0.2.4`) or a full commit SHA for stricter supply-chain control.

## Inputs

| Input              | Required | Default                   | Description                                                                                                                                                    |
| ------------------ | -------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`            | Yes      |                           | Model to use, in `provider/model` format.                                                                                                                      |
| `agent`            | No       | `build`                   | OpenCode primary agent to use. Falls back to `default_agent` from config or `build` if not found.                                                              |
| `share`            | No       | `false`                   | Whether to share the OpenCode session.                                                                                                                         |
| `prompt`           | No       |                           | Custom prompt to override the default prompt.                                                                                                                  |
| `use-github-token` | No       | `false`                   | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.                                                                                            |
| `mentions`         | No       | `/opencode,/oc`           | Comma-separated trigger phrases, matched case-insensitively.                                                                                                   |
| `variant`          | No       |                           | Provider-specific model variant for reasoning effort, such as `high`, `max`, or `minimal`.                                                                     |
| `oidc-base-url`    | No       | `https://api.opencode.ai` | Base URL for OIDC token exchange. Override only for a custom GitHub App installation.                                                                          |
| `version`          | No       | `latest`                  | OpenCode version to install, such as `v1.2.3`; `latest` resolves the latest upstream release.                                                                  |
| `enable-toolkit`   | No       | `true`                    | Install the action's bundled `.opencode/` agents, commands, and skills into `~/.config/opencode` (global config) before running. Existing files are preserved. |

## Outputs

| Output             | Description                                     |
| ------------------ | ----------------------------------------------- |
| `opencode-version` | OpenCode version resolved for this run.         |
| `cache-hit`        | Whether the OpenCode binary cache was restored. |

## Secrets

Set the API key required by the selected model provider, for example:

- `OPENCODE_API_KEY` for OpenCode models
- `OPENROUTER_API_KEY` for OpenRouter models
- `ANTHROPIC_API_KEY` for Anthropic models
- `OPENAI_API_KEY` for OpenAI models

When `use-github-token: true`, pass `GITHUB_TOKEN` in `env` and grant the workflow enough permissions for the requested work.

## Pull Request Reviews

The bundled `/review-pr` command submits a GitHub pull request review through `gh api`. It uses inline review comments for every finding that can be safely anchored to the PR diff, and includes only unanchorable findings in the review body as summary-only fallback items when at least one inline comment is submitted. If no finding can be anchored inline, `/review-pr` returns a top-level markdown fallback instead. The surrounding `opencode github run` integration still posts the command's final text to the PR, so the command returns only a short status message after a successful inline review submission.

When the default OpenCode GitHub App flow is used (`use-github-token: false`), `/review-pr` restores the App token that OpenCode configured in the local Git extraheader and exports it for `gh`. Direct inline review submissions are therefore authored by `opencode-agent[bot]`. If the workflow explicitly opts into `use-github-token: true`, `/review-pr` falls back to the workflow token and direct review submissions may appear as `github-actions[bot]`.

Workflows that invoke `/review-pr` must provide:

- `pull-requests: write` permission
- `GH_TOKEN: ${{ github.token }}` or `GITHUB_TOKEN: ${{ github.token }}` for `gh pr diff`, `gh pr view`, and `gh api` review submission when using `use-github-token: true`; with the default App-token flow, `/review-pr` prefers the OpenCode App token from Git config for `gh api`
- A valid API key for the selected model provider with available credits or quota

Example OpenCode step:

```yaml
- name: Run OpenCode review
  uses: dceoy/opencode-action@v0
  env:
    OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
  with:
    model: openrouter/openrouter/free
    prompt: /review-pr
```

### Review commands

The bundled toolkit combines Claude Code Action-style core reviewers with `pr-review-toolkit` specialty agents. Use `/review-pr` with any of the following aspect keywords:

| Command                           | What runs                                                                                                                                                                                                                                                                                                               |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/review-pr` or `/review-pr all`  | Core reviewers (`code-quality-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, `security-code-reviewer`, `code-reviewer`) plus specialty agents (`pr-test-analyzer`, `silent-failure-hunter`, `comment-analyzer`, `type-design-analyzer`) when triggered by diff content |
| `/review-pr security performance` | `security-code-reviewer`, `performance-reviewer`                                                                                                                                                                                                                                                                        |
| `/review-pr tests docs`           | `test-coverage-reviewer`, `pr-test-analyzer`, `documentation-accuracy-reviewer`                                                                                                                                                                                                                                         |
| `/review-pr code`                 | `code-reviewer`, `code-quality-reviewer`                                                                                                                                                                                                                                                                                |
| `/review-pr quality`              | `code-quality-reviewer`                                                                                                                                                                                                                                                                                                 |
| `/review-pr coverage`             | `test-coverage-reviewer`, `pr-test-analyzer`                                                                                                                                                                                                                                                                            |
| `/review-pr documentation`        | `documentation-accuracy-reviewer`                                                                                                                                                                                                                                                                                       |
| `/review-pr errors`               | `silent-failure-hunter`                                                                                                                                                                                                                                                                                                 |
| `/review-pr comments`             | `comment-analyzer`                                                                                                                                                                                                                                                                                                      |
| `/review-pr types`                | `type-design-analyzer`                                                                                                                                                                                                                                                                                                  |
| `/review-pr simplify`             | `code-simplifier` — refinement only, does not return a review                                                                                                                                                                                                                                                           |

#### Core reviewers (Claude Code Action-compatible)

- **`code-quality-reviewer`** — general quality, maintainability, edge cases, robustness, type safety
- **`test-coverage-reviewer`** — missing critical test scenarios, brittle tests, error coverage gaps
- **`documentation-accuracy-reviewer`** — README, API docs, docstrings, examples vs. implementation

#### Specialty reviewers (pr-review-toolkit style)

- **`code-reviewer`** — project-guideline compliance (AGENTS.md), bugs, and quality
- **`performance-reviewer`** — algorithmic complexity, N+1, resource leaks
- **`security-code-reviewer`** — trust boundaries, injection, secrets, auth/authz
- **`pr-test-analyzer`** — behavioral test coverage and critical coverage gaps
- **`silent-failure-hunter`** — silent failures, broad catch blocks, fallback logic
- **`comment-analyzer`** — comment accuracy, completeness, and comment rot
- **`type-design-analyzer`** — type invariants, encapsulation, and design quality

Findings are normalized, deduplicated across agents, and validated against the PR diff before being posted. Diff-anchorable findings are submitted as GitHub inline review comments. When inline comments are submitted, findings that cannot be safely anchored remain in the GitHub review body with an explicit fallback reason. When no inline anchors are available, the command returns a top-level fallback response instead.

## Examples

Explain an issue:

```text
/opencode explain this issue
```

Fix an issue and open a pull request:

```text
/opencode fix this
```

Request a change on a pull request:

```text
Delete the attachment from S3 when the note is removed /oc
```

Request a change on specific code lines from the pull request Files tab:

```text
/oc add error handling here
```
