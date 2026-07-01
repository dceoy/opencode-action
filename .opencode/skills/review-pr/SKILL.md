---
name: review-pr
description: Run a comprehensive pull request review across changed files using Claude Code Action-compatible core reviewers and pr-review-toolkit specialty agents. Gathers the PR via gh, runs agents in parallel, normalizes and deduplicates findings, validates file:line references, and returns a single concise markdown review response. The surrounding `opencode github run` integration posts the returned response to the PR as `opencode-agent[bot]`. Use when reviewing a PR before merge, before requesting review, after addressing feedback, or when the user asks to review a diff or recent changes.
---

# Comprehensive PR Review

Run a comprehensive pull request review by orchestrating specialized review agents, each focusing on one aspect of code quality. The orchestrator gathers the PR, spawns agents as subagents via the `task` tool, normalizes and deduplicates findings, validates `file:line` references against the diff, and **returns a single concise markdown review response**. The surrounding `opencode github run` integration posts that response to the PR as `opencode-agent[bot]`.

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

### Filtering rules applied before assembling the response

1. Drop praise-only items (no actionable issue).
2. Drop nitpicks (cosmetic preferences, no real-world impact).
3. Drop findings not supported by the diff — check **file membership only**; the changed-file set contains paths, not line numbers. Leave line validation to the `file:line` reference validation step.
4. Deduplicate across agents (keep the most specific finding when two agents report the same issue at the same location).
5. **Aggregate by root cause**: when several findings share the same underlying root cause (e.g. the same inconsistency repeated across README, SKILL.md, and command files), keep one representative finding as a `file:line` reference and collapse the rest into the review body. Prefer root-cause aggregation over line-by-line repetition. Cross-document or cross-file consistency problems should usually be summarized once in the review body instead of repeated at each affected location.
6. Orchestrator second filter: the orchestrator reviews every remaining finding and discards any it does not also deem noteworthy.

Prefer fewer, higher-signal references over exhaustive lists. Optional guardrail suggestions (such as adding tests for agent frontmatter or reference validation) should be downgraded to `suggestion` severity at most.

## file:line Reference Validation

Before assembling the response, every finding is validated against the PR diff:

- Use the head-file line number for every `file:line` reference.
- A `file:line` reference is valid if the line falls within a `+` hunk or surrounding unchanged-context lines of that hunk for the given file.
- Findings whose line cannot be safely validated are **kept in the review body as `file`-only references** (drop the unverified `:line`) — not dropped, since the file is a changed file and only the line is unverifiable.
- One unverifiable `file:line` reference never fails the entire review.

## Review Output Policy

- Return **one final markdown response only**. Do not split it into multiple posts.
- Do **not** call `gh api`, `gh pr review`, or `gh pr comment`. Do **not** post a GitHub Review or inline review comments.
- The surrounding `opencode github run` integration posts the returned response to the PR as `opencode-agent[bot]`.
- The orchestrator never writes to GitHub; it only assembles and returns the review.
- Group findings by severity in the response:
  - **Critical** — must fix before merge
  - **Important** — should fix
  - **Suggestions** — optional improvements
- Each finding entry begins with its severity tag (`**critical**:`, `**important**:`, or `**suggestion**:`) followed by the message and an actionable `file:line` reference.
- **Unverifiable-line findings** (changed file but no safe diff line) → review body as `file`-only references.
- **Duplicated root causes** → one representative `file:line` entry plus a body entry listing all affected files.
- Reserve `file:line` references for issues tied to a specific representative line. Cross-document or cross-file consistency problems should usually be summarized once in the review body instead of repeated across every affected file.
- If there are no findings, return only `No noteworthy issues found.` — one line, no padding, no praise, no status logs.

## Workflow

1. **Detect context** — GitHub Actions (PR mode) or local (local mode).
2. **Gather diff** — `gh pr diff` in PR mode; `git diff` in local mode.
3. **Choose reviewers** — based on `$ARGUMENTS` and diff content.
4. **Launch subagents in parallel** — pass diff, files, and PR metadata.
5. **Normalize, filter, and aggregate** — apply filtering rules, root-cause aggregation, and orchestrator second filter.
6. **Validate `file:line` references** — check each finding against the diff; demote unverified findings to `file`-only references (do not drop them).
7. **Return response** — single markdown review in both PR and local mode. `opencode github run` posts it to the PR as `opencode-agent[bot]` in PR mode.

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
2. The orchestrator gathers the PR via read-only `gh` calls, runs the agents, and returns one review response.
3. `opencode github run` posts that response to the PR as a single `opencode-agent[bot]` comment. The orchestrator does **not** post a GitHub Review or inline comments.
4. Re-run by commenting `/opencode` or `/oc` on the PR.

**After PR feedback:**

1. Make requested changes.
2. Run targeted reviews based on feedback.
3. Verify issues are resolved.
4. Push updates.

## Notes

- Agents run autonomously and return structured findings.
- Each agent focuses on its specialty for deep analysis.
- Results are actionable with specific `file:line` references.
- Never include secrets, tokens, or full file contents in the response.
- The only PR-visible review output from an automated OpenCode review run is the final response posted by `opencode-agent[bot]`. `github-actions[bot]` does not post a review.
