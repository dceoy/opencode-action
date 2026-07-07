---
name: review-pr
description: Run a comprehensive pull request review across changed files using Claude Code Action-compatible core reviewers and pr-review-toolkit specialty agents. Gathers the PR via gh, runs agents in parallel, normalizes and deduplicates findings, validates diff anchors, and submits GitHub inline review comments when findings can be anchored. Use when reviewing a PR before merge, before requesting review, after addressing feedback, or when the user asks to review a diff or recent changes.
---

# Comprehensive PR Review

Run a comprehensive pull request review by orchestrating specialized review agents, each focusing on one aspect of code quality. The orchestrator gathers the PR, spawns agents as subagents via the `task` tool, normalizes and deduplicates findings, validates every finding against the PR diff, and submits GitHub inline review comments for every diff-anchorable finding.

The surrounding `opencode github run` integration always posts the final assistant text to the PR. After a successful inline review submission, return only a short status message so the integration does not duplicate the full review as a top-level comment.

## When to Use

- A PR is open or about to open and needs a quality review pass.
- The user asks to review changes, a diff, or a pull request.
- Before requesting human review, before merge, or after addressing feedback.

Do not use this skill to triage existing review comments on a PR; use `pr-feedback-triage` instead.

## Inputs

- Optional review aspects requested by the user (see Supported Aspects below).
- A repository checkout with the changes to review. In GitHub Actions the skill derives the PR number from the event payload or pull request ref, then passes that number to `gh pr diff` and `gh pr view`; locally it uses `git diff` and `git status`.

If no aspects are specified, run all applicable reviews.

## Supported Aspects

| Aspect                    | Agent(s)                                     | Notes                                               |
| ------------------------- | -------------------------------------------- | --------------------------------------------------- |
| `code`                    | `code-reviewer`, `code-quality-reviewer`     | General code quality and guidelines compliance      |
| `quality`                 | `code-quality-reviewer`                      | Clean code, edge cases, robustness, type safety     |
| `performance`             | `performance-reviewer`                       | Bottlenecks, N+1 queries, resource leaks            |
| `security`                | `security-code-reviewer`                     | Trust boundaries, injection, secrets, auth/authz    |
| `tests` or `coverage`     | `test-coverage-reviewer`, `pr-test-analyzer` | Missing tests, brittle tests, coverage gaps         |
| `docs` or `documentation` | `documentation-accuracy-reviewer`            | README, API docs, docstrings, examples accuracy     |
| `comments`                | `comment-analyzer`                           | Code comment accuracy and maintainability           |
| `errors`                  | `silent-failure-hunter`                      | Silent failures, broad catch blocks, error handling |
| `types`                   | `type-design-analyzer`                       | Type design and invariant expression                |
| `simplify`                | `code-simplifier`                            | Refinement only — does not return a review          |
| `all` (default)           | All applicable (see below)                   | Deterministic full review                           |

## Deterministic `all` Behavior

When `all` is requested or no aspect is specified, the following **core reviewers** run unconditionally:

1. `code-quality-reviewer` — Claude Code Action-compatible: general quality, edge cases, robustness
2. `performance-reviewer` — algorithmic complexity, N+1, resource leaks
3. `test-coverage-reviewer` — Claude Code Action-compatible: missing critical tests and brittle tests
4. `documentation-accuracy-reviewer` — Claude Code Action-compatible: docs and README accuracy
5. `security-code-reviewer` — trust boundaries, injection, secrets, auth
6. `code-reviewer` — always run; AGENTS.md/project-guideline compliance and high-precision bug detection; avoids duplicating `code-quality-reviewer` findings

The following **specialty reviewers** run conditionally:

- `pr-test-analyzer` — when test files changed (paths matching `*test*`, `*spec*`, or test directories)
- `silent-failure-hunter` — when error handling, catch blocks, fallback logic, retries, logging, or failure paths changed
- `comment-analyzer` — when code comments or docstrings changed
- `type-design-analyzer` — when new or modified types, interfaces, classes, schemas, domain models, or struct definitions are introduced

`code-simplifier` is never part of the `all` review set; it is a separate post-review refinement step.

## Claude Code Action-Compatible Core Reviewers

These three agents mirror the intent of Claude Code Action's corresponding review agents:

**`code-quality-reviewer`**: General code quality, maintainability, clean code principles, edge cases, robustness, and type safety. Reports findings with confidence >= 80.

**`test-coverage-reviewer`**: Test coverage and test quality. Identifies missing critical test scenarios, brittle tests, and missing edge or error coverage. Reports gaps rated >= 7 out of 10.

**`documentation-accuracy-reviewer`**: Verifies code docs, README, API docs, examples, configuration docs, and public interface documentation against the implementation. Reports findings with confidence >= 80.

## pr-review-toolkit Specialty Reviewers

These agents cover focused specialty concerns:

**`code-reviewer`**: Checks AGENTS.md compliance; detects bugs and quality issues with high precision (confidence >= 80).

**`performance-reviewer`**: Analyzes algorithmic complexity, N+1 queries, resource leaks, and I/O efficiency.

**`security-code-reviewer`**: Reviews trust boundaries, input validation, auth/authz, and secrets handling.

**`pr-test-analyzer`**: Reviews behavioral test coverage and identifies critical gaps and brittle tests.

**`silent-failure-hunter`**: Finds silent failures, broad catch blocks, and checks error logging and fallback behavior.

**`comment-analyzer`**: Verifies comment accuracy vs code and identifies comment rot.

**`type-design-analyzer`**: Analyzes type encapsulation, invariant expression, and design quality.

**`code-simplifier`** (refinement, not review): Simplifies complex code for clarity; run after review passes.

## Finding Normalization

Every subagent returns findings in this normalized structure:

```yaml
- file: path/to/file
  line: <head-file line number>
  severity: critical | important | suggestion
  source: <agent-name>
  message: <concise issue and concrete fix>
```

### Filtering rules applied before posting the review

1. Drop praise-only items (no actionable issue).
2. Drop nitpicks (cosmetic preferences, no real-world impact).
3. Drop findings not supported by the diff — check **file membership only**; the changed-file set contains paths, not line numbers. Leave line validation to the anchoring step.
4. Deduplicate across agents (keep the most specific finding when two agents report the same issue at the same location).
5. Aggregate by root cause only when it still preserves an actionable inline anchor. If several findings share one root cause, keep one representative inline comment at the best anchor and mention the other affected files briefly in that comment. Do not collapse an anchorable finding into a top-level-only summary.
6. Orchestrator second filter: the orchestrator reviews every remaining finding and discards any it does not also deem noteworthy.

Prefer fewer, higher-signal comments over exhaustive lists. Optional guardrail suggestions (such as adding tests for agent frontmatter or reference validation) should be downgraded to `suggestion` severity at most.

## Diff Anchor Validation

Before submitting a GitHub review, classify every surviving finding as either inline or summary-only.

### Inline comment requirements

- Every finding with a valid `file` and diff-anchorable `line` must become an inline review comment.
- Do not skip inline comments merely because the same finding is also listed in a summary.
- Do not convert all findings into a single top-level markdown response when one or more valid inline anchors exist.
- Summary-only findings are allowed only when the issue is real but cannot be safely anchored to the diff, such as a cross-file design issue or a stale/unavailable line.

### Anchor validation rules

- Use the hunk list from `gh pr diff` in PR mode or `git diff` in local mode.
- A line is valid when it can be anchored on the head side of a hunk for the given file.
- Prefer an added or modified line that directly caused the issue.
- If the reported line is not anchorable but the same finding has a nearby valid head-side diff line in the same file, adjust to the nearest relevant line and keep it inline.
- If no safe anchor exists, mark the finding summary-only with a short reason. Do not silently drop it.
- One unverifiable reference never fails the entire review.

## Review Submission Policy

### PR mode with no findings

Return exactly:

```text
No noteworthy issues found.
```

Do not submit an empty GitHub review.

### PR mode with inline findings

Submit one GitHub pull request review via `gh api` using a structured review payload with `comments` entries. Use `gh api` instead of `gh pr review` because this workflow needs explicit per-line anchors.

The review payload must include:

- `commit_id`: PR head SHA from `gh pr view --json headRefOid`
- `event`: `COMMENT`
- `body`: concise review summary plus any summary-only findings and fallback reasons
- `comments`: one entry per inline finding, each with `path`, `line`, `side: RIGHT`, and concise `body`

Inline comment body format:

```markdown
**<severity> · <source>**: <issue and concrete fix>
```

Operational requirements:

- `GH_TOKEN` or `GITHUB_TOKEN` must have pull request write permission.
- If GitHub rejects the review because one inline anchor is invalid, remove only the rejected or unverifiable inline comment, move it to the summary-only section with the failure reason, and retry once.
- If the retry still fails, return a concise failure report that includes the attempted inline comment count, failing anchors, and the summary-only fallback body. Do not claim inline comments were posted.

After a successful submission, return only a concise status, for example:

```text
Submitted OpenCode PR review with 3 inline comment(s) and 1 summary-only finding.
```

### PR mode without inline findings

If all findings are valid but none can be safely anchored inline, return a concise markdown review body as a top-level fallback and explicitly state why inline comments were not used.

### Local mode

Print the same normalized review summary to the user. Do not call `gh api`, `gh pr review`, or `gh pr comment`.

## Workflow

1. **Detect context** — GitHub Actions (PR mode) or local (local mode).
2. **Gather diff** — `gh pr diff` in PR mode; `git diff` in local mode.
3. **Choose reviewers** — based on requested aspects and diff content.
4. **Launch subagents in parallel** — pass diff, files, and PR metadata.
5. **Normalize, filter, and aggregate** — apply filtering rules, root-cause aggregation, and orchestrator second filter.
6. **Validate anchors** — classify findings as inline or summary-only; adjust nearby anchors when safe.
7. **Submit or return** — submit an inline GitHub review in PR mode when anchors exist; otherwise use the documented fallback. In local mode, print the summary only.

## Workflow Integration

**Before committing:**

1. Write code.
2. Run `/review-pr code errors`.
3. Fix any critical issues.
4. Commit.

**Before creating a PR:**

1. Stage all changes.
2. Run `/review-pr all`.
3. Address all critical and important issues.
4. Run specific reviews again to verify.
5. Create PR.

**In GitHub Actions:**

1. The `opencode.yml` workflow runs `/review-pr` on PR open / ready for review.
2. The orchestrator gathers the PR via `gh`, runs the agents, validates anchors, and submits a GitHub review with inline comments for anchorable findings. The `opencode github run` integration then posts only a short status comment.
3. Re-run by commenting `/opencode` or `/oc` on the PR.

**After PR feedback:**

1. Make requested changes.
2. Run targeted reviews based on feedback.
3. Verify issues are resolved.
4. Push updates.

## Notes

- Agents run autonomously and return structured findings.
- Each agent focuses on its specialty for deep analysis.
- Results are actionable with specific inline anchors whenever the diff supports them.
- The skill posts a GitHub review only in PR mode when inline anchors exist; otherwise it uses the documented fallback.
- Never include secrets, tokens, or full file contents in the review response or GitHub comments.
