# Pull request reviews

The bundled `/review-pr` flow runs a strictly read-only, risk-driven multi-agent review and submits validated findings through GitHub's pull request review API. The command is the supported entrypoint: it selects the dedicated `review-pr-orchestrator` primary agent and loads the internal `pr-review` skill.

`pr-review` contains the review procedure, while `review-pr-orchestrator` contains the permission boundary. Loading the skill directly into another primary agent does not transfer those permissions, so direct skill loading must not be treated as an enforced read-only review path. The skill is marked non-slash and non-autoinvokable for OpenCode v2 discovery; the command remains the explicit review entrypoint.

## Setup

Review workflows require OpenCode 1.2.14 or newer, `use-bundled-toolkit: true`, `pull-requests: write`, and an API key for the selected model provider. The bundled Sakura provider's `chunkTimeout` setting requires OpenCode 1.2.25 or newer; pins between 1.2.14 and 1.2.24 fall back to the top-level request `timeout` instead of the inter-chunk timeout. Request, chunk, and action timeouts are safety limits, not substitutes for bounding request size, and `chunkTimeout` cannot guarantee that a provider-side gateway or inference timeout will not end a request sooner.

Start from the pinned workflow in the [README quick start](../README.md#quick-start), then grant pull-request write access and configure the OpenCode step for review mode. The copied job remains triggered by `/oc` or `/opencode`; the fixed `prompt` below makes either accepted mention run `/review-pr`.

Set the workflow permissions:

```yaml
permissions:
  contents: read
  pull-requests: write
  id-token: write
```

Then configure the `Run OpenCode` step from the README quick start:

```yaml
env:
  OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
  GITHUB_TOKEN: ${{ github.token }}
with:
  model: openrouter/openrouter/free
  prompt: /review-pr
```

For a smaller caller workflow, use the bundled [`opencode-review.yml` reusable workflow](reusable-workflows.md#pull-request-review).

When `use-github-token: true`, pass `GH_TOKEN` or `GITHUB_TOKEN` and grant the workflow token the required permissions.

## Review aspects

To select review aspects in this fixed-prompt setup, set `prompt` to `/review-pr` followed by one or more keywords:

| Command                           | Focus                                |
| --------------------------------- | ------------------------------------ |
| `/review-pr` or `/review-pr all`  | Full review                          |
| `/review-pr security performance` | Security and performance             |
| `/review-pr tests docs`           | Test coverage and documentation      |
| `/review-pr code`                 | Correctness and code quality         |
| `/review-pr quality`              | Code quality                         |
| `/review-pr coverage`             | Test coverage                        |
| `/review-pr documentation`        | Documentation accuracy               |
| `/review-pr errors`               | Silent failures and error handling   |
| `/review-pr comments`             | Comment and docstring accuracy       |
| `/review-pr types`                | Type design                          |
| `/review-pr simplify`             | Read-only simplification suggestions |

An unscoped review first builds a change and risk map, covers baseline correctness, regression, tests, and documentation, then adds only lenses justified by the actual diff. It typically creates 2-6 dynamically named discovery tasks such as `authorization-boundary`, `migration-integrity`, `async-cleanup`, or `workflow-permissions`; these are task roles, not fixed agent identities. Explicit aspects are hard scope constraints rather than routes to specialist agent files.

The current OpenCode v1-compatible runtime uses one hidden `review-worker` subagent definition with read/glob/grep permissions only. Each discovery task launches a fresh worker session, and every surviving candidate is checked in a separate fresh validation session that actively seeks counterevidence before the parent may publish it. When OpenCode v2's built-in read-only `explore` contract becomes the action runtime boundary, this compatibility worker can be removed without changing the review procedure.

## Finding and submission behavior

The parent primary agent retains the full pull request context for anchoring and normalization while each child receives only a bounded packet for its specific risk hypothesis. The review flow then:

1. maps changed behavior and chooses only justified review lenses
2. dispatches fresh read-only discovery tasks with bounded context
3. deduplicates candidates by root cause
4. validates candidates independently as `confirmed`, `rejected`, or `needs-human`
5. arbitrates confirmed findings against the captured diff
6. posts anchorable confirmed findings as inline review comments and keeps genuine unanchorable findings in the review body

A successful run validates the complete payload without a GitHub write, then creates one structured GitHub review and updates its body with the workflow run link. The validated payload is sealed against later edits, and the live initial submission can be attempted only once per run. `/review-pr` does not post through `gh pr comment` or the issue comment API.

If no finding can be anchored, the command returns a concise Markdown fallback instead of an empty review. Validation identifies missing or invalid fields before submission. Submission failures fail the workflow without a retry rather than risking an unintended review artifact or reposting findings as an unstructured comment.

`opencode github run` may separately post the command's final completion message, so a run can produce the structured review plus at most one top-level completion comment.

## Security

`opencode-action` treats the repository checkout, project OpenCode configuration, pull request content, and unverified git credentials as untrusted.

### Review isolation

When the effective prompt starts with `/review-pr`, the action installs a fresh bundled OpenCode configuration, disables project-provided configuration and externally discovered skills, removes inherited plugins and agents, and resolves the review command only from the action bundle.

The bundled global OpenCode config does not grant trusted review paths to every agent. External-directory access to the fixed review helpers and dedicated state directory under `~/.config/opencode/` is allowed only by the `review-pr-orchestrator` permission profile. The read-only worker has no shell or edit permission. The helpers source the trusted-context and token-resolution libraries only from their installed sibling paths; repository-controlled files never enter that execution path.

### Trusted pull request context

One shared trusted-context helper derives the repository and pull request number from the GitHub Actions event and pins a base/head SHA pair for both read and write helpers. It captures event metadata for `pull_request` runs or obtains metadata and both SHAs together for `issue_comment` runs, so the saved metadata belongs to the immutable snapshot. The changed-file list is captured from the pinned comparison; if GitHub's comparison response reaches its 300-file limit, context fails closed rather than saving incomplete file metadata. The diff helper reads only the pinned `base_sha...head_sha` comparison. The submission helper validates the pinned head commit immediately before the write and repeats that readability check after token verification. If the live pull request head advances after the snapshot is captured, the run still submits against the pinned commit; GitHub may render affected comments as outdated, which is intentional.

### Trusted host boundary

Review isolation assumes the runner host and its administrator-controlled OpenCode state are trusted. The action clears project/caller review configuration and inherited toolkit state, but it does not attempt to reproduce OpenCode's full external, managed, plugin, or remote configuration discovery. Variant prevalidation therefore uses the bundled registry only when the isolated environment is conservatively known to make that registry authoritative; otherwise the requested variant is passed through unchanged. Use trusted or ephemeral runners for review workflows.

### Token verification and precedence

The default OIDC flow supplies an OpenCode GitHub App installation token. Credentials discovered through git configuration remain untrusted until their identity is verified.

Before a structured review write, the action creates an empty pending review with each candidate, verifies that its author is `opencode-agent[bot]`, and immediately deletes it. The probe is not published, but it is a real create-and-delete API operation. Tokens and decoded authorization headers are never printed.

Structured writes use this precedence:

1. the first candidate verified as `opencode-agent[bot]`
2. the caller's existing `GH_TOKEN` or `GITHUB_TOKEN` only when `use-github-token: true`
3. otherwise, fail without submitting a review

The explicit workflow-token fallback may make reviews appear under `github-actions[bot]` or another identity associated with that token. Unverified candidates may be used for read-only metadata access but never pass the structured-write gate.

### Fail-closed behavior

Review-only mode fails rather than weakening its guarantees when:

- the bundled toolkit is disabled or the OpenCode version is unsupported
- trusted pull request context cannot be established
- the pinned commit or comparison cannot be read
- no App token verifies and workflow-token fallback was not explicitly enabled
- review payload validation or structured submission fails
- the `~/.opencode` state directory is a symlink, checked before the OpenCode binary is cached or installed, since cleaning or reusing it would otherwise write through the link
