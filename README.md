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

| Input              | Required | Default                   | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------ | -------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`            | Yes      |                           | Model to use, in `provider/model` format.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `agent`            | No       | `build`                   | OpenCode primary agent to use. Falls back to `default_agent` from config or `build` if not found.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `share`            | No       | `false`                   | Whether to share the OpenCode session.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `prompt`           | No       |                           | Custom prompt to override the default prompt.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `use-github-token` | No       | `false`                   | Use `GITHUB_TOKEN` directly instead of OpenCode App token exchange.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `mentions`         | No       | `/opencode,/oc`           | Comma-separated trigger phrases, matched case-insensitively.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `variant`          | No       |                           | Provider-specific model variant for reasoning effort, such as `high`, `max`, or `minimal`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `oidc-base-url`    | No       | `https://api.opencode.ai` | Base URL for OIDC token exchange. Override only for a custom GitHub App installation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `version`          | No       | `latest`                  | OpenCode version to install, such as `v1.2.3`; `latest` resolves the latest upstream release.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `enable-toolkit`   | No       | `true`                    | Install the action's bundled `.opencode/` agents, commands, and skills into `~/.config/opencode` (global config) before running. When `review-only` is also `true`, any pre-existing content at that path (and at `~/.opencode/` other than the cached `bin/` directory) is replaced first so a stale or self-hosted-runner-persisted toolkit can never remain authoritative; otherwise pre-existing global config is preserved so mutation-capable workflows keep their persisted customizations on self-hosted runners.                                                                                                                                                                                                                                                       |
| `review-only`      | No       | `false`                   | Set `true` only for a dedicated review-only workflow entrypoint whose prompt always invokes `/review-pr`. Requires `enable-toolkit: true` and `agent` to be the default (`build`) or `review-pr-orchestrator`, and requires `prompt` to explicitly invoke `/review-pr`; the run fails fast otherwise. Combined with `enable-toolkit`, this also disables project-level `.opencode/` config and `AGENTS.md` from the checked-out repository and installs the toolkit into a freshly wiped `~/.config/opencode/`, so a pull request cannot shadow the bundled toolkit's agents, commands, or permissions with its own. Leave `false` for mutation-capable workflows (for example `/oc ...`), which need the repository's own `.opencode/` config and `AGENTS.md` to keep working. |
| `timeout-minutes`  | No       | `60`                      | Maximum minutes to let `opencode github run` execute before it is killed (uses `timeout`/`gtimeout` when available; otherwise runs without enforced timeout).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

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

The bundled `/review-pr` command is strictly read-only. It runs as the dedicated `review-pr-orchestrator` agent, whose permissions deny `edit` and `skill` outright and deny every `bash` and subagent `task` invocation except an explicit allow-list of non-mutating commands (`git status`/`git diff`, the read-only `gh` wrapper, the worktree guard, the review-submission helper, and the ten approved reviewer agents). Every reviewer agent likewise denies `edit`, `bash`, `task`, and `skill` in its own frontmatter, so a reviewer cannot format, generate, install, or otherwise mutate files even if instructed to. `/review-pr` never runs repository QA scripts, formatters, auto-fixing linters, generators, or dependency installers, and `/review-pr simplify` is refused outright rather than dispatched to `code-simplifier`.

Because OpenCode merges project-level `.opencode/` config from the checked-out repository over the global config, a pull request could otherwise ship its own `.opencode/commands/review-pr.md` or `.opencode/agents/review-pr-orchestrator.md` and replace this entire read-only boundary with a permissive one. Set `review-only: true` on a dedicated review-only workflow entrypoint (see the example below) to have the action set `OPENCODE_DISABLE_PROJECT_CONFIG=1` for the run, so only the toolkit installed by the action into `~/.config/opencode` before checkout is ever loaded; the reviewed repository's own `.opencode/` directory is ignored entirely. This is a separate input from `enable-toolkit` because `OPENCODE_DISABLE_PROJECT_CONFIG` also skips project-level `AGENTS.md`, which mutation-capable workflows (for example `/oc fix ...`) still need.

`review-only: true` fails the run fast, before OpenCode is even installed, unless `enable-toolkit` is also `true`, `agent` is the default `build` or explicitly `review-pr-orchestrator`, and `prompt` explicitly invokes `/review-pr`. A mention-triggered or unset prompt is rejected in `review-only` mode because it would otherwise let arbitrary comment-supplied text run under the default agent, bypassing the read-only boundary entirely. `enable-toolkit: true` combined with `review-only: true` also installs the bundled toolkit into a fresh `~/.config/opencode`, replacing any pre-existing content there first, and clears any pre-existing `~/.opencode/` content other than the cached `bin/` directory, since OpenCode always loads both paths regardless of `OPENCODE_DISABLE_PROJECT_CONFIG`; without this, a stale or self-hosted-runner-persisted file at either path could remain authoritative instead of the version this action installs. Outside `review-only`, `enable-toolkit` preserves pre-existing content at both paths instead, so mutation-capable workflows keep persisted customizations on self-hosted runners. Every reviewer agent and the orchestrator also deny the `lsp` permission, since OpenCode's LSP integration can download and execute repository-local language server binaries outside the `bash` permission model.

**Known limitation:** `review-only` enforces a read-only boundary inside the OpenCode agent run (permissions, the worktree guard, and the input validation above), but it does not currently disable `opencode github run`'s own automatic branch commit/push, which runs after the agent returns control. The installed OpenCode CLI (checked at v1.17.17) exposes no flag or environment variable to suppress that behavior. The worktree guard fails the run if it detects any mutation before a review is submitted, which covers agent-caused drift, but cannot prevent the CLI's own push step from acting on a dirty worktree it discovers independently. Track this gap before treating `review-only` as a complete enforcement boundary for untrusted PRs; see [issue #24](https://github.com/dceoy/opencode-action/issues/24).

Every helper `/review-pr` invokes — the worktree guard, the read-only `gh` wrapper, the review-submission helper, and the App-token resolver they source — is invoked only by its `~/.config/opencode/scripts/` path, never by a repository-relative path, for the same reason: the checkout under review is untrusted and could otherwise ship a same-named script of its own.

As defense in depth, `/review-pr` snapshots the repository worktree (`bash "$HOME/.config/opencode/scripts/review-pr-worktree-guard.sh" snapshot`) before dispatching any reviewer and re-verifies that snapshot (`... verify`) after every reviewer completes and immediately before every GitHub write. The guard compares tracked-file diffs, the index, and untracked-file content hashes; any mutation — including a generated file such as Checkov's `github_conf/branch_protection_rules.json` — fails the run instead of being committed, pushed, or published. The guard only ever reads state and reports a mismatch; it never runs `git add`, `commit`, `push`, `reset`, `restore`, `clean`, `stash`, `checkout`, `switch`, `merge`, or `rebase`.

`/review-pr` reads PR metadata and diff through a wrapper (`.opencode/scripts/review-pr-gh.sh`) that best-effort prepares a candidate OpenCode App token before calling `gh`, so the default `use-github-token: false` path does not fall back to a shallow local diff when `gh` would otherwise be unauthenticated. `/review-pr` submits a GitHub pull request review through `gh api`, using a separate constrained helper script (`.opencode/scripts/review-pr-submit.sh`) that validates the repository name, PR number, review ID, payload location, and payload schema before every write. It uses inline review comments for every finding that can be safely anchored to the PR diff, and includes only unanchorable findings in the review body as summary-only fallback items when at least one inline comment is submitted. If no finding can be anchored inline, `/review-pr` returns a top-level markdown fallback instead. When there are no summary-only findings, the review body is a single line (`OpenCode PR Review: <N> inline finding(s).`) with no empty "Summary-only findings" section.

A successful structured review run produces one GitHub review summary (with its inline comments), which `/review-pr` updates in place with the run link. `/review-pr` never calls `gh pr comment` or the issue comment API itself. It may still return a short final assistant message after submitting the review; `opencode github run` posts that as a separate top-level completion comment, so a run can produce the review plus at most one additional completion comment — not necessarily exactly one top-level artifact.

The bundled toolkit ships an `external_directory` permission in `.opencode/opencode.jsonc` (copied into `~/.config/opencode/` with the rest of the toolkit) that denies by default, so a stray attempt to read outside the checked-out repository, such as inspecting `/opt/pipx/logs/*` after a failed tool install, is denied immediately instead of blocking on the default "ask" prompt, which nothing can answer in a non-interactive GitHub Actions run and would otherwise hang until `timeout-minutes` kills it. The narrow exceptions are the four scripts above (`resolve-app-token.sh`, `review-pr-worktree-guard.sh`, `review-pr-submit.sh`, and `review-pr-gh.sh`) at their exact `~/.config/opencode/scripts/` paths; no other external path is permitted.

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
    review-only: true
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

`/review-pr simplify` is unavailable: `/review-pr` is strictly read-only, so simplification-style edits must go through an explicitly mutation-capable workflow such as `/oc fix ...` instead of `code-simplifier`.

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
