# opencode-action

Run an [OpenCode](https://opencode.ai/) agent from GitHub Actions, including issue and pull request comments, pull request reviews, and manually dispatched tasks.

[![CI](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml/badge.svg)](https://github.com/dceoy/opencode-action/actions/workflows/ci.yml)

## Quick start

### 1. Add a provider secret

In **Settings → Secrets and variables → Actions**, add the API key for your model provider. The example below uses `OPENCODE_API_KEY`.

### 2. Add the workflow

Create `.github/workflows/opencode.yml`:

<!-- prettier-ignore -->
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
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false
      - name: Run OpenCode
        uses: dceoy/opencode-action@0ff64486494c3134c46df6ce0e51eda4a64e349f  # v0.7.3
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

## Reusable workflows

For smaller caller workflows, this repository provides reusable workflows for OpenCode tasks and pull request reviews:

| Workflow                                                       | Purpose                                                                           |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [`opencode-bot.yml`](.github/workflows/opencode-bot.yml)       | Run OpenCode from trusted comments, manual dispatch, or a fixed prompt.           |
| [`opencode-review.yml`](.github/workflows/opencode-review.yml) | Install and use `pr-loop`'s external `pr-review` skill for `pull_request` events. |

See [Reusable workflows](docs/reusable-workflows.md) for caller examples, inputs, secrets, and permission requirements.

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

## Sakura AI Engine model synchronization

The optional [Sakura model synchronization workflow](.github/workflows/sync-sakura-models.yml) discovers chat-capable Sakura AI Engine models and opens or updates a pull request when the catalog changes. Configure the `SAKURA_AI_ENGINE_API_KEY` repository secret before enabling it.

The workflow uses the repository-provided `GITHUB_TOKEN` with `contents: write` and `pull-requests: write`; no additional GitHub token secret is required. GitHub does not create new workflow runs for events triggered by `GITHUB_TOKEN`, so pull requests created by this workflow do not automatically trigger `pull_request` workflows. See [GitHub's `GITHUB_TOKEN` documentation](https://docs.github.com/en/actions/concepts/security/github_token).

## Inputs

| Input                 | Default                   | Description                                                                                                                                       |
| --------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`               | Required                  | Model in `provider/model` format.                                                                                                                 |
| `agent`               | `build`                   | Primary agent. A slash command can override it.                                                                                                   |
| `prompt`              | Event comment             | Fixed prompt to use instead of the triggering comment.                                                                                            |
| `mentions`            | `/opencode,/oc`           | Comma-separated trigger phrases.                                                                                                                  |
| `variant`             | -                         | Provider-specific reasoning effort; leave empty unless supported. See [Custom providers](docs/custom-providers.md#variants-for-custom-providers). |
| `share`               | `false`                   | Share the OpenCode session.                                                                                                                       |
| `use-github-token`    | `false`                   | Use the workflow token instead of the default App-token flow.                                                                                     |
| `opencode-version`    | `latest`                  | OpenCode version to install. The bundled Sakura provider's `chunkTimeout` needs 1.2.25+.                                                          |
| `use-bundled-toolkit` | `true`                    | Use the bundled agents, commands, skills, and configuration.                                                                                      |
| `review-only`         | `false`                   | Enable isolated review execution and install upstream `pr-review`.                                                                                |
| `pr-review-ref`       | Caller-supplied SHA       | Immutable `pr-loop` commit supplying the review skill.                                                                                            |
| `timeout-minutes`     | `60`                      | Stop OpenCode after this many minutes.                                                                                                            |
| `oidc-base-url`       | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.                                                                                           |

Direct `workflow_dispatch` uses the same inputs as `workflow_call`; `model` and a non-empty `prompt` are required to run the job.

When `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task.

Outputs are `opencode-version` and `cache-hit`. Review-only runs (`review-only: 'true'`) skip the OpenCode binary cache and install the external `pr-review` skill.

## Pull request reviews

The reusable [`opencode-review.yml`](.github/workflows/opencode-review.yml) installs the external `pr-loop/pr-review` skill and runs it with `review-only: true`. The former bundled `/review-pr` command is no longer supported. The installed skill enables `metadata.opencode/slash: "true"` for native TUI `/pr-review` invocation. In GitHub runs, `/pr-review` is normalized into an explicit instruction to load the skill; no command file is generated. plain-text `prompt` instructions are also accepted to focus the review (for example, `security and performance`). The skill freezes the reviewed head, validates findings, and publishes a verified `COMMENT` review.

For direct action calls, set `review-only: 'true'` with `use-bundled-toolkit: 'true'`. The verified OpenCode GitHub App token is reused for upstream `pr-review` GitHub API calls through `pr-review-gh.sh`; it is not persisted outside the child `gh` process. `opencode-review.yml` pins `dceoy/pr-loop` once in `env.PR_LOOP_REF` (`v1.0.0`). Direct action and bot review-only calls must supply `pr-review-ref` explicitly. Review-only runs isolate project configuration and force a restricted primary agent with access only to review evidence and the structured adapter request. This tool permission boundary is not an operating-system sandbox.

See [Pull request reviews](docs/pull-request-reviews.md) for usage, permissions, trust boundaries, and limitations.
