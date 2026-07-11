---
description: Strictly read-only GitHub PR review with specialized reviewers, validated anchors, a worktree invariant, and constrained structured-review submission.
agent: review-pr-orchestrator
---

# Strictly Read-Only PR Review

This is a strictly read-only repository review. Analyze and report only. Do not create, edit, delete, format, generate, install, or fix files. Do not execute repository QA scripts, formatters, generators, package managers, or commands with mutation flags such as `--fix`, `--write`, or equivalent options.

The worktree guard is defense in depth and never authorizes mutations. Do not run a command merely because it is called a check, lint, test, or scan: it is permitted only when explicitly allow-listed and demonstrably non-mutating. In particular, never run repository-wide QA scripts, formatters, auto-fixing linters, generators, dependency installers, or anything that can create caches, reports, snapshots, lockfiles, coverage output, scan output, or configuration exports in the checkout.

Every helper this command invokes — the worktree guard, the read-only `gh` wrapper, the constrained submission helper, and the App-token resolver they source — lives only at its `${HOME}/.config/opencode/scripts/` path, installed there by the action before the reviewed repository is ever checked out. Never invoke any of them by a repository-relative path such as `.opencode/scripts/...`: the checkout under review is untrusted input, and a repository-relative path would let a malicious PR that edits or adds a same-named file substitute its own script for the trusted one. These exact external paths are the sole allow-listed exceptions to the default external-directory denial.

**Requested review aspects (optional):** "$ARGUMENTS"

If `$ARGUMENTS` contains `simplify`, stop immediately and say: `/review-pr simplify` is unavailable because `/review-pr` is strictly read-only. Use an explicitly mutation-capable workflow such as `/oc fix ...` for simplification. Do not invoke `code-simplifier`.

## 1. Establish the invariant and context

Before any analysis, invoke exactly:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-worktree-guard.sh" init
```

This records, in a protected per-run state directory outside the checkout, an initial snapshot of the pristine worktree bound to this run's repository, PR number, head commit, and run identifiers, all read from the trusted GitHub Actions context. If it fails, stop unsuccessfully. You do not pass its output anywhere: every later `verify` and the submission helper recompute the same state-directory path from the trusted context themselves.

Determine `PR_NUMBER` from `.pull_request.number` or `.issue.number` in `GITHUB_EVENT_PATH`; otherwise accept only `GITHUB_REF` matching `refs/pull/<positive number>/merge`. In PR mode, obtain metadata through the read-only `gh` wrapper, which best-effort prepares a candidate App token from `resolve-app-token.sh` before calling `gh` so the default `use-github-token: false` path does not fall back to a shallow local diff:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" pr view "$PR_NUMBER" --json number,title,body,baseRefName,headRefName,headRefOid,files,url
bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" pr diff "$PR_NUMBER"
```

If that metadata request fails, use local mode: `git status --short`, `git diff --name-only HEAD`, and `git diff --no-ext-diff`. Do not infer a PR from the current branch.

Capture the full diff, changed-file list, PR title/body, base and head branch names, head SHA, and relevant source context using the read, glob, grep, and LSP tools. Pass that complete context to reviewers; they have no shell access and must not need it.

## 2. Select and launch reviewers

Supported aspects are:

- `code`: `code-reviewer`, `code-quality-reviewer`
- `quality`: `code-quality-reviewer`
- `performance`: `performance-reviewer`
- `security`: `security-code-reviewer`
- `tests` or `coverage`: `test-coverage-reviewer`, `pr-test-analyzer`
- `docs` or `documentation`: `documentation-accuracy-reviewer`
- `comments`: `comment-analyzer`
- `errors`: `silent-failure-hunter`
- `types`: `type-design-analyzer`
- `all`, or no aspect: the core reviewers `code-quality-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, `security-code-reviewer`, and `code-reviewer`; include specialty reviewers when the supplied diff is relevant.

Launch only the explicitly permitted reviewer agents. For each, supply the captured diff, changed-file list, metadata, and relevant source context. Tell each reviewer to inspect changed lines and their containing functions only, return high-confidence findings only, and use:

```yaml
- file: path/to/file
  line: <head-file line number>
  severity: critical | important | suggestion
  source: <agent-name>
  message: <concise issue description and concrete fix>
```

Do not let a reviewer post to GitHub. After every reviewer completes, verify the invariant:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-worktree-guard.sh" verify
```

On failure, do not submit a review and terminate unsuccessfully.

## 3. Normalize and anchor findings

Drop praise, nitpicks, style-only feedback, findings outside the changed-file list, and duplicates. Keep the most specific actionable finding for each root cause. Classify every remaining finding as inline when its file and head-side changed line can be anchored in the captured diff; adjust only to a nearby relevant changed line. Put genuine but unanchorable findings in `summary_only` with a short reason.

If there are no findings, verify the invariant once more and return exactly `No noteworthy issues found.` Do not post an empty review.

For findings, build temporary payloads outside the checkout only with the constrained helper. The helper fills in `commit_id` from the trusted head commit itself, so you never pass it; the initial payload it builds always contains that `commit_id`, `event: "COMMENT"`, a nonempty body, and a nonempty inline `comments` array. Each inline body is `**<severity> · <source>**: <issue and concrete fix>`.

When there are summary-only findings, the body begins `OpenCode PR Review: <N> inline finding(s), <M> summary-only finding(s).` and lists them. Otherwise it begins `OpenCode PR Review: <N> inline finding(s).` Never use issue comments or `gh pr comment`.

## 4. Submit through the constrained helper

Immediately before every GitHub write, verify the invariant. The only allowed payload and GitHub-write helpers are:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" build-initial "$REVIEW_BODY" "$COMMENTS_JSON"
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" build-update "$UPDATED_REVIEW_BODY"
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial "$REVIEW_PAYLOAD"
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" update "$REVIEW_UPDATE_PAYLOAD"
```

You never pass a repository, PR number, target commit, or review ID: the helper derives the repository and PR number from the trusted GitHub Actions context, pins the write to the head commit from the same context, and updates only the review ID it recorded when the initial submission succeeded in this run. Before it acquires any write-capable credential, it re-verifies the worktree invariant and the per-run state binding authoritatively, then validates the temporary payload location and schema, HTTP method, and exact pull-request-review endpoint. It sources the existing App-token resolver and calls `opencode_require_app_token_for_review` immediately before its permitted POST or PUT. This preserves verified `opencode-agent[bot]` attribution when available, preserves the explicit `use-github-token: true` fallback, and never accepts an unverified candidate for a write.

Update the submitted review with final status and the run URL when available; the helper targets the review it recorded, so no review ID is passed. If GitHub rejects inline anchors, retry once only after converting the identified invalid anchors to summary-only; never lose a finding. If no inline anchors remain, return the concise markdown fallback instead of submitting an empty comments array.

Verify the invariant immediately before successful return. On any guard failure, print no success output and return unsuccessfully. Do not clean, reset, restore, stash, commit, or push anything.
