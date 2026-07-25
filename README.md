# opencode-action

Run an [OpenCode](https://opencode.ai/) agent from GitHub issue and pull request comments.

[![CI](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml/badge.svg)](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml)

## Quick start

### 1. Add a model provider secret

In your repository, open **Settings → Secrets and variables → Actions**, select **New repository secret**, and add the API key for your provider.

For the example below, create `OPENCODE_API_KEY`.

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

### 3. Ask OpenCode for help

Comment on an issue or pull request:

```text
/opencode explain this issue
```

You can also use the shorter `/oc` trigger:

```text
/oc fix this
```

The default setup exchanges the workflow's OIDC token for an OpenCode GitHub App token. This is why the workflow grants `id-token: write`.

## Choose a model

Set `model` to a `provider/model` value and pass that provider's API key:

| Provider         | Example model                | Secret                     |
| ---------------- | ---------------------------- | -------------------------- |
| OpenCode         | `opencode-go/kimi-k3`        | `OPENCODE_API_KEY`         |
| OpenRouter       | `openrouter/openrouter/free` | `OPENROUTER_API_KEY`       |
| Anthropic        | `anthropic/claude-opus-5`    | `ANTHROPIC_API_KEY`        |
| OpenAI           | `openai/gpt-5.6-sol`         | `OPENAI_API_KEY`           |
| Sakura AI Engine | Provider-specific            | `SAKURA_AI_ENGINE_API_KEY` |

Make sure the account has available credits or quota.

## Common options

Add options under the step's `with:` block:

```yaml
with:
  model: openrouter/openrouter/free
  prompt: /review-pr
  timeout-minutes: 30
```

| Input              | Default                   | Description                                                      |
| ------------------ | ------------------------- | ---------------------------------------------------------------- |
| `model`            | Required                  | Model in `provider/model` format.                                |
| `prompt`           | Event comment             | Use a fixed prompt instead of the triggering comment.            |
| `mentions`         | `/opencode,/oc`           | Comma-separated trigger phrases.                                 |
| `agent`            | `build`                   | Primary OpenCode agent. A slash command can override it.         |
| `variant`          | -                         | Provider-specific reasoning effort, such as `high` or `minimal`. |
| `share`            | `false`                   | Share the OpenCode session.                                      |
| `use-github-token` | `false`                   | Use `GITHUB_TOKEN` instead of the OpenCode App token flow.       |
| `version`          | `latest`                  | OpenCode version to install. `/review-pr` needs 1.2.14 or newer. |
| `enable-toolkit`   | `true`                    | Install the action's bundled agents, commands, and skills.       |
| `timeout-minutes`  | `60`                      | Stop the OpenCode process after this many minutes.               |
| `oidc-base-url`    | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.          |

If you set `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task.

The action outputs `opencode-version` (the installed version) and `cache-hit` (whether the binary came from cache).

## Pull request reviews

The bundled `/review-pr` command reviews a pull request and submits findings through GitHub's review API:

```yaml
- name: Run OpenCode review
  uses: dceoy/opencode-action@419cdd50ed88bd77dd429ebb683e8d18b03ac89a # v0.4.0
  env:
    OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
  with:
    model: openrouter/openrouter/free
    prompt: /review-pr
```

Grant `pull-requests: write`. With the default App-token flow, the review is submitted as `opencode-agent[bot]`; if a valid App token cannot be verified, the run fails instead of posting under the wrong identity. With `use-github-token: true`, it can fall back to `github-actions[bot]`.

Limit a review to one or more aspects:

| Command                           | Focus                                |
| --------------------------------- | ------------------------------------ |
| `/review-pr` or `/review-pr all`  | Full review                          |
| `/review-pr security performance` | Security and performance             |
| `/review-pr tests docs`           | Test coverage and documentation      |
| `/review-pr code`                 | Correctness and code quality         |
| `/review-pr errors`               | Silent failures and error handling   |
| `/review-pr comments`             | Comment accuracy                     |
| `/review-pr types`                | Type design                          |
| `/review-pr simplify`             | Read-only simplification suggestions |

Review findings are deduplicated and validated against the pull request diff. Findings that can be anchored are posted inline; any remaining findings are summarized in the review body.

See [Pull request reviews](docs/pull-request-reviews.md) for reviewer selection, submission behavior, permissions, and failure modes.

## Documentation

- [Pull request reviews](docs/pull-request-reviews.md)
- [Security model](docs/security-model.md)
