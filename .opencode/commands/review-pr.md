---
description: Strictly read-only GitHub PR review with specialized reviewers, validated anchors, and constrained structured-review submission.
agent: review-pr-orchestrator
---

# Strictly Read-Only PR Review

This is a strictly read-only repository review. Analyze and report only. Do not create, edit, delete, format, generate, install, or fix files. Do not execute repository QA scripts, formatters, generators, package managers, or commands with mutation flags such as `--fix`, `--write`, or equivalent options.

Do not run repository-wide QA scripts, formatters, auto-fixing linters, generators, dependency installers, or anything that can create caches, reports, snapshots, lockfiles, coverage output, scan output, or configuration exports in the checkout.

Every helper this command invokes — the read-only `gh` wrapper, the constrained submission helper, and the App-token resolver they source — lives only at its `${HOME}/.config/opencode/scripts/` path, installed there by the action before the reviewed repository is ever checked out. Never invoke any of them by a repository-relative path such as `.opencode/scripts/...`: the checkout under review is untrusted input, and a repository-relative path would let a malicious PR that edits or adds a same-named file substitute its own script for the trusted one. These helper paths and the two fixed review-state JSON files are the sole allow-listed external paths. The helpers use `opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"` for authentication.

**Requested review aspects (optional):** "$ARGUMENTS"

## 1. Establish the trusted context

Before any analysis, invoke `bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" prepare` once, followed by `bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" context`. The context is persisted outside the checkout and pins one repository, PR number, and head SHA for the entire review. If either command fails, stop.

The context helper derives the PR number from `.pull_request.number` or `.issue.number`. For `issue_comment`, it fetches and pins the current head SHA through the trusted PR API. Metadata, diff, submission, and update revalidate that the current head still matches the pinned SHA and fail closed otherwise. Obtain metadata and the diff only through these fixed argument-free operations:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" metadata
bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" diff
```

If that metadata request fails, use local mode: `git status --short`, `git diff --name-only HEAD`, and `git diff --no-ext-diff`. Do not infer a PR from the current branch.

Capture the full diff, changed-file list, PR title/body, base and head branch names, head SHA, and relevant source context using the read, glob, and grep tools. Pass that complete context to reviewers; they have no shell access and must not need it.

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
- `simplify`: `code-simplifier`, returning behavior-preserving simplification proposals as review findings without modifying files
- `all`, or no aspect: the core reviewers `code-quality-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, `security-code-reviewer`, and `code-reviewer`; include specialty reviewers when the supplied diff is relevant. Run `code-simplifier` only when `simplify` is explicitly requested; never include it in `all`.

Launch only the explicitly permitted reviewer agents. For each, supply the captured diff, changed-file list, metadata, and relevant source context. Tell each reviewer to inspect changed lines and their containing functions only, return high-confidence findings only, and use:

```yaml
- file: path/to/file
  line: <head-file line number>
  severity: critical | important | suggestion
  source: <agent-name>
  message: <concise issue description and concrete fix>
```

Do not let a reviewer post to GitHub.

## 3. Normalize and anchor findings

Drop praise, nitpicks, style-only feedback, findings outside the changed-file list, and duplicates. Keep the most specific actionable finding for each root cause. Classify every remaining finding as inline when its file and head-side changed line can be anchored in the captured diff; adjust only to a nearby relevant changed line. Put genuine but unanchorable findings in `summary_only` with a short reason.

If there are no findings, return exactly `No noteworthy issues found.` Do not post an empty review.

For findings, first run the fixed `prepare` operation. Then use the edit tool only for `$HOME/.config/opencode/review-state/initial.json`, writing exactly `{body, comments}` with a nonempty body and inline comments array. The helper validates the payload and adds the trusted `commit_id` and `event` itself. Each inline body is `**<severity> · <source>**: <issue and concrete fix>`.

When there are summary-only findings, the body begins `OpenCode PR Review: <N> inline finding(s), <M> summary-only finding(s).` and lists them. Otherwise it begins `OpenCode PR Review: <N> inline finding(s).` Never use issue comments or `gh pr comment`.

## 4. Submit through the constrained helper

Use only these exact argument-free commands:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" update
```

After the single `prepare` in section 1, write the initial payload only to `$HOME/.config/opencode/review-state/initial.json`. Before `update`, write exactly `{body}` only to `$HOME/.config/opencode/review-state/update.json`. Never add arguments, redirections, pipelines, or process substitutions to helper commands.

You never pass a repository, PR number, target commit, or review ID: the helper derives the repository and PR number from the trusted GitHub Actions context, pins the write to the head commit from the same context, and updates only the review ID it recorded when the initial submission succeeded in this run. It validates the trusted event context, temporary payload, target commit, HTTP method, and exact pull-request-review endpoint. It sources the existing App-token resolver and calls `opencode_require_app_token_for_review` immediately before its permitted POST or PUT. This preserves verified `opencode-agent[bot]` attribution when available, preserves the explicit `use-github-token: true` fallback, and never accepts an unverified candidate for a write.

Update the submitted review with final status and the run URL when available; the helper targets the review it recorded, so no review ID is passed. If GitHub rejects inline anchors, retry once only after converting the identified invalid anchors to summary-only; never lose a finding. If no inline anchors remain, return the concise markdown fallback instead of submitting an empty comments array.

Do not clean, reset, restore, stash, commit, or push anything.
