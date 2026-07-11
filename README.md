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

| Input              | Required | Default                   | Description                                                                                                                                                                                                   |
| ------------------ | -------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`            | Yes      |                           | Model to use, in `provider/model` format.                                                                                                                                                                     |
| `agent`            | No       | `build`                   | OpenCode primary agent to use. Falls back to `default_agent` from config or `build` if not found.                                                                                                             |
| `share`            | No       | `false`                   | Whether to share the OpenCode session.                                                                                                                                                                        |
| `prompt`           | No       |                           | Custom prompt to override the default prompt.                                                                                                                                                                 |
| `use-github-token` | No       | `false`                   | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.                                                                                                                                           |
| `mentions`         | No       | `/opencode,/oc`           | Comma-separated trigger phrases, matched case-insensitively.                                                                                                                                                  |
| `variant`          | No       |                           | Provider-specific model variant for reasoning effort, such as `high`, `max`, or `minimal`.                                                                                                                    |
| `oidc-base-url`    | No       | `https://api.opencode.ai` | Base URL for OIDC token exchange. Override only for a custom GitHub App installation.                                                                                                                         |
| `version`          | No       | `latest`                  | OpenCode version to install, such as `v1.2.3`; `latest` resolves the latest upstream release.                                                                                                                 |
| `enable-toolkit`   | No       | `true`                    | Install the action's bundled `.opencode/` agents, commands, and skills into `~/.config/opencode` (global config) before running. Existing files are preserved; review-only mode always installs a fresh copy. |
| `timeout-minutes`  | No       | `60`                      | Maximum minutes to let `opencode github run` execute before it is killed (uses `timeout`/`gtimeout` when available; otherwise runs without enforced timeout).                                                 |

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

## Pull Request Reviews

The bundled `/review-pr` command submits a GitHub pull request review through `gh api`. It uses inline review comments for every finding that can be safely anchored to the PR diff, and includes only unanchorable findings in the review body as summary-only fallback items when at least one inline comment is submitted. If no finding can be anchored inline, `/review-pr` returns a top-level markdown fallback instead. When there are no summary-only findings, the review body is a single line (`OpenCode PR Review: <N> inline finding(s).`) with no empty "Summary-only findings" section.

A successful structured review run produces one GitHub review summary (with its inline comments), which `/review-pr` updates in place with the run link. `/review-pr` never calls `gh pr comment` or the issue comment API itself. It may still return a short final assistant message after submitting the review; `opencode github run` posts that as a separate top-level completion comment, so a run can produce the review plus at most one additional completion comment — not necessarily exactly one top-level artifact.

The bundled toolkit ships an `external_directory` permission in `.opencode/opencode.jsonc` (copied into `~/.config/opencode/` with the rest of the toolkit) that denies by default, so a stray attempt to read outside the checked-out repository, such as inspecting `/opt/pipx/logs/*` after a failed tool install, is denied immediately instead of blocking on the default "ask" prompt, which nothing can answer in a non-interactive GitHub Actions run and would otherwise hang until `timeout-minutes` kills it. The one narrow exception is `~/.config/opencode/scripts/resolve-app-token.sh` itself: `/review-pr` sources that bundled script from outside the checked-out repository to resolve the OpenCode App token, so it is individually allow-listed ahead of the catch-all deny rule; no other external path is permitted.

### Review-only mode hardening

When the action detects a review-only run (a `/review-pr` prompt or trigger comment), it refuses to load any caller-controlled OpenCode configuration:

- The resolved OpenCode version must be a plain `x.y.z` release at or above `1.1.29`, the first upstream release that supports `OPENCODE_DISABLE_PROJECT_CONFIG`. Older or unparseable versions fail the run instead of silently loading the reviewed project's `.opencode/` config.
- The `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, and `OPENCODE_CONFIG_CONTENT` environment variables are unset (with a workflow warning) before `opencode github run` starts, because upstream honors them even when project config is disabled. The `OPENCODE_PERMISSION`, `OPENCODE_TEST_HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` variables are unset for the same reason, and `XDG_DATA_HOME` is then re-exported to a fresh, empty `mktemp -d` directory so the persistent `$HOME/.local/share` tree (or any inherited XDG data path) cannot supply an `auth.json` whose `wellknown` entries would be merged as remote config before the bundled global config.
- The PR head SHA is pinned when the review context is established and revalidated immediately before each review `POST`/`PUT`, so a head that moves during the run — including during token identity verification — aborts the submission.

### Review author and the OpenCode App token

When the default OpenCode GitHub App flow is used (`use-github-token: false`), `/review-pr` resolves every _candidate_ App token from git credential configuration (checking the local `http.https://github.com/.extraheader` key, `git config --get-urlmatch`, and `--get-regexp`/`--show-origin --get-regexp` across all config scopes to also cover includeIf/global-style credential files, matching only keys whose URL host is exactly `github.com`). None of these candidates is trusted on format alone: an `actions/checkout`-persisted `GITHUB_TOKEN` credential or a PAT can be written to the exact same git-config key in the exact same `x-access-token:<token>` basic-auth shape as the real OpenCode App token, and a workflow can legitimately have both that checkout-persisted credential at the highest-priority key and a real OpenCode App token from a lower-priority source. So before any structured review write, `/review-pr` tries each candidate in order, verifying it by creating a throwaway pending PR review with it, checking the `user.login` on the response, and immediately deleting that pending review regardless of the outcome. The search stops at, and exports, the first candidate that verifies as `opencode-agent[bot]`; an earlier unverified candidate does not stop it from trying later ones. Every structured review submission, review-body update, and anchor-validation retry re-resolves and re-verifies immediately beforehand.

**Limitation:** GitHub does not expose a read-only "whoami" endpoint for GitHub App installation tokens — `GET /user` requires user-to-server auth and returns 403 for every installation token alike, so it cannot distinguish the OpenCode App token from the workflow's own `GITHUB_TOKEN` or a PAT-backed credential. The pending-review probe above is the safest available alternative: a pending review is never visible to anyone but its own author until submitted, so a failed or mismatched check never publishes anything to the PR, but creating and deleting the probe are still real API writes, not a true read-only check.

**If no App token can be verified as `opencode-agent[bot]` while `use-github-token` is `false`, `/review-pr` fails the run instead of submitting the review.** It never silently falls back to the workflow's `GH_TOKEN`/`GITHUB_TOKEN`, or to an unverified candidate, for a structured review submission, because either could make the review appear under the wrong identity instead of `opencode-agent[bot]`.

If the workflow explicitly opts into `use-github-token: true` and no candidate App token verifies, this is intentional: `/review-pr` falls back to the workflow's `GH_TOKEN`/`GITHUB_TOKEN`, and direct review submissions are expected to appear as `github-actions[bot]` in that case. A verified `opencode-agent[bot]` candidate still takes precedence over that fallback when one is found — see the exact precedence rules below.

**Exact credential precedence for every structured review write, regardless of `use-github-token`:**

1. Every resolved candidate App token is tried in order; the first one that verifies as `opencode-agent[bot]` always wins, is exported, and is used for that write. This applies even when `use-github-token: true`, so a real App token still takes precedence over the explicit workflow token when one is available and verifies.
2. Only when **no** candidate verifies does `use-github-token` decide the outcome: `true` falls back to the caller's original `GH_TOKEN`/`GITHUB_TOKEN`, unmodified; `false` fails the run.

That fallback is safe because the best-effort read helper (`opencode_prepare_gh_token`, used for `gh pr view`/`gh pr diff`) is a no-op whenever `use-github-token: true` — it never exports an unverified git-config candidate over the caller's own token, so there is nothing to overwrite the explicit workflow token with before the write gate runs.

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
| `/review-pr simplify`             | `code-simplifier` — read-only, behavior-preserving simplification proposals; never modifies files                                                                                                                                                                                                                       |

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
