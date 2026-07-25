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

## Read-only behavior

Review-only mode does not modify the checkout, run mutating repository commands, or allow reviewer agents to post directly to GitHub. It uses action-installed configuration and trusted helpers, and aborts if the pinned pull request context changes.

See [Security model](security-model.md) for trust boundaries, token verification, and fail-closed behavior.
