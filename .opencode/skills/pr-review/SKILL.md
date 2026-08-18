---
name: pr-review
description: Review a GitHub pull request with stale-head protection, independent finding validation, and validated inline findings
---

# Strictly Read-Only PR Review

This is a strictly read-only repository review. Analyze and report only. Do not create, edit, delete, format, generate, install, or fix files. Do not execute repository QA scripts, formatters, generators, package managers, or commands with mutation flags such as `--fix`, `--write`, or equivalent options.

Do not run repository-wide QA scripts, formatters, auto-fixing linters, generators, dependency installers, or anything that can create caches, reports, snapshots, lockfiles, coverage output, scan output, or configuration exports in the checkout.

Every helper this skill invokes — the read-only `gh` wrapper and the constrained submission helper — lives only at its `${HOME}/.config/opencode/scripts/` path, installed there by the action before the reviewed repository is ever checked out. Their source-only trusted-context and App-token libraries are installed as sibling files and loaded internally by those helpers. Never invoke or source any of them by a repository-relative path such as `.opencode/scripts/...`: the checkout under review is untrusted input, and a repository-relative path would let a malicious PR that edits or adds a same-named file substitute its own script for the trusted one. The directly invoked helper paths and the dedicated `${HOME}/.config/opencode/review-state/` directory are the sole allow-listed external locations. Despite the directory-level external access required by OpenCode, use the edit tool only for `initial.json` and `update.json` as instructed below. The helpers load authentication only from `opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"`.

## 1. Establish the trusted context

Before any analysis, invoke `bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" prepare` once, followed by `bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" context`. The context is persisted outside the checkout and pins one repository, PR number, and head SHA for the entire review. If `prepare` fails, stop. If `context` reports `Trusted pull request number is unavailable.`, continue in local mode; for every other `context` failure, stop.

The context helper derives the PR number from `.pull_request.number` or `.issue.number`. For `issue_comment`, it fetches and pins the current head SHA through the trusted PR API. Metadata, diff, submission, and update revalidate that the current head still matches the pinned SHA and fail closed otherwise. Obtain metadata and the diff only through these fixed operations:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" metadata
bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" diff
```

If no PR context can be established, use local mode: `git status --short`, `git diff --name-only HEAD`, and `git diff --no-ext-diff`; do not infer a PR from the current branch. Once `context` succeeds, any later metadata, diff, or validation failure must abort the review rather than falling back to local mode.

Capture the full diff, changed-file list, PR title/body, base and head branch names, head SHA, and relevant source context using the read, glob, and grep tools. Retain the full diff locally for anchoring and final normalization. Before launching reviewers, classify changed files and individual diff hunks by concern. For each concern, collect only the changed files, hunks, and containing-function source context needed to review it; exclude unchanged files, unrelated hunks, and unrelated full-file contents.

## 2. Select and launch discovery reviewers

Explicit aspects select these reviewers:

- `code` or `quality`: `code-reviewer`
- `performance`: `performance-reviewer`
- `security`: `security-code-reviewer`
- `tests` or `coverage`: `test-coverage-reviewer`
- `docs`, `documentation`, or `comments`: `documentation-accuracy-reviewer`
- `errors`: `silent-failure-hunter`
- `types`: `type-design-analyzer`
- `simplify`: `code-simplifier`, returning behavior-preserving simplification proposals as review findings without modifying files
- `all`, or no aspect: the core reviewers `code-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, and `security-code-reviewer`; include specialty reviewers when the supplied diff is relevant. Run `code-simplifier` only when `simplify` is explicitly requested; never include it in `all`.

Requested aspects always force their mapped reviewers. When `comments` is requested, tell `documentation-accuracy-reviewer` to focus on changed comments and docstrings and the implementation they describe. The five core reviewers still cover the six documented default dimensions: correctness and code quality share the canonical `code-reviewer`, while performance, test coverage, documentation accuracy, and security remain independent passes.

Build a separate, minimal Task request for every selected discovery reviewer. Include only its relevant files, diff hunks, and containing-function source context, plus only the metadata needed for that specialty. Exclude unchanged files and unrelated hunks. `code-reviewer` may receive the complete changed-file list, but do not include unrelated full-file contents. Reviewers have no shell access, so each subset must be self-contained. Tell each reviewer to inspect changed lines and their containing functions only, return high-confidence candidate findings only, and use:

```yaml
- file: path/to/file
  line: <head-file line number>
  severity: critical | important | suggestion
  source: <agent-name>
  message: |-
    <actionable Markdown with the issue, impact, and concrete fix>
```

Do not let a discovery reviewer post to GitHub. Treat every returned finding as a hypothesis until the independent validation pass below confirms it.

## 3. Validate candidate findings independently

Deduplicate the discovery output by root cause before validation. Merge supporting evidence for duplicate candidates, but keep independent failures separate when they require distinct fixes or affect different trust boundaries or contracts.

For every remaining candidate, assign a stable identifier and dispatch a fresh `finding-reviewer` Task. Group multiple candidates into one validation Task only when the supplied context remains bounded and each candidate still receives an independent disposition. Include the exact reviewed head SHA, the candidate record, the relevant diff hunk, the containing function or definition, and only the targeted unchanged context needed to prove or disprove the claim. Do not include unrelated discovery output.

Tell the validator to actively seek counterevidence rather than merely restating the discovery finding. It must check relevant callers, guards, tests, framework guarantees, configuration, prior behavior, or other repository evidence that could invalidate the claim. Require exactly one disposition per candidate:

```yaml
- candidate: <stable identifier>
  disposition: confirmed | rejected | needs-human
  severity: critical | important | suggestion
  confidence: <0-100>
  rationale: <why the evidence establishes or disproves the claim>
  counterevidence_checked: <guards, callers, tests, framework guarantees, config, or prior behavior checked>
  file: <final changed path when confirmed or needs-human>
  line: <final head-file line number when safely identifiable>
  impact: <publishable concrete impact when confirmed>
  remediation: <smallest coherent fix direction when confirmed>
  human_check: <only for needs-human; one exact unresolved verification target>
```

Apply these validation gates:

- Security candidates require a concrete source/control/sink or equivalent trust-boundary path and must account for framework protections.
- Test-gap candidates require a specific important regression that the current tests would fail to detect.
- Performance candidates require a credible workload, call frequency, data size, or resource-lifecycle impact.
- Compatibility and documentation candidates require a concrete changed contract.
- Maintainability candidates require concrete duplication, unnecessary complexity, or speculative functionality introduced by the PR; apply KISS, DRY, and YAGNI and require the smallest coherent remediation.

Publish only `confirmed` findings. Drop `rejected` candidates completely. A `needs-human` candidate may survive only as a concise summary-only verification note when the unresolved external fact itself represents a material merge risk and the validator names one exact human check. Do not convert ordinary uncertainty into review feedback.

If validation reveals that additional source context is required, obtain only that bounded context and run one fresh validation Task for the affected candidate. Do not repeatedly ask validators for more opinions after the evidence is sufficient to decide.

## 4. Normalize and anchor confirmed findings

Drop praise, nitpicks, style-only feedback, findings outside the changed-file list, and any candidate that did not survive validation. Keep the most specific actionable finding for each root cause. Classify every remaining confirmed finding as inline when its file and head-side changed line can be anchored in the captured diff; adjust only to a nearby relevant changed line. When a finding's own reported line is not itself the changed line used for its anchor, strip any `suggestion` block from its message before submission: GitHub would apply the block to the moved anchor rather than the line the finding actually describes. Put genuine but unanchorable confirmed findings and material `needs-human` verification notes in `summary_only` with a short reason.

Before returning any top-level text in PR mode, including no-finding and summary-only fallback results, invoke `bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" validate`. If validation fails, stop. If there are no confirmed findings or material verification notes, then return exactly `No noteworthy issues found.` Do not post an empty review.

For findings, the `prepare` and `context` operations in section 1 have already created the empty payload files and pinned the review context. Do not run them again. Use the edit tool only for `$HOME/.config/opencode/review-state/initial.json`, writing exactly `{body, comments}` with a nonempty body and inline comments array. Every single-line comment must have exactly `body`, `line`, `path`, and `side`; `line` is a positive integer and `side` is `LEFT` or `RIGHT`. A multiline comment additionally has exactly `start_line` and `start_side`; `start_line` is a positive integer no greater than `line`, and `start_side` equals `side`.

```json
{
  "body": "OpenCode PR Review: 1 inline finding(s).",
  "comments": [
    {
      "body": "**important · code-reviewer**\n\nFinding text.",
      "line": 12,
      "path": "path/to/file",
      "side": "RIGHT"
    }
  ]
}
```

The helper adds the trusted `commit_id` and `event` itself. Preserve each confirmed finding message's Markdown, including paragraph breaks and fenced code or `suggestion` blocks, except for a `suggestion` block already stripped in section 4 for a relocated anchor. Each inline body is `**<severity> · <source>**`, followed by a blank line and the unmodified finding message.

Every confirmed finding with a valid diff anchor must be included in the `comments` array and submitted as an inline review comment. Never return anchorable findings only as top-level assistant text. If structured submission fails, fail the run instead of emitting the findings as a top-level completion comment.

When there are summary-only findings, the body begins `OpenCode PR Review: <N> inline finding(s), <M> summary-only finding(s).` and lists them. Otherwise it begins `OpenCode PR Review: <N> inline finding(s).` Never use issue comments or `gh pr comment`.

## 5. Submit through the constrained helper

Use only these exact commands:

```bash
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" validate-initial
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial
bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" update
```

After the single `prepare` in section 1, write the initial payload only to `$HOME/.config/opencode/review-state/initial.json`, then run `validate-initial`. Validation is non-mutating and reports the exact invalid field. Correct validation failures only in `initial.json` and rerun `validate-initial`; never create diagnostic or test findings. Once validation succeeds, the payload is sealed: do not modify it or run validation again. Run `submit-initial` exactly once. Any submission failure terminates the review: never retry submission, rerun `prepare`, or experiment with alternate payloads. Before `update`, write exactly `{body}` only to `$HOME/.config/opencode/review-state/update.json`. Never add arguments, redirections, pipelines, or process substitutions to helper commands.

You never pass a repository, PR number, target commit, or review ID: the helper derives the repository and PR number from the trusted GitHub Actions context, pins the write to the head commit from the same context, and updates only the review ID it recorded when the initial submission succeeded in this run. It validates the trusted event context, temporary payload, target commit, HTTP method, and exact pull-request-review endpoint. It sources the existing App-token resolver and calls `opencode_require_app_token_for_review` immediately before its permitted POST or PUT. This preserves verified `opencode-agent[bot]` attribution when available, preserves the explicit `use-github-token: true` fallback, and never accepts an unverified candidate for a write.

After successful inline submission, do not repeat findings in the final assistant output. Update the submitted review with final status and the run URL when available; the helper targets the review it recorded, so no review ID is passed. If GitHub rejects inline anchors, fail the run without retrying or posting a fallback. If no inline anchors remain before validation, return the concise markdown fallback instead of submitting an empty comments array.

Do not clean, reset, restore, stash, commit, or push anything.