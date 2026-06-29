---
name: review-pr
description: Run a comprehensive pull request review across changed files using specialized review agents for performance, security, tests, error handling, comments, type design, and general code quality. Gathers the PR via gh, runs the agents in parallel, filters to noteworthy findings, and posts inline + summary review comments back to the PR. Use when reviewing a PR before merge, before requesting review, after addressing feedback, or when the user asks to review a diff or recent changes.
---

# Comprehensive PR Review

Run a comprehensive pull request review by orchestrating specialized review agents, each focusing on one aspect of code quality. The orchestrator gathers the PR, spawns the agents as subagents via the `task` tool (using the agent name as `subagent_type`), filters their findings to the noteworthy ones, and posts the results back to the PR.

## When to Use

- A PR is open or about to open and needs a quality review pass.
- The user asks to review changes, a diff, or a pull request.
- Before requesting human review, before merge, or after addressing feedback.

Do not use this skill to triage existing review comments on a PR; use `pr-feedback-triage` instead.

## Inputs

- Optional review aspects requested by the user, such as `code`, `performance`, `security`, `tests`, `errors`, `comments`, `types`, `simplify`, or `all`.
- A repository checkout with the changes to review. In GitHub Actions the skill derives the PR number from the event payload or pull request ref, then passes that number to `gh pr diff` and `gh pr view`; locally it uses `git diff` and `git status`.

If no aspects are specified, run all applicable reviews.

## Review Aspects

- **code** - General review for project guidelines (`code-reviewer`) — always applicable
- **performance** - Performance bottlenecks and resource efficiency (`performance-reviewer`)
- **security** - Security vulnerabilities and trust-boundary issues (`security-code-reviewer`)
- **tests** - Test coverage quality and completeness (`pr-test-analyzer`)
- **errors** - Error handling for silent failures (`silent-failure-hunter`)
- **comments** - Code comment accuracy and maintainability (`comment-analyzer`)
- **types** - Type design and invariants when new types are added (`type-design-analyzer`)
- **simplify** - Simplify code for clarity (`code-simplifier`) — refinement only, not part of the default review
- **all** - Run all applicable reviews (default)

## Workflow

1. **Detect the review context**
   - In GitHub Actions, `GITHUB_EVENT_NAME`, `GITHUB_REPOSITORY`, `GITHUB_REF`, and `GITHUB_EVENT_PATH` are set. The `gh` CLI also requires `GH_TOKEN` or `GITHUB_TOKEN` in the environment.
   - Derive the PR number from the event payload first:

     ```bash
     PR_NUMBER=""
     if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
       PR_NUMBER="$(jq -r '.pull_request.number // .issue.number // empty' "$GITHUB_EVENT_PATH")"
     fi
     ```

   - If the payload does not contain a PR or issue number, fall back to parsing `GITHUB_REF` only for pull request refs:

     ```bash
     if [[ -z "${PR_NUMBER}" && "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/merge$ ]]; then
       PR_NUMBER="${BASH_REMATCH[1]}"
     fi
     ```

   - If `PR_NUMBER` is set, run `gh pr view "$PR_NUMBER" --json number,title,body,baseRefName,headRefName,files,url`. If it succeeds, you are in **PR mode** (post results back). If not, fall back to **local mode** (report to the user only).
   - Do not rely on the current git branch to identify the PR. GitHub Actions pull request workflows usually check out a detached merge ref.

2. **Gather the diff**
   - PR mode: `gh pr diff "$PR_NUMBER"` and the `files` list from `gh pr view "$PR_NUMBER"`. Prefer `gh pr diff "$PR_NUMBER"` because CI checkouts are shallow.
   - Local mode: `git diff --name-only HEAD` plus untracked files from `git status --short`, then `git diff` for content.

3. **Choose applicable reviewers**
   - Always run `code-reviewer`.
   - Add `performance-reviewer` and `security-code-reviewer` for changes touching hot paths, external input, auth, or secrets.
   - Add `pr-test-analyzer` if test files changed, `silent-failure-hunter` if error handling changed, `comment-analyzer` if comments/docs changed, `type-design-analyzer` if new types are introduced.
   - `code-simplifier` is a separate post-review refinement step, not part of the review.

4. **Launch review agents**
   - Spawn each applicable agent with the `task` tool, passing the changed files and diff as input.
   - Launch them in **parallel** for speed.
   - Each agent returns only noteworthy findings (confidence >= 80) as `{file, line, severity, message}`.

5. **Filter and aggregate**
   - Keep only findings you also deem noteworthy. Discard duplicates, false positives, and nits.
   - Group by severity: Critical (must fix), Important (should fix), Suggestions (optional).

6. **Post the results**
   - PR mode: post a single review with a summary body and inline comments via `gh api -X POST repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews` (`event: COMMENT`). Anchor inline comments to diff lines with `side: "RIGHT"`; move out-of-range findings into the summary body. If posting the review fails, fall back to `gh pr comment`. Use `event: "REQUEST_CHANGES"` only for blocking critical findings.
   - Local mode: print the summary to the user.
   - If there are no findings, post a one-line confirmation so users know the review ran.

## Agent Descriptions

**code-reviewer**:

- Checks AGENTS.md compliance
- Detects bugs and quality issues with high precision (confidence >= 80)

**performance-reviewer**:

- Analyzes algorithmic complexity, N+1 queries, and resource leaks
- Flags only bottlenecks with measurable impact

**security-code-reviewer**:

- Reviews trust boundaries, input validation, auth/authz, and secrets handling
- Maps untrusted data flows to sensitive operations

**pr-test-analyzer**:

- Reviews behavioral test coverage
- Identifies critical gaps and brittle tests

**silent-failure-hunter**:

- Finds silent failures and broad catch blocks
- Checks error logging and fallback behavior

**comment-analyzer**:

- Verifies comment accuracy vs code
- Identifies comment rot and misleading docs

**type-design-analyzer**:

- Analyzes type encapsulation and invariant expression
- Rates type design quality on four axes

**code-simplifier** (refinement, not review):

- Simplifies complex code for clarity
- Preserves functionality; run after review passes

## Tips

- **Run early**: Before creating a PR, not after.
- **Focus on changes**: Agents analyze the diff by default, not the whole repo.
- **Address critical first**: Fix high-priority issues before lower priority.
- **Re-run after fixes**: Verify issues are resolved.
- **Use specific aspects**: Target `performance` or `security` when you know the concern.
- **Keep it concise**: A short review with real signal beats a long review with padding.

## Workflow Integration

**Before committing:**

1. Write code
2. Run `/review-pr code errors`
3. Fix any critical issues
4. Commit

**Before creating a PR:**

1. Stage all changes
2. Run `/review-pr all`
3. Address all critical and important issues
4. Run specific reviews again to verify
5. Create PR

**In GitHub Actions:**

1. The `opencode.yml` workflow runs `/review-pr` on PR open / ready for review.
2. The orchestrator gathers the PR via `gh`, runs the agents, and posts a review with inline comments.
3. Re-run by commenting `/opencode` or `/oc` on the PR.

**After PR feedback:**

1. Make requested changes
2. Run targeted reviews based on feedback
3. Verify issues are resolved
4. Push updates

## Notes

- Agents run autonomously and return structured findings.
- Each agent focuses on its specialty for deep analysis.
- Results are actionable with specific `file:line` references.
- All agents are available as subagents (spawned automatically by this skill).
- Never post secrets, tokens, or full file contents in review comments.
