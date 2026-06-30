---
name: review-pr
description: Run a comprehensive pull request review across changed files using Claude Code Action-compatible core reviewers and pr-review-toolkit specialty agents. Gathers the PR via gh, runs agents in parallel, normalizes and deduplicates findings, validates inline comment anchoring, and posts a single review with inline and summary comments back to the PR. Use when reviewing a PR before merge, before requesting review, after addressing feedback, or when the user asks to review a diff or recent changes.
---

# Comprehensive PR Review

Run a comprehensive pull request review by orchestrating specialized review agents, each focusing on one aspect of code quality. The orchestrator gathers the PR, spawns agents as subagents via the `task` tool, normalizes and deduplicates findings, validates inline comment anchoring, and posts the results back to the PR.

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
| `simplify`                | `code-simplifier`                            | Refinement only — does not post a review            |
| `all` (default)           | All applicable (see below)                   | Deterministic full review                           |

## Deterministic `all` Behavior

When `all` is requested or no aspect is specified, the following **core reviewers** run unconditionally:

1. `code-quality-reviewer` — Claude Code Action-compatible: general quality, edge cases, robustness
2. `performance-reviewer` — algorithmic complexity, N+1, resource leaks
3. `test-coverage-reviewer` — Claude Code Action-compatible: missing critical tests and brittle tests
4. `documentation-accuracy-reviewer` — Claude Code Action-compatible: docs and README accuracy
5. `security-code-reviewer` — trust boundaries, injection, secrets, auth

The following **specialty reviewers** run conditionally:

- `silent-failure-hunter` — when error handling, catch blocks, fallback logic, retries, logging, or failure paths changed
- `comment-analyzer` — when code comments or docstrings changed
- `type-design-analyzer` — when new or modified types, interfaces, classes, schemas, domain models, or struct definitions are introduced
- `code-reviewer` — as the AGENTS.md/project-guideline-focused reviewer; avoids duplicating `code-quality-reviewer` findings

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

### Filtering rules applied before posting

1. Drop praise-only items (no actionable issue).
2. Drop nitpicks (cosmetic preferences, no real-world impact).
3. Drop findings not supported by the diff (file or line not in the changed-file set).
4. Deduplicate across agents (keep the most specific finding when two agents report the same issue at the same location).
5. Orchestrator second filter: the orchestrator reviews every remaining finding and discards any it does not also deem noteworthy.

Prefer fewer, higher-signal comments over exhaustive lists.

## Inline Comment Anchoring

Before building the review payload, every finding is validated against the PR diff:

- Inline comments use `side: "RIGHT"` and the head-file line number.
- A line is anchored if it falls within a `+` hunk or surrounding unchanged-context lines of that hunk for the given file.
- Findings whose line cannot be safely anchored are moved to the summary body as `file:line` references.
- One invalid comment never fails the entire review.

## Review Posting Policy

Post one review via `gh api -X POST repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews`.

- `event: "COMMENT"` — normal reviews.
- `event: "REQUEST_CHANGES"` — only when critical findings block merge.

Use inline comments for specific, anchored findings. Use the review body for:

- Concise summary of areas reviewed
- Unanchorable findings
- General observations
- No-finding confirmation

If no findings: post `No noteworthy issues found.` — one line, no padding.

## Fallback Behavior

If the reviews API call fails:

1. Retry once after removing the invalid inline comment (move it to the summary body).
2. If still failing, fall back to one top-level `gh pr comment "$PR_NUMBER" --body "$SUMMARY"`.

Never leave the user with no feedback.

## Workflow

1. **Detect context** — GitHub Actions (PR mode) or local (local mode).
2. **Gather diff** — `gh pr diff` in PR mode; `git diff` in local mode.
3. **Choose reviewers** — based on `$ARGUMENTS` and diff content.
4. **Launch subagents in parallel** — pass diff, files, and PR metadata.
5. **Normalize and filter** — apply filtering rules and orchestrator second filter.
6. **Validate anchoring** — check each finding against the diff; move unanchored findings to summary.
7. **Post** — single review in PR mode; print summary in local mode.

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
2. The orchestrator gathers the PR via `gh`, runs the agents, and posts a review with inline comments.
3. Re-run by commenting `/opencode` or `/oc` on the PR.

**After PR feedback:**

1. Make requested changes.
2. Run targeted reviews based on feedback.
3. Verify issues are resolved.
4. Push updates.

## Notes

- Agents run autonomously and return structured findings.
- Each agent focuses on its specialty for deep analysis.
- Results are actionable with specific `file:line` references.
- Never post secrets, tokens, or full file contents in review comments.
