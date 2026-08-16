# Reusable workflows

`opencode-action` publishes two reusable GitHub Actions workflows under `.github/workflows`. Call them as jobs with `uses`, then pass action configuration through `with` and provider credentials through `secrets`.

The examples below pin the reusable workflow definition to the commit that introduced these workflows. The called workflow currently invokes `dceoy/opencode-action@v0` internally, so this fixes the workflow definition without making the nested action reference immutable.

## Mention bot

Use `opencode-bot.yml` for `/opencode` and `/oc` comments, or for another event with a fixed `prompt`.

```yaml
---
name: OpenCode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  opencode:
    permissions:
      contents: read
      issues: write
      pull-requests: write
      id-token: write
      actions: read
    uses: dceoy/opencode-action/.github/workflows/opencode-bot.yml@7c392aad14ab1281630ae0c93e81d727f76b3e92
    with:
      model: opencode-go/kimi-k3
    secrets:
      OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
```

For comment events, the reusable workflow accepts comments only from `OWNER`, `MEMBER`, or `COLLABORATOR` author associations. On other events, set a non-empty `prompt` to run the workflow without a comment trigger.

## Pull request review

Use `opencode-review.yml` for automatic reviews on `pull_request` events. Its `prompt` defaults to `/review-pr`.

```yaml
---
name: OpenCode review
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

jobs:
  review:
    permissions:
      contents: read
      issues: write
      pull-requests: write
      id-token: write
      actions: read
    uses: dceoy/opencode-action/.github/workflows/opencode-review.yml@7c392aad14ab1281630ae0c93e81d727f76b3e92
    with:
      model: openrouter/openrouter/free
    secrets:
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
```

To focus the review, override `prompt` with a supported review aspect, for example `prompt: /review-pr security performance`. See [Pull request reviews](pull-request-reviews.md) for review behavior and security guarantees.

## Inputs

Both reusable workflows expose the action configuration plus a runner input:

| Input                 | Default                                                             | Description                                                   |
| --------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------- |
| `model`               | Required                                                            | Model in `provider/model` format.                             |
| `agent`               | `build`                                                             | Primary agent.                                                |
| `share`               | `false`                                                             | Share the OpenCode session.                                   |
| `prompt`              | `''` for `opencode-bot.yml`; `/review-pr` for `opencode-review.yml` | Fixed prompt.                                                 |
| `use-github-token`    | `false`                                                             | Use the workflow token instead of the default App-token flow. |
| `mentions`            | `/opencode,/oc`                                                     | Comma-separated trigger phrases.                              |
| `variant`             | `''`                                                                | Provider-specific model variant.                              |
| `oidc-base-url`       | `https://api.opencode.ai`                                           | OIDC exchange base URL.                                       |
| `opencode-version`    | `latest`                                                            | OpenCode version to install.                                  |
| `use-bundled-toolkit` | `true`                                                              | Use the bundled OpenCode toolkit.                             |
| `timeout-minutes`     | `60`                                                                | Maximum OpenCode runtime in minutes.                          |
| `runs-on`             | `ubuntu-latest`                                                     | Runner label for the called job.                              |

## Secrets

Pass only the provider secret needed by the selected model. The reusable workflows accept `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `OPENCODE_API_KEY`, and `SAKURA_AI_ENGINE_API_KEY`.

`GH_TOKEN` is optional. When omitted, the reusable workflow falls back to the caller's `github.token`. If `use-github-token: true`, ensure the caller grants the permissions required by the requested operation.

## Permissions

The reusable workflows request `contents: read`, `pull-requests: write`, `issues: write`, `id-token: write`, and `actions: read`. A called workflow cannot elevate the `GITHUB_TOKEN` permissions granted by its caller, so the calling job must grant the permissions needed by the selected mode.

The examples keep `permissions`, `with`, and `secrets` under the calling job so their scopes are explicit: `permissions` controls the caller token, `with` configures the reusable workflow inputs, and `secrets` passes credentials.
