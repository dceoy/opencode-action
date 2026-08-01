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
        uses: dceoy/opencode-action@aa0903dd64b04afeb942c067e69d47a3b580ccd1 # v0.6.2
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

| Provider        | Example model                | Secret               |
| --------------- | ---------------------------- | -------------------- |
| OpenCode        | `opencode-go/kimi-k3`        | `OPENCODE_API_KEY`   |
| OpenRouter      | `openrouter/openrouter/free` | `OPENROUTER_API_KEY` |
| Anthropic       | `anthropic/claude-opus-5`    | `ANTHROPIC_API_KEY`  |
| OpenAI          | `openai/gpt-5.6-sol`         | `OPENAI_API_KEY`     |
| Custom provider | `myprovider/my-model`        | Provider-specific    |

The provider account must have sufficient credits or quota. For providers not built into OpenCode, see [Custom providers](docs/custom-providers.md).

## Inputs

| Input                 | Default                   | Description                                                                                                                                                             |
| --------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`               | Required                  | Model in `provider/model` format.                                                                                                                                       |
| `agent`               | `build`                   | Primary agent. A slash command can override it.                                                                                                                         |
| `prompt`              | Event comment             | Fixed prompt to use instead of the triggering comment.                                                                                                                  |
| `mentions`            | `/opencode,/oc`           | Comma-separated trigger phrases.                                                                                                                                        |
| `variant`             | -                         | Provider-specific reasoning effort. Validated before the run; see [Model variants](#model-variants).                                                                    |
| `share`               | `false`                   | Share the OpenCode session.                                                                                                                                             |
| `use-github-token`    | `false`                   | Use the workflow token instead of the default App-token flow.                                                                                                           |
| `opencode-version`    | `latest`                  | OpenCode version to install. `/review-pr` requires 1.2.14+; the bundled Sakura provider's `chunkTimeout` needs 1.2.25+ (older pins fall back to the request `timeout`). |
| `use-bundled-toolkit` | `true`                    | Use the bundled agents, commands, skills, and configuration.                                                                                                            |
| `timeout-minutes`     | `60`                      | Stop OpenCode after this many minutes.                                                                                                                                  |
| `oidc-base-url`       | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.                                                                                                                 |

When `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task.

Outputs are `opencode-version` and `cache-hit`. `cache-hit` is empty on review-only runs (`prompt: /review-pr`), which always skip the cache and install fresh.

## Model variants

`variant` selects provider-specific reasoning effort. Leaving it empty is the portable default and always works.

A nonempty `variant` is checked against the action's bundled model metadata (`scripts/model-variants.json`) before OpenCode starts:

- Models listed there accept only the variants they declare. Anything else fails with an error naming the model, the requested variant, the supported values, and how to fix the workflow. Nothing is silently substituted.
- Models listed there with no declared variants reject every nonempty `variant`. All bundled `sakura/*` models are in this group, so `model: sakura/preview/Kimi-K2.7-Code` must run without `variant` — `variant: thinking` fails immediately instead of failing later inside OpenCode or the provider.
- Models outside that metadata — built-in OpenCode providers and custom providers from your own `opencode.json` — keep passing `variant` straight through, with a warning that compatibility was not validated.

## Pull request reviews

Set `prompt: /review-pr` to run the bundled read-only `pr-review` skill through its backward-compatible command wrapper. Findings are deduplicated, validated against the diff, and posted inline when they can be anchored to changed lines. Agents can also load the skill directly through OpenCode's native skill tool, but only `/review-pr` carries the read-only guarantees; see [Pull request reviews](docs/pull-request-reviews.md#review-isolation).

The default review runs the core quality, performance, coverage, documentation, security, and correctness reviewers; specialty reviewers beyond that set are added only when the diff matches their documented concern or an aspect such as `security`, `tests`, `docs`, or `performance` explicitly requests them. Provider request and chunk timeouts and the action's `timeout-minutes` watchdog are safety limits; they do not replace bounded request context or guarantee that a provider gateway or inference request will remain open.

See [Pull request reviews](docs/pull-request-reviews.md) for setup, supported review aspects, submission behavior, and security guarantees.
