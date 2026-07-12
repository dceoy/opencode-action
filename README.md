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
| `agent`            | No       | `build`                   | OpenCode primary agent applied as `default_agent`; a slash command's frontmatter agent takes precedence.                                                      |
| `share`            | No       | `false`                   | Whether to share the OpenCode session.                                                                                                                         |
| `prompt`           | No       |                           | Custom prompt. A leading Markdown slash command is expanded before `opencode github run`.                                                                      |
| `use-github-token` | No       | `false`                   | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.                                                                                            |
| `mentions`         | No       | `/opencode,/oc`           | Comma-separated trigger phrases, matched case-insensitively.                                                                                                   |
| `variant`          | No       |                           | Provider-specific model variant for reasoning effort, such as `high`, `max`, or `minimal`.                                                                     |
| `oidc-base-url`    | No       | `https://api.opencode.ai` | Base URL for OIDC token exchange. Override only for a custom GitHub App installation.                                                                          |
| `version`          | No       | `latest`                  | OpenCode version to install, such as `v1.2.3`; `latest` resolves the latest upstream release.                                                                  |
| `enable-toolkit`   | No       | `true`                    | Install the action's bundled `.opencode/` agents, commands, and skills into `~/.config/opencode` (global config) before running. Existing files are preserved. |
| `timeout-minutes`  | No       | `60`                      | Maximum minutes to let `opencode github run` execute before it is killed (uses `timeout`/`gtimeout` when available; otherwise runs without enforced timeout).  |

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

## Slash-command dispatch

`opencode github run` currently sends the prompt verbatim and does not forward the action's `agent` input. The action therefore expands a leading Markdown command before invoking OpenCode and applies the effective agent as `default_agent`.

Command lookup uses this precedence:

1. the checked-out repository's `.opencode/commands/`;
2. the user's installed `~/.config/opencode/commands/`;
3. the action's bundled commands as a fallback when `enable-toolkit: true`.

A command's frontmatter `agent:` overrides the action input only when it selects a primary agent. `$ARGUMENTS` is expanded literally. Commands using `model:`, `subtask:`, positional placeholders, shell template blocks, or config-defined command entries are rejected or left to native OpenCode handling rather than partially emulated.

## Pull Request Reviews

The bundled `/review-pr` command pins the PR head SHA before analyzing the diff and refuses to publish a conclusion if the head moves. Structured inline reviews are submitted through a helper that:

- derives the repository and PR number from the GitHub Actions context;
- accepts only `commit_id`, `body`, and a non-empty comments array with line-based anchors;
- injects `event: COMMENT`;
- verifies the review-author token;
- rechecks the live PR head immediately before the review POST.

The command does not retarget findings to a newer commit and does not update the submitted review body after posting.

### Review author and the OpenCode App token

When the default OpenCode GitHub App flow is used (`use-github-token: false`), `/review-pr` resolves candidate App tokens from git credential configuration and verifies the author identity with a throwaway pending review before the structured write. If none verifies as `opencode-agent[bot]`, the review fails instead of silently using another identity. With `use-github-token: true`, the workflow token is an explicit fallback.

Workflows that invoke `/review-pr` must provide:

- `pull-requests: write` permission;
- `GH_TOKEN` or `GITHUB_TOKEN` for GitHub reads and the explicit workflow-token fallback;
- a valid model-provider API key.

Example:

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

| Command                           | What runs                                                                                                                                                                                                                                                                                                               |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/review-pr` or `/review-pr all`  | Core reviewers plus applicable specialty agents; excludes `code-simplifier`.                                                                                                                                                                                                                                          |
| `/review-pr security performance` | `security-code-reviewer`, `performance-reviewer`                                                                                                                                                                                                                                                                        |
| `/review-pr tests docs`           | `test-coverage-reviewer`, `pr-test-analyzer`, `documentation-accuracy-reviewer`                                                                                                                                                                                                                                         |
| `/review-pr code`                 | `code-reviewer`, `code-quality-reviewer`                                                                                                                                                                                                                                                                                |
| `/review-pr quality`              | `code-quality-reviewer`                                                                                                                                                                                                                                                                                                 |
| `/review-pr coverage`             | `test-coverage-reviewer`, `pr-test-analyzer`                                                                                                                                                                                                                                                                            |
| `/review-pr documentation`        | `documentation-accuracy-reviewer`                                                                                                                                                                                                                                                                                       |
| `/review-pr errors`               | `silent-failure-hunter`                                                                                                                                                                                                                                                                                                 |
| `/review-pr comments`             | `comment-analyzer`                                                                                                                                                                                                                                                                                                      |
| `/review-pr types`                | `type-design-analyzer`                                                                                                                                                                                                                                                                                                  |
| `/review-pr simplify`             | `code-simplifier` — returns behavior-preserving simplification proposals as review suggestions; never edits files.                                                                                                                                                                                                      |

Findings are normalized, deduplicated, and validated against the pinned diff. Diff-anchorable findings are posted as inline review comments. Material findings without safe anchors remain in the review body or are returned as a top-level fallback when no inline comment can be submitted.

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
