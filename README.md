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
        uses: dceoy/opencode-action@main
        env:
          OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          model: opencode-go/glm-5.2
```

Then comment `/opencode` or `/oc` on an issue, pull request, or pull request review comment.

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
| `opencode-version` | OpenCode version resolved for the workflow run. |
| `cache-hit`        | Whether the OpenCode binary cache was restored. |

## Secrets

Set the API key required by the selected model provider, for example:

- `OPENCODE_API_KEY` for OpenCode models
- `OPENROUTER_API_KEY` for OpenRouter models
- `ANTHROPIC_API_KEY` for Anthropic models
- `OPENAI_API_KEY` for OpenAI models

When `use-github-token: true`, pass `GITHUB_TOKEN` in `env` and grant the workflow enough permissions for the requested work.

## Pull Request Reviews

The bundled `/review-pr` command posts reviews back to GitHub with `gh`. Workflows that invoke it must provide:

- `pull-requests: write`
- `issues: write` when falling back to `gh pr comment`
- `GH_TOKEN: ${{ github.token }}` or `GITHUB_TOKEN: ${{ github.token }}`
- A valid API key for the selected model provider with available credits or quota

Example OpenCode step:

```yaml
- name: Run OpenCode review
  uses: dceoy/opencode-action@main
  env:
    OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
    GH_TOKEN: ${{ github.token }}
  with:
    model: openrouter/openrouter/free
    prompt: /review-pr
```

### Review commands

The bundled toolkit combines Claude Code Action-style core reviewers with `pr-review-toolkit` specialty agents. Use `/review-pr` with any of the following aspect keywords:

| Command                           | What runs                                                                                                                                 |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `/review-pr` or `/review-pr all`  | All applicable reviewers: code quality, performance, tests, documentation, security, plus specialty agents when triggered by diff content |
| `/review-pr security performance` | Security and performance reviewers only                                                                                                   |
| `/review-pr tests docs`           | Test coverage and documentation accuracy reviewers                                                                                        |
| `/review-pr code`                 | Code reviewer (guidelines) and code-quality reviewer                                                                                      |
| `/review-pr quality`              | Code-quality reviewer (edge cases, robustness, type safety)                                                                               |
| `/review-pr coverage`             | Test-coverage reviewer and PR test analyzer                                                                                               |
| `/review-pr documentation`        | Documentation accuracy reviewer                                                                                                           |
| `/review-pr errors`               | Silent-failure hunter (error handling, catch blocks, fallback logic)                                                                      |
| `/review-pr comments`             | Comment analyzer (code comment accuracy and maintainability)                                                                              |
| `/review-pr types`                | Type-design analyzer (invariants, encapsulation)                                                                                          |
| `/review-pr simplify`             | Code simplifier — refinement only, does not post a review                                                                                 |

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

Findings are normalized, deduplicated across agents, and validated against the PR diff before posting. Inline comments are used only when the line can be safely anchored to the diff; unanchorable findings move to the summary body. If the reviews API call fails, the skill falls back to a single top-level PR comment.

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
