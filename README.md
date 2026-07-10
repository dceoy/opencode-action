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

| Input              | Required | Default                   | Description                                                                                                                                                                                                         |
| ------------------ | -------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`            | Yes      |                           | Model to use, in `provider/model` format.                                                                                                                                                                           |
| `agent`            | No       | `build`                   | OpenCode primary agent to use. Falls back to `default_agent` from config or `build` if not found.                                                                                                                   |
| `share`            | No       | `false`                   | Whether to share the OpenCode session.                                                                                                                                                                              |
| `prompt`           | No       |                           | Custom prompt to override the default prompt.                                                                                                                                                                       |
| `use-github-token` | No       | `false`                   | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.                                                                                                                                                 |
| `mentions`         | No       | `/opencode,/oc`           | Comma-separated trigger phrases, matched case-insensitively.                                                                                                                                                        |
| `variant`          | No       |                           | Provider-specific model variant for reasoning effort, such as `high`, `max`, or `minimal`.                                                                                                                          |
| `oidc-base-url`    | No       | `https://api.opencode.ai` | Base URL for OIDC token exchange. Override only for a custom GitHub App installation.                                                                                                                               |
| `version`          | No       | `latest`                  | OpenCode version to install, such as `v1.2.3`; `latest` resolves the latest upstream release.                                                                                                                       |
| `enable-toolkit`   | No       | `true`                    | Install the action's bundled `.opencode/` agents, commands, and skills into `~/.config/opencode` (global config) before running. Existing files are preserved; `/review-pr` uses a temporary trusted configuration. |
| `timeout-minutes`  | No       | `60`                      | Maximum minutes to let OpenCode execute before it is killed (uses `timeout`/`gtimeout`; `/review-pr` requires one).                                                                                                 |

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

### Safe pull request reviews

For `/review-pr`, make the caller-provided workflow token the security boundary. Use `use-github-token: true`, pass `${{ github.token }}` explicitly, grant `contents: read`, and configure checkout with `persist-credentials: false`. Do not substitute `secrets.GH_TOKEN`, `secrets.GITHUB_TOKEN`, or another custom token: those may have `contents: write`.

```yaml
permissions:
  contents: read
  pull-requests: write

- uses: actions/checkout@v7
  with:
    persist-credentials: false

- uses: dceoy/opencode-action@v0
  env:
    GITHUB_TOKEN: ${{ github.token }}
  with:
    model: opencode-go/glm-5.2
    prompt: /review-pr
    use-github-token: true
```

`/review-pr` requires a clean caller checkout (including ignored paths). Trusted action code collects PR metadata and the diff, then creates a disposable plain directory from `git archive`; it is deliberately not a Git worktree, so review analysis has no refs, remotes, Git configuration, hooks, index, or credentials to mutate. The analysis process receives a temporary action-owned OpenCode configuration and no GitHub token. Repository-local OpenCode configuration, commands, agents, plugins, and permission files are moved out of discovery locations before analysis. After it exits, trusted code validates the structured findings and submits the PR review with the workflow token. The disposable directory is removed on success, failure, timeout, and signals. Normal action behavior, including mutation-capable `/oc fix` workflows, is unchanged.

## Pull Request Reviews

The review token boundary is deliberately narrow: use only `${{ github.token }}` with `contents: read` and `pull-requests: write`. `use-github-token: true` is required for this bundled review workflow; it does not inspect or replace that token from Git configuration. The token is available only to trusted PR-context collection and validated review submission, never to the model process.

Preventive controls are the non-Git disposable analysis directory, temporary action-owned configuration, and restricted analyzer agent. Cleanup and the clean-checkout check are containment and integrity verification, not the primary enforcement mechanism. Review submission is a structured action-owned `gh api` call; no issue-comment permission is needed.

<!-- Historical App-token flow details below apply to normal OpenCode commands, not /review-pr. -->

### Review author and the OpenCode App token

When the default OpenCode GitHub App flow is used (`use-github-token: false`), `/review-pr` resolves every _candidate_ App token from git credential configuration (checking the local `http.https://github.com/.extraheader` key, `git config --get-urlmatch`, and `--get-regexp`/`--show-origin --get-regexp` across all config scopes to also cover includeIf/global-style credential files, matching only keys whose URL host is exactly `github.com`). None of these candidates is trusted on format alone: an `actions/checkout`-persisted `GITHUB_TOKEN` credential or a PAT can be written to the exact same git-config key in the exact same `x-access-token:<token>` basic-auth shape as the real OpenCode App token, and a workflow can legitimately have both that checkout-persisted credential at the highest-priority key and a real OpenCode App token from a lower-priority source. So before any structured review write, `/review-pr` tries each candidate in order, verifying it by creating a throwaway pending PR review with it, checking the `user.login` on the response, and immediately deleting that pending review regardless of the outcome. The search stops at, and exports, the first candidate that verifies as `opencode-agent[bot]`; an earlier unverified candidate does not stop it from trying later ones. Every structured review submission, review-body update, and anchor-validation retry re-resolves and re-verifies immediately beforehand.

**Limitation:** GitHub does not expose a read-only "whoami" endpoint for GitHub App installation tokens — `GET /user` requires user-to-server auth and returns 403 for every installation token alike, so it cannot distinguish the OpenCode App token from the workflow's own `GITHUB_TOKEN` or a PAT-backed credential. The pending-review probe above is the safest available alternative: a pending review is never visible to anyone but its own author until submitted, so a failed or mismatched check never publishes anything to the PR, but creating and deleting the probe are still real API writes, not a true read-only check.

**If no App token can be verified as `opencode-agent[bot]` while `use-github-token` is `false`, `/review-pr` fails the run instead of submitting the review.** It never silently falls back to the workflow's `GH_TOKEN`/`GITHUB_TOKEN`, or to an unverified candidate, for a structured review submission, because either could make the review appear under the wrong identity instead of `opencode-agent[bot]`.

When the workflow explicitly opts into `use-github-token: true`, `/review-pr` uses the caller's `GH_TOKEN`/`GITHUB_TOKEN` exclusively for reads and review submissions. It does not inspect, verify, or export any App-token candidate, so a runner's Git configuration cannot replace the selected read-scoped workflow token. Direct review submissions are expected to appear as `github-actions[bot]` in this mode.

**Exact credential precedence for every structured review write:**

1. With `use-github-token: true`, the caller-provided `GH_TOKEN`/`GITHUB_TOKEN` is used unchanged; no Git-config App-token candidate is considered.
2. With `use-github-token: false`, every resolved candidate App token is tried in order and the first that verifies as `opencode-agent[bot]` is exported. If none verifies, the run fails rather than falling back to another credential.

The exclusive-token behavior is safe because the best-effort read helper (`opencode_prepare_gh_token`, used for `gh pr view`/`gh pr diff`) is a no-op whenever `use-github-token: true` — it never exports an unverified git-config candidate over the caller's own token.

Workflows that invoke `/review-pr` must provide:

- `pull-requests: write` permission
- `GH_TOKEN: ${{ github.token }}` or `GITHUB_TOKEN: ${{ github.token }}` for `gh pr diff`, `gh pr view`, and `gh api` review submission when using `use-github-token: true`; with the default App-token flow, `/review-pr` requires an App token that verifies as `opencode-agent[bot]` for `gh api` review submission and fails fast if none is available
- A valid API key for the selected model provider with available credits or quota

Example OpenCode step:

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

The bundled toolkit combines Claude Code Action-style core reviewers with `pr-review-toolkit` specialty agents. Use `/review-pr` with any of the following aspect keywords:

| Command                           | What runs                                                                                                                                                                                                                                                                                                               |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/review-pr` or `/review-pr all`  | Core reviewers (`code-quality-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, `security-code-reviewer`, `code-reviewer`) plus specialty agents (`pr-test-analyzer`, `silent-failure-hunter`, `comment-analyzer`, `type-design-analyzer`) when triggered by diff content |
| `/review-pr security performance` | `security-code-reviewer`, `performance-reviewer`                                                                                                                                                                                                                                                                        |
| `/review-pr tests docs`           | `test-coverage-reviewer`, `pr-test-analyzer`, `documentation-accuracy-reviewer`                                                                                                                                                                                                                                         |
| `/review-pr code`                 | `code-reviewer`, `code-quality-reviewer`                                                                                                                                                                                                                                                                                |
| `/review-pr quality`              | `code-quality-reviewer`                                                                                                                                                                                                                                                                                                 |
| `/review-pr coverage`             | `test-coverage-reviewer`, `pr-test-analyzer`                                                                                                                                                                                                                                                                            |
| `/review-pr documentation`        | `documentation-accuracy-reviewer`                                                                                                                                                                                                                                                                                       |
| `/review-pr errors`               | `silent-failure-hunter`                                                                                                                                                                                                                                                                                                 |
| `/review-pr comments`             | `comment-analyzer`                                                                                                                                                                                                                                                                                                      |
| `/review-pr types`                | `type-design-analyzer`                                                                                                                                                                                                                                                                                                  |

#### Core reviewers (Claude Code Action-compatible)

- **`code-quality-reviewer`** — general quality, maintainability, edge cases, robustness, type safety
- **`test-coverage-reviewer`** — missing critical test scenarios, brittle tests, error coverage gaps
- **`documentation-accuracy-reviewer`** — README, API docs, docstrings, examples vs. implementation

#### Specialty reviewers (pr-review-toolkit style)

- **`code-reviewer`** — project-guideline compliance (AGENTS.md), bugs, and quality
- **`performance-reviewer`** — algorithmic complexity, N+1, resource leaks
- **`security-code-reviewer`** — trust boundaries, injection, secrets, auth/authz
- **`pr-test-analyzer`** — behavioral test coverage and critical coverage gaps
- **`silent-failure-hunter`** — silent failures, broad catch blocks, fallback logic
- **`comment-analyzer`** — comment accuracy, completeness, and comment rot
- **`type-design-analyzer`** — type invariants, encapsulation, and design quality

Findings are normalized, deduplicated across agents, and validated against the PR diff before being posted. Diff-anchorable findings are submitted as GitHub inline review comments. When inline comments are submitted, findings that cannot be safely anchored remain in the GitHub review body with an explicit fallback reason. When no inline anchors are available, the command returns a top-level fallback response instead.

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
