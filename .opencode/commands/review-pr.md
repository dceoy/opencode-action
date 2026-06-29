---
description: Comprehensive PR review using specialized agents (comments, tests, errors, types, code, simplify).
agent: general
---

# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality. Each review agent is a subagent you spawn via the `task` tool using its name as the `subagent_type`.

**Review Aspects (optional):** "$ARGUMENTS"

## Review Workflow:

1. **Determine Review Scope**
   - Check git status to identify changed files
   - Parse arguments to see if the user requested specific review aspects
   - Default: Run all applicable reviews

2. **Available Review Aspects:**

   - **comments** - Analyze code comment accuracy and maintainability
   - **tests** - Review test coverage quality and completeness
   - **errors** - Check error handling for silent failures
   - **types** - Analyze type design and invariants (if new types added)
   - **code** - General code review for project guidelines
   - **simplify** - Simplify code for clarity and maintainability
   - **all** - Run all applicable reviews (default)

3. **Identify Changed Files**
   - Run `git diff --name-only HEAD` to see staged and unstaged modified files
   - Include untracked files from `git status --short` when they are part of the review
   - Check if a PR already exists: `gh pr view`
   - Identify file types and what reviews apply

4. **Determine Applicable Reviews**

   Based on changes:
   - **Always applicable**: code-reviewer (general quality)
   - **If test files changed**: pr-test-analyzer
   - **If comments/docs added**: comment-analyzer
   - **If error handling changed**: silent-failure-hunter
   - **If types added/modified**: type-design-analyzer
   - **After passing review**: code-simplifier (polish and refine)

5. **Launch Review Agents**

   Spawn each applicable agent with the `task` tool, passing the changed files / diff as input:

   - **comment-analyzer** - comment accuracy
   - **pr-test-analyzer** - test coverage
   - **silent-failure-hunter** - error handling
   - **type-design-analyzer** - type design
   - **code-reviewer** - general review
   - **code-simplifier** - refinement (run last, only after review passes)

   **Sequential approach** (one at a time):
   - Easier to understand and act on
   - Each report is complete before the next
   - Good for interactive review

   **Parallel approach** (user can request):
   - Launch all agents simultaneously
   - Faster for comprehensive review
   - Results come back together

6. **Aggregate Results**

   After agents complete, summarize:
   - **Critical Issues** (must fix before merge)
   - **Important Issues** (should fix)
   - **Suggestions** (nice to have)
   - **Positive Observations** (what's good)

7. **Provide Action Plan**

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

## Usage Examples:

**Full review (default):**

```
/review-pr
```

**Specific aspects:**

```
/review-pr tests errors
# Reviews only test coverage and error handling

/review-pr comments
# Reviews only code comments

/review-pr simplify
# Simplifies code after passing review
```

**Parallel review:**

```
/review-pr all parallel
# Launches all agents in parallel
```

## Agent Descriptions:

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

## Tips:

- **Run early**: Before creating PR, not after
- **Focus on changes**: Agents analyze git diff by default
- **Address critical first**: Fix high-priority issues before lower priority
- **Re-run after fixes**: Verify issues are resolved
- **Use specific reviews**: Target specific aspects when you know the concern

## Workflow Integration:

**Before committing:**

```
1. Write code
2. Run: /review-pr code errors
3. Fix any critical issues
4. Commit
```

**Before creating PR:**

```
1. Stage all changes
2. Run: /review-pr all
3. Address all critical and important issues
4. Run specific reviews again to verify
5. Create PR
```

**After PR feedback:**

```
1. Make requested changes
2. Run targeted reviews based on feedback
3. Verify issues are resolved
4. Push updates
```

## Notes:

- Agents run autonomously and return detailed reports
- Each agent focuses on its specialty for deep analysis
- Results are actionable with specific file:line references
- All agents are available as subagents (spawned automatically by this command)
