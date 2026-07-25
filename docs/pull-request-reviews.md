# Pull request reviews

The bundled `/review-pr` command runs a read-only, multi-agent review and submits validated findings through GitHub's pull request review API.

## Setup

Review workflows require OpenCode 1.2.14 or newer, `enable-toolkit: true`, `pull-requests: write`, and an API key for the selected model provider.

```yaml
permissions:
  contents: read
  pull-requests: write
steps:
  - name: Run OpenCode review
    uses: dceoy/opencode-action@419cdd50ed88bd77dd429ebb683e8d18b03ac89a # v0.4.0
    env:
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
      GITHUB_TOKEN: ${{ github.token }}
    with:
      model: openrouter/openrouter/free
      prompt: /review-pr
```

When `use-github-token: true`, pass `GH_TOKEN` or `GITHUB_TOKEN` and grant the workflow token the required permissions.

## Review aspects

Use one or more keywords after `/review-pr`:

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
| `/review-pr comments`             | Comment accuracy                     |
| `/review-pr types`                | Type design                          |
| `/review-pr simplify`             | Read-only simplification suggestions |

A full review runs the core quality, performance, coverage, documentation, security, and correctness reviewers. Specialty reviewers are added when relevant to the diff. The simplifier runs only when explicitly requested.

## Finding and submission behavior

The orchestrator receives the pull request metadata, changed-file list, diff, and relevant source context. It then:

1. keeps only high-confidence, actionable findings on changed files
2. removes style-only feedback and duplicates
3. validates findings against the captured diff
4. posts anchorable findings as inline review comments
5. keeps genuine unanchorable findings in the review body

A successful run creates one structured GitHub review and updates its body with the workflow run link. `/review-pr` does not post through `gh pr comment` or the issue comment API.

If no finding can be anchored, the command returns a concise Markdown fallback instead of an empty review. Invalid inline anchors are retried once as summary-only findings. Submission failures fail the workflow rather than reposting findings as an unstructured comment.

`opencode github run` may separately post the command's final completion message, so a run can produce the structured review plus at most one top-level completion comment.

## Security

`opencode-action` treats the repository checkout, project OpenCode configuration, pull request content, and unverified git credentials as untrusted.

### Review isolation

When the effective prompt starts with `/review-pr`, the action installs a fresh bundled OpenCode configuration, disables project-provided configuration, removes inherited plugins and agents, and resolves the review command only from the action bundle.

External-directory access is denied by default. Only the trusted review helpers and their dedicated state directory under `~/.config/opencode/` are allowed. Review-only mode does not modify the checkout, run mutating repository commands, or allow reviewer agents to post directly to GitHub.

### Trusted pull request context

The helpers derive the repository and pull request number from the GitHub Actions event and pin the pull request head SHA before analysis. The submission helper validates the event context, pinned commit, payload shape, and target endpoint. If the pull request head changes after the diff is captured, the run fails before submitting stale findings.

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
