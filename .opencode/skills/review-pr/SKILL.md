---
name: review-pr
description: Run a comprehensive pull request review across changed files using specialized review agents for comments, tests, error handling, type design, general code quality, and simplification. Use when reviewing a PR before merge, before requesting review, after addressing feedback, or when the user asks to review a diff or recent changes.
---

# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality. Each review agent is a subagent spawned via the `task` tool using its name as the `subagent_type`.

## When to Use

- A PR is open or about to open and needs a quality review pass.
- The user asks to review changes, a diff, or a pull request.
- Before requesting human review, before merge, or after addressing feedback.

Do not use this skill to triage existing review comments on a PR; use `pr-feedback-triage` instead.

## Inputs

- Optional review aspects requested by the user, such as `comments`, `tests`, `errors`, `types`, `code`, `simplify`, or `all`.
- A repository checkout with the changes to review. The skill relies on `git diff` to identify changed files.

If no aspects are specified, run all applicable reviews.

## Review Aspects

- **comments** - Analyze code comment accuracy and maintainability (`comment-analyzer`)
- **tests** - Review test coverage quality and completeness (`pr-test-analyzer`)
- **errors** - Check error handling for silent failures (`silent-failure-hunter`)
- **types** - Analyze type design and invariants when new types are added (`type-design-analyzer`)
- **code** - General code review for project guidelines (`code-reviewer`)
- **simplify** - Simplify code for clarity and maintainability (`code-simplifier`)
- **all** - Run all applicable reviews (default)

## Workflow

1. **Determine Review Scope**
   - Check `git status` to identify changed files.
   - Parse any requested aspects from the user; default to all applicable reviews.

2. **Identify Changed Files**
   - Run `git diff --name-only` to see modified files.
   - Check if a PR already exists with `gh pr view`.
   - Identify file types and which reviews apply.

3. **Determine Applicable Reviews**

   Based on the changes:
   - **Always applicable**: `code-reviewer` (general quality)
   - **If test files changed**: `pr-test-analyzer`
   - **If comments/docs added**: `comment-analyzer`
   - **If error handling changed**: `silent-failure-hunter`
   - **If types added/modified**: `type-design-analyzer`
   - **After passing review**: `code-simplifier` (polish and refine; run last)

4. **Launch Review Agents**

   Spawn each applicable agent with the `task` tool, passing the changed files or diff as input:

   - **comment-analyzer** - comment accuracy
   - **pr-test-analyzer** - test coverage
   - **silent-failure-hunter** - error handling
   - **type-design-analyzer** - type design
   - **code-reviewer** - general review
   - **code-simplifier** - refinement (run last, only after review passes)

   **Sequential approach** (default, one at a time):
   - Easier to understand and act on.
   - Each report is complete before the next.
   - Good for interactive review.

   **Parallel approach** (when the user requests it):
   - Launch all agents simultaneously.
   - Faster for comprehensive review.
   - Results come back together.

5. **Aggregate Results**

   After agents complete, summarize:
   - **Critical Issues** (must fix before merge)
   - **Important Issues** (should fix)
   - **Suggestions** (nice to have)
   - **Positive Observations** (what's good)

6. **Provide Action Plan**

   Organize findings:

   ```markdown
   # PR Review Summary

   ## Critical Issues (X found)

   - [agent-name]: Issue description [file:line]

   ## Important Issues (X found)

   - [agent-name]: Issue description [file:line]

   ## Suggestions (X found)

   - [agent-name]: Suggestion [file:line]

   ## Strengths

   - What's well-done in this PR

   ## Recommended Action

   1. Fix critical issues first
   2. Address important issues
   3. Consider suggestions
   4. Re-run review after fixes
   ```

## Agent Descriptions

**comment-analyzer**:

- Verifies comment accuracy vs code
- Identifies comment rot
- Checks documentation completeness

**pr-test-analyzer**:

- Reviews behavioral test coverage
- Identifies critical gaps
- Evaluates test quality

**silent-failure-hunter**:

- Finds silent failures
- Reviews catch blocks
- Checks error logging

**type-design-analyzer**:

- Analyzes type encapsulation
- Reviews invariant expression
- Rates type design quality

**code-reviewer**:

- Checks AGENTS.md compliance
- Detects bugs and issues
- Reviews general code quality

**code-simplifier**:

- Simplifies complex code
- Improves clarity and readability
- Applies project standards
- Preserves functionality

## Tips

- **Run early**: Before creating a PR, not after.
- **Focus on changes**: Agents analyze `git diff` by default.
- **Address critical first**: Fix high-priority issues before lower priority.
- **Re-run after fixes**: Verify issues are resolved.
- **Use specific reviews**: Target specific aspects when you know the concern.

## Workflow Integration

**Before committing:**

1. Write code
2. Review `code` and `errors`
3. Fix any critical issues
4. Commit

**Before creating a PR:**

1. Stage all changes
2. Run `all`
3. Address all critical and important issues
4. Run specific reviews again to verify
5. Create PR

**After PR feedback:**

1. Make requested changes
2. Run targeted reviews based on feedback
3. Verify issues are resolved
4. Push updates

## Notes

- Agents run autonomously and return detailed reports.
- Each agent focuses on its specialty for deep analysis.
- Results are actionable with specific `file:line` references.
- All agents are available as subagents (spawned automatically by this skill).
