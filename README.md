# opencode-action

Run an [OpenCode](https://opencode.ai/) agent from GitHub issue and pull request comments.

[![CI](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml/badge.svg)](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml)

## Quick start

### 1. Add a provider secret

In **Settings → Secrets and variables → Actions**, add the API key for your model provider. The example below uses `OPENCODE_API_KEY`.

### 2. Add the workflow

Create `.github/workflows/opencode.yml`:

```yaml
---
name: OpenCode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
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
          persist-credentials: false
      - name: Run OpenCode
        uses: dceoy/opencode-action@419cdd50ed88bd77dd429ebb683e8d18b03ac89a # v0.4.0
        env:
          OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
          GITHUB_TOKEN: ${{ github.token }}
        with:
          model: opencode-go/kimi-k3
```

### 3. Comment on an issue or pull request

```text
/opencode explain this issue
```

The shorter `/oc` trigger also works:

```text
/oc fix this
```

The default setup exchanges the workflow OIDC token for an OpenCode GitHub App token, which requires `id-token: write`.

## Models and secrets

Set `model` to a `provider/model` value and pass the corresponding API key:

| Provider         | Example model                | Secret                     |
| ---------------- | ---------------------------- | -------------------------- |
| OpenCode         | `opencode-go/kimi-k3`        | `OPENCODE_API_KEY`         |
| OpenRouter       | `openrouter/openrouter/free` | `OPENROUTER_API_KEY`       |
| Anthropic        | `anthropic/claude-opus-5`    | `ANTHROPIC_API_KEY`        |
| OpenAI           | `openai/gpt-5.6-sol`         | `OPENAI_API_KEY`           |
| Sakura AI Engine | Provider-specific            | `SAKURA_AI_ENGINE_API_KEY` |

The provider account must have sufficient credits or quota.

## Inputs

| Input              | Default                   | Description                                                      |
| ------------------ | ------------------------- | ---------------------------------------------------------------- |
| `model`            | Required                  | Model in `provider/model` format.                                |
| `agent`            | `build`                   | Primary agent. A slash command can override it.                  |
| `prompt`           | Event comment             | Fixed prompt to use instead of the triggering comment.           |
| `mentions`         | `/opencode,/oc`           | Comma-separated trigger phrases.                                 |
| `variant`          | -                         | Provider-specific reasoning effort.                              |
| `share`            | `false`                   | Share the OpenCode session.                                      |
| `use-github-token` | `false`                   | Use the workflow token instead of the default App-token flow.    |
| `version`          | `latest`                  | OpenCode version to install. `/review-pr` requires 1.2.14+.      |
| `enable-toolkit`   | `true`                    | Install the bundled agents, commands, and skills.                |
| `timeout-minutes`  | `60`                      | Stop OpenCode after this many minutes.                            |
| `oidc-base-url`    | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.          |

When `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task.

Outputs are `opencode-version` and `cache-hit`.

## Pull request reviews

Set `prompt: /review-pr` to run the bundled read-only pull request review workflow. Findings are deduplicated, validated against the diff, and posted inline when they can be anchored to changed lines.

See [Pull request reviews](docs/pull-request-reviews.md) for setup, supported review aspects, submission behavior, and security guarantees.
