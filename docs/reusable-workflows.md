# Reusable workflows

`opencode-action` publishes two reusable GitHub Actions workflows under `.github/workflows`. Call them as jobs with `uses`, then pass action configuration through `with` and provider credentials through `secrets`.

The examples below pin the reusable workflow definition and its `action-ref` input to the same commit. The called workflow checks out that OpenCode action revision and invokes it from a local path, so a full commit SHA makes both layers immutable.

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
    uses: dceoy/opencode-action/.github/workflows/opencode-bot.yml@87c8c6821360f1ced2fbb0868fb8e583df100046
    with:
      model: opencode-go/kimi-k3
      action-ref: 87c8c6821360f1ced2fbb0868fb8e583df100046
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
    uses: dceoy/opencode-action/.github/workflows/opencode-review.yml@87c8c6821360f1ced2fbb0868fb8e583df100046
    with:
      model: openrouter/openrouter/free
      action-ref: 87c8c6821360f1ced2fbb0868fb8e583df100046
    secrets:
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
```

This example assumes a trusted, same-repository pull request. For `pull_request` events from public forks, GitHub withholds repository Actions secrets and makes `GITHUB_TOKEN` read-only; Dependabot pull requests have the same restrictions. Private-fork behavior can differ when repository settings explicitly allow secrets or write tokens.

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
| `action-ref`          | Required                                                            | Revision of `dceoy/opencode-action` to check out.              |
| `runs-on`             | `ubuntu-latest`                                                     | Runner label for the called job.                              |

## Secrets

Pass only the provider secret needed by the selected model. The reusable workflows accept `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `OPENCODE_API_KEY`, `SAKURA_AI_ENGINE_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, `DEEPSEEK_API_KEY`, `XAI_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, and `MOONSHOT_API_KEY`.

`GH_TOKEN` is optional. When omitted, the reusable workflow falls back to the caller's `github.token`. With `use-github-token: true`, that fallback is limited to `contents: read` by the called workflow even if the caller grants `contents: write`. For code-writing operations such as `/oc fix this`, pass a separately write-scoped `GH_TOKEN`; otherwise GitHub API writes to repository contents fail with `403`.

## Permissions

The reusable workflows request `contents: read`, `pull-requests: write`, `issues: write`, `id-token: write`, and `actions: read`. A called workflow can only maintain or reduce the caller's `GITHUB_TOKEN` permissions: the caller must grant the requested permissions, but its higher `contents` permission cannot override the called workflow's `contents: read` ceiling. A separately supplied `GH_TOKEN` is not governed by that `GITHUB_TOKEN` permission ceiling.

The examples keep `permissions`, `with`, and `secrets` under the calling job so their scopes are explicit: `permissions` controls the caller token, `with` configures the reusable workflow inputs, and `secrets` passes credentials.
