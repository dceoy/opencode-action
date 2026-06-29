# opencode-action

OpenCode GitHub Action for running the OpenCode GitHub agent in workflows.

[![CI](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml/badge.svg)](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml)

This repository provides a composite GitHub Action based on the upstream OpenCode GitHub Action implementation at <https://github.com/anomalyco/opencode/tree/dev/github>. The action resolves the requested OpenCode CLI version, restores or populates a cache for the binary, adds OpenCode to `PATH`, and delegates execution to:

```bash
opencode github run
```

## Usage

Create `.github/workflows/opencode.yml` in the repository where you want OpenCode to respond to issue and pull request comments. By default, the action exchanges the workflow OIDC token for an OpenCode GitHub App token, so the workflow must grant `id-token: write`.

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

| Input              | Required | Default                   | Description                                                                                       |
| ------------------ | -------- | ------------------------- | ------------------------------------------------------------------------------------------------- |
| `model`            | Yes      |                           | Model to use, in `provider/model` format.                                                         |
| `agent`            | No       | `build`                   | OpenCode primary agent to use. Falls back to `default_agent` from config or `build` if not found. |
| `share`            | No       | `false`                   | Whether to share the OpenCode session.                                                            |
| `prompt`           | No       |                           | Custom prompt to override the default prompt.                                                     |
| `use_github_token` | No       | `false`                   | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.                               |
| `mentions`         | No       | `/opencode,/oc`           | Comma-separated trigger phrases, matched case-insensitively.                                      |
| `variant`          | No       |                           | Provider-specific model variant for reasoning effort, such as `high`, `max`, or `minimal`.        |
| `oidc_base_url`    | No       | `https://api.opencode.ai` | Base URL for OIDC token exchange. Override only for a custom GitHub App installation.             |
| `version`          | No       | `latest`                  | OpenCode version to install, such as `v1.2.3`; `latest` resolves the latest upstream release.     |

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

When `use_github_token: true`, pass `GITHUB_TOKEN` in `env` and grant the workflow enough permissions for the requested work.

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
