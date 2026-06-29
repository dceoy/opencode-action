# opencode-action

OpenCode GitHub agent for GitHub Actions.

This repository provides a composite GitHub Action based on the upstream OpenCode GitHub Action implementation at <https://github.com/anomalyco/opencode/tree/dev/github>. The action installs the latest OpenCode CLI, caches the binary, and delegates execution to:

```bash
opencode github run
```

## Usage

Create `.github/workflows/opencode.yml` in the repository where you want OpenCode to respond to issue and pull request comments:

```yaml
name: opencode

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  opencode:
    if: |
      contains(github.event.comment.body, '/oc') ||
      contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    permissions:
      contents: write
      issues: write
      pull-requests: write
      id-token: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@v6
        with:
          fetch-depth: 1
          persist-credentials: false

      - name: Run OpenCode
        uses: dceoy/opencode-action@main
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          model: anthropic/claude-sonnet-4-20250514
          use_github_token: true
```

Then comment `/opencode` or `/oc` on an issue, pull request, or pull request review comment.

## Inputs

| Input              | Required | Default | Description                                                           |
| ------------------ | -------- | ------- | --------------------------------------------------------------------- |
| `model`            | Yes      |         | Model to use, in `provider/model` format.                             |
| `agent`            | No       |         | OpenCode primary agent to use.                                        |
| `share`            | No       |         | Share the OpenCode session. Defaults to true for public repositories. |
| `prompt`           | No       |         | Custom prompt to override the default prompt.                         |
| `use_github_token` | No       | `false` | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.   |
| `mentions`         | No       |         | Comma-separated trigger phrases. Defaults to `/opencode,/oc`.         |
| `variant`          | No       |         | Provider-specific model variant, such as `high`, `max`, or `minimal`. |
| `oidc_base_url`    | No       |         | Custom OIDC token exchange API base URL.                              |

## Secrets

Set the API key required by the selected model provider, for example:

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

## License

AGPL-3.0
