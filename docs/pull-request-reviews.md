# Pull request reviews

The bundled `/review-pr` command runs a read-only, multi-agent review and submits validated findings through GitHub's pull request review API.

## Requirements

A review workflow must provide:

- OpenCode 1.2.14 or newer
- `enable-toolkit: true`
- `pull-requests: write`
- an API key for the selected model provider with available credits or quota

When `use-github-token: true`, also pass `GH_TOKEN` or `GITHUB_TOKEN` and grant the workflow token the permissions required for the requested work.

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

## Review aspects

Use one or more aspect keywords after `/review-pr`:

| Command                           | Reviewers                                                                                       |
| --------------------------------- | ----------------------------------------------------------------------------------------------- |
| `/review-pr` or `/review-pr all`  | Core reviewers plus specialty reviewers selected for the diff                                  |
| `/review-pr security performance` | `security-code-reviewer`, `performance-reviewer`                                                 |
| `/review-pr tests docs`           | `test-coverage-reviewer`, `pr-test-analyzer`, `documentation-accuracy-reviewer`                  |
| `/review-pr code`                 | `code-reviewer`, `code-quality-reviewer`                                                         |
| `/review-pr quality`              | `code-quality-reviewer`                                                                         |
| `/review-pr coverage`             | `test-coverage-reviewer`, `pr-test-analyzer`                                                     |
| `/review-pr documentation`        | `documentation-accuracy-reviewer`                                                                |
| `/review-pr errors`               | `silent-failure-hunter`                                                                         |
| `/review-pr comments`             | `comment-analyzer`                                                                              |
| `/review-pr types`                | `type-design-analyzer`                                                                          |
| `/review-pr simplify`             | `code-simplifier`, returning read-only, behavior-preserving simplification suggestions          |

A full review always includes the core reviewers:

- `code-quality-reviewer`
- `performance-reviewer`
- `test-coverage-reviewer`
- `documentation-accuracy-reviewer`
- `security-code-reviewer`
- `code-reviewer`

Specialty reviewers are added when the changed files make them relevant. `code-simplifier` runs only when `simplify` is explicitly requested.

## Finding processing

Each reviewer receives the pull request metadata, changed-file list, diff, and relevant source context. Reviewers inspect changed lines and their containing functions and return only high-confidence, actionable findings.

The orchestrator then:

1. drops praise, nitpicks, style-only feedback, and findings outside changed files
2. deduplicates findings that share the same root cause
3. validates each finding against the captured diff
4. anchors findings to changed lines when possible
5. keeps genuine but unanchorable findings as summary-only items

Inline comments use the finding severity and source agent in the comment body. If no noteworthy findings remain, the command does not submit an empty review.

## Submission behavior

A successful structured run creates one GitHub review containing:

- inline comments for findings that can be anchored to the diff
- a review body containing only summary-only findings, when present
- a concise count when every finding is inline

The submitted review is updated in place with the workflow run link. The `/review-pr` command does not call `gh pr comment` or GitHub's issue comment API.

`opencode github run` may still post the command's final assistant message as one separate top-level completion comment. A run can therefore produce the structured review and at most one additional completion comment.

If no finding can be anchored, the command returns a concise top-level Markdown fallback instead of submitting an empty structured review. If GitHub rejects an inline anchor, the command retries once after moving the rejected item to the summary-only section.

A structured submission failure fails the workflow. Findings are not repeated as an unstructured top-level comment after a failed submission.

## Read-only guarantees

The review workflow is designed to analyze and report only. It must not:

- edit, create, delete, format, or generate repository files
- run package managers, installers, generators, formatters, or mutation flags such as `--fix` or `--write`
- commit, reset, restore, stash, or push changes
- let reviewer agents post directly to GitHub

The action installs a fresh trusted OpenCode configuration for review-only runs and ignores project-provided OpenCode configuration. Trusted helper scripts are invoked only from the action-installed global configuration, never from repository-relative paths.

The review context pins the repository, pull request number, and head commit before analysis. Metadata, diff retrieval, validation, submission, and review updates fail closed if the pull request head changes.

See [Security model](security-model.md) for external-directory restrictions, credential verification, and token precedence.
