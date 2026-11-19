# opencode-action

Run an [OpenCode](https://opencode.ai/) agent from GitHub Actions, including inline pull request review comments, pull request reviews, and manually dispatched tasks.

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
  pull_request_review_comment:
    types: [created]
permissions:
  contents: read
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
        uses: dceoy/opencode-action@c9f89e8a02bc7eb64d52808ff8f1603f0a0713e3  # v1.0.0
        env:
          OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
          GITHUB_TOKEN: ${{ github.token }}
        with:
          model: opencode-go/kimi-k3
```

### 3. Add an inline comment to a pull request diff

```text
/opencode explain this change
```

The shorter `/oc` trigger also works:

```text
/oc suggest a fix
```

The default setup exchanges the workflow OIDC token for an OpenCode GitHub App token, which requires `id-token: write`.

On v2, no GitHub credentials are passed to OpenCode through its environment, and `gh` runs unauthenticated. In the default OIDC mode, the launcher only posts the final message as a reply to the review-comment thread. For code-writing runs, set `use-github-token: true` with persisted checkout credentials and a write-capable token (enabling `git push`), or use `runtime: v1` with an exact v1 pin. In token mode, persisted checkout credentials remain readable from OpenCode's shell, so that token is not isolated from the model; scope it least-privilege.

## Reusable workflows

For smaller caller workflows, this repository provides reusable workflows for OpenCode tasks and pull request reviews:

| Workflow                                                       | Purpose                                                                           |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [`opencode-bot.yml`](.github/workflows/opencode-bot.yml)       | Run OpenCode via PR review comments, dispatch, or a fixed prompt.                 |
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

## Releases

The [release workflow](.github/workflows/release.yml) runs every Monday at 09:15 JST when eligible files have changed, or manually for major, minor, and patch releases. After publication, it updates the major-version tag and opens a PR to refresh SHA pins.

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
| `runtime`             | `v2`                      | Runtime generation: `v1` or `v2`.                                                                                                                 |
| `opencode-version`    | `v2.3.0`                  | Exact stable release matching the runtime. The Sakura provider requires 1.2.25+.                                                                  |
| `use-bundled-toolkit` | `true`                    | Install the bundled provider configuration for normal runs or the trusted review bridge for review-only runs.                                     |
| `review-only`         | `false`                   | Enable isolated review execution and install upstream `pr-review`.                                                                                |
| `pr-review-ref`       | Caller-supplied SHA       | Immutable `pr-loop` commit supplying the review skill.                                                                                            |
| `timeout-minutes`     | `60`                      | Stop OpenCode after this many minutes.                                                                                                            |
| `oidc-base-url`       | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.                                                                                           |

The default is the Renovate-managed OpenCode v2 pin. Floating versions, including `latest`, are rejected. To use v1, set `runtime: v1` and a matching exact pin such as `v1.19.3`; test and pin upgrades for the selected major.

Direct `workflow_dispatch` uses the same inputs as `workflow_call`; `model` and a non-empty `prompt` are required to run the job.

When `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task. On v2, the token is not placed in OpenCode's environment and `gh` is unauthenticated; the launcher uses it for thread replies. In token mode, the persisted checkout credential remains readable from the shell (`git push`), so use a least-privilege token.

Outputs are `opencode-version`, `runtime` (`v1` or `v2`, selected explicitly), and `cache-hit`. Review-only runs (`review-only: 'true'`) skip the OpenCode binary cache, install the external `pr-review` skill, and use a disposable temporary HOME (including isolated XDG paths).

## Pull request reviews

The reusable [`opencode-review.yml`](.github/workflows/opencode-review.yml) runs the SHA-pinned external `pr-loop/pr-review` skill in an isolated `review-only` environment. The old bundled `/review-pr` command, agents, and orchestration are gone. The `/pr-review` prompt loads the skill through OpenCode's native `skill` tool; On v1, optional plain-text instructions narrow review focus; v2 accepts only an empty prompt or `/pr-review`.

Direct action or bot review-only calls require `use-bundled-toolkit: 'true'`, a full `pr-review-ref` commit SHA, and a concrete PR URL/head SHA. The reusable review workflow retains `agent`, `mentions`, and `use-bundled-toolkit` as public inputs for compatibility; its review agent remains fixed, comment mentions are irrelevant to PR events, and the bundle is required. The action retains its restricted GitHub API adapter and verified App-token publication flow, which are needed to enforce read-only evidence access and a commit-bound `COMMENT` review. The restriction is an OpenCode tool permission boundary, not an operating-system sandbox.

The reusable review workflow defaults to `opencode/deepseek-v4.1-flash-free`, currently free for a limited time without a model-provider API key or account. Override `model` with another provider and supply credentials only if required. GitHub credentials are still needed for review operations; model availability and free-tier limits can change.

See [Pull request reviews](docs/pull-request-reviews.md) for usage, permissions, trust boundaries, and limitations.

### Sakura OpenCode v2 integration check

The credential-free Bats smoke test checks the synchronized catalog with the
pinned OpenCode v2 CLI, including the isolated review configuration. It does
not establish provider parity or send a Sakura request. The manual **Trusted
Sakura v2 integration** workflow can exercise a catalog model with a real key:
configure the `sakura-integration` GitHub environment and its
`SAKURA_AI_ENGINE_API_KEY` secret and `SAKURA_MODEL` variable (a catalog
model ID without `sakura/`), then dispatch the workflow from the default branch. Restrict access to
that environment to trusted maintainers. The workflow checks out only the
default branch and never runs on pull requests. It asks the model to use the
read tool; a successful run requires a completed tool event and the probe
marker. The CLI may make more than one HTTP request to complete that single
interactive task. The harness suppresses provider output and classifies common
failures without printing credentials. Its five-minute deadline plus a short
shutdown grace period is separate from the catalog's provider timeouts. A
successful run does not by itself validate rate limits or the effective timeout semantics.
