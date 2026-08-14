# Pull request reviews

The bundled `pr-review` skill runs a read-only, multi-agent review and submits validated findings through GitHub's pull request review API. The `/review-pr` command remains a thin wrapper that loads the skill and forwards any requested review aspects.

Agents can also load `pr-review` directly through OpenCode's native skill tool, but only `/review-pr` carries the read-only guarantees below: those come from `review-pr-orchestrator`'s `permission` config (denying edit and unrestricted `bash`), which only applies when the command routes to that agent. Loading the skill directly injects the same instructions into whatever agent calls it, and that agent's own permissions still apply, so the read-only behavior is advisory rather than enforced.

## Setup

Review workflows require OpenCode 1.2.14 or newer, `use-bundled-toolkit: true`, `pull-requests: write`, and an API key for the selected model provider. The bundled Sakura provider's `chunkTimeout` setting requires OpenCode 1.2.25 or newer; pins between 1.2.14 and 1.2.24 fall back to the top-level request `timeout` instead of the inter-chunk timeout. Request, chunk, and action timeouts are safety limits, not substitutes for bounding request size, and `chunkTimeout` cannot guarantee that a provider-side gateway or inference timeout will not end a request sooner.

Start from the pinned workflow in the [README quick start](../README.md#quick-start), then grant pull-request write access and configure the OpenCode step for review mode. The copied job remains triggered by `/oc` or `/opencode`; the fixed `prompt` below makes either accepted mention run `/review-pr`:

```yaml
permissions:
  contents: read
  pull-requests: write
  id-token: write

# In the Run OpenCode step from the README quick start:
env:
  OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
  GITHUB_TOKEN: ${{ github.token }}
with:
  model: openrouter/openrouter/free
  prompt: /review-pr
```

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

A full review uses five core reviewers to cover six dimensions: correctness and code quality share the canonical code reviewer, while performance, test coverage, documentation accuracy, and security each retain a dedicated reviewer. Comments and docstrings are part of the documentation-accuracy review rather than a separate reviewer pass. Explicit `comments` requests focus that reviewer on changed comments/docstrings and the implementation they describe. Specialty reviewers are added when relevant to the diff, and the simplifier runs only when explicitly requested.

## Finding and submission behavior

The orchestrator retains the full pull request context for anchoring and normalization, but classifies files and hunks before delegation. Each reviewer receives only its relevant diff subset and containing-function context. The orchestrator then:

1. keeps only high-confidence, actionable findings on changed files
2. removes style-only feedback and duplicates
3. validates findings against the captured diff
4. posts anchorable findings as inline review comments
5. keeps genuine unanchorable findings in the review body

A successful run validates the complete payload without a GitHub write, then creates one structured GitHub review and updates its body with the workflow run link. The validated payload is sealed against later edits, and the live initial submission can be attempted only once per run. `/review-pr` does not post through `gh pr comment` or the issue comment API.

If no finding can be anchored, the command returns a concise Markdown fallback instead of an empty review. Validation identifies missing or invalid fields before submission. Submission failures fail the workflow without a retry rather than risking an unintended review artifact or reposting findings as an unstructured comment.

`opencode github run` may separately post the command's final completion message, so a run can produce the structured review plus at most one top-level completion comment.

## Security

`opencode-action` treats the repository checkout, project OpenCode configuration, pull request content, and unverified git credentials as untrusted.

### Review isolation

When the effective prompt starts with `/review-pr`, the action installs a fresh bundled OpenCode configuration, disables project-provided configuration and externally discovered skills, removes inherited plugins and agents, and resolves the review command only from the action bundle.

External-directory access is denied by default. Only the directly invoked trusted review helpers and their dedicated state directory under `~/.config/opencode/` are exposed to OpenCode. The helpers source the trusted-context and token-resolution libraries only from their installed sibling paths; repository-controlled files never enter that execution path. Review-only mode does not modify the checkout, run mutating repository commands, or allow reviewer agents to post directly to GitHub.

### Trusted pull request context

One shared trusted-context helper derives the repository and pull request number from the GitHub Actions event and validates the pinned pull request head SHA for both read and write helpers. The submission helper validates the same context immediately before the write and repeats the live-head check after token verification. If the pull request head changes after the diff is captured or while the token is being resolved, the run fails before submitting stale findings.

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
- the pull request head changes
- no App token verifies and workflow-token fallback was not explicitly enabled
- review payload validation or structured submission fails
- the `~/.opencode` state directory is a symlink, checked before the OpenCode binary is cached or installed, since cleaning or reusing it would otherwise write through the link
