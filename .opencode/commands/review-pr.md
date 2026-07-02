---
description: Comprehensive GitHub PR review — gathers the PR via gh, runs specialized review subagents in parallel, normalizes and deduplicates findings, validates file:line references against the diff, and returns a single review response for the OpenCode GitHub integration to post.
agent: general
---

# Comprehensive PR Review

Perform a comprehensive pull request review by orchestrating specialized review subagents in parallel. Each subagent returns only noteworthy findings in a normalized format. You then deduplicate and filter across agents, validate file:line references against the diff, and return a single review response. The surrounding `opencode github run` integration posts that response to the PR as `opencode-agent[bot]`; do not post to GitHub yourself.

**Requested review aspects (optional):** "$ARGUMENTS"

## 1. Detect the review context

Determine whether you are reviewing a real GitHub PR (running in GitHub Actions) or working locally.

- In GitHub Actions the environment provides `GITHUB_EVENT_NAME`, `GITHUB_REPOSITORY`, `GITHUB_REF` (e.g. `refs/pull/42/merge`), and `GITHUB_EVENT_PATH`. The `gh` CLI also requires `GH_TOKEN` or `GITHUB_TOKEN` to be available in the environment.
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

- If `PR_NUMBER` is set, run `gh pr view "$PR_NUMBER" --json number,title,body,baseRefName,headRefName,files,url` to confirm a PR is available.
  - If it succeeds, you are in **PR mode**: return a review response (step 7).
  - If it fails (no PR or not in CI), fall back to **local mode**: review `git diff` and `git status`, and report findings directly to the user without posting anything to GitHub.
- Do not rely on the current git branch to identify the PR. GitHub Actions pull request workflows usually check out a detached merge ref.

## 2. Gather the diff

- **PR mode:** run `gh pr diff "$PR_NUMBER"` for the full diff and use the `files` list from `gh pr view "$PR_NUMBER"` for the changed-file set. Prefer `gh pr diff "$PR_NUMBER"` over `git diff` because CI checkouts are shallow (`fetch-depth: 1`).
- **Local mode:** run `git diff --name-only HEAD` plus untracked files from `git status --short` for the changed-file set, then `git diff` for content.

Capture the changed-file list, the full diff, and the PR metadata (title, body, base/head branch) to hand to the subagents.

## 3. Choose applicable reviewers based on $ARGUMENTS

Parse `$ARGUMENTS` (the requested aspects). Supported aspect keywords:

- `code` → `code-reviewer` and `code-quality-reviewer`
- `quality` → `code-quality-reviewer`
- `performance` → `performance-reviewer`
- `security` → `security-code-reviewer`
- `tests` or `coverage` → `test-coverage-reviewer` and `pr-test-analyzer`
- `docs` or `documentation` → `documentation-accuracy-reviewer`
- `comments` → `comment-analyzer`
- `errors` → `silent-failure-hunter`
- `types` → `type-design-analyzer`
- `simplify` → run `code-simplifier` as a refinement step only; **do not return a review**; stop after simplification
- `all` or no argument → run all applicable reviewers (see below)

### Deterministic reviewer set for `all`

When `all` is requested or no aspect is specified, run the following **core reviewers** unconditionally:

1. `code-quality-reviewer` — general quality, edge cases, robustness
2. `performance-reviewer` — algorithmic complexity, N+1, resource leaks
3. `test-coverage-reviewer` — missing critical tests and brittle tests
4. `documentation-accuracy-reviewer` — docs and README accuracy vs implementation
5. `security-code-reviewer` — trust boundaries, injection, secrets, auth
6. `code-reviewer` — always run; AGENTS.md/project-guideline compliance and high-precision bug detection; do not duplicate findings from `code-quality-reviewer`

Also run the following **specialty reviewers** conditionally:

- `pr-test-analyzer` — when test files changed (paths matching `*test*`, `*spec*`, or test directories)
- `silent-failure-hunter` — when the diff contains: try/catch, except, rescue, `.catch(`, `on_error`, `fallback`, retry logic, or logging/error-handling paths
- `comment-analyzer` — when the diff contains changes to code comments, docstrings, or inline docs (`//`, `#`, `/*`, `"""`, `'''`)
- `type-design-analyzer` — when the diff introduces new types, interfaces, classes, schemas, domain models, or struct definitions

Do **not** include `code-simplifier` in the `all` review set; it is a separate post-review refinement step.

## 4. Launch the subagents in parallel

Spawn each applicable reviewer as a subagent using the `task` tool with its agent name as `subagent_type`. Pass:

- The changed-file list
- The full diff
- The PR title and body
- The head branch name

Launch all subagents **in parallel** for speed.

Instruct every subagent to:

- Review **only the changed lines** (the diff) and the functions they belong to, not the whole repository.
- Return **only high-confidence, noteworthy findings** (no nitpicks, no praise-only output).
- Format **every finding** using this normalized structure:

  ```yaml
  - file: path/to/file
    line: <head-file line number>
    severity: critical | important | suggestion
    source: <agent-name>
    message: <concise issue description and concrete fix>
  ```

- If no noteworthy findings exist, return an empty list and a one-line "no issues" note.

Do **not** let subagents post comments themselves. The orchestrator returns the final response; the `opencode github run` integration posts it.

## 5. Normalize, filter, and aggregate findings

### Normalization

Collect all findings from all subagents. Each finding must have `file`, `line`, `severity`, `source`, and `message`.

### Filtering rules (apply in order)

1. **Drop praise-only items**: remove any entry whose message is only positive (no actionable issue).
2. **Drop nitpicks**: remove cosmetic preferences, style-only feedback, or issues with no real-world impact.
3. **Drop findings not supported by the diff**: if the file referenced is not in the changed-file set, drop the finding. Do **not** compare `line` against the changed-file set — it contains paths, not line numbers. Leave line validation to the diff-anchoring step (step 6).
4. **Deduplicate across agents**: if two or more agents report substantially the same issue at the same location, keep the most specific one (usually from the specialized agent) and discard the duplicate.
5. **Aggregate by root cause**: when several findings share the same underlying root cause (for example, the same inconsistency repeated across README, SKILL.md, and command files), keep **one representative finding** as a `file:line` reference and collapse the remaining occurrences into the summary body. Prefer root-cause aggregation over line-by-line repetition. Cross-document or cross-file consistency problems should usually be summarized once in the review body instead of repeated at each affected location.
6. **Orchestrator second filter**: review every remaining finding yourself and remove any you do not also deem noteworthy. This filter keeps the signal high.

### Grouping

Group surviving findings by severity:

- **Critical** — must fix before merge
- **Important** — should fix
- **Suggestions** — optional improvements

Prefer fewer, higher-signal comments over exhaustive lists. Optional guardrail suggestions (such as adding tests for agent frontmatter or reference validation) should be downgraded to `suggestion` severity at most.

## 6. Validate file:line references against the diff

Before building the review response, validate every finding against the PR diff so the `file:line` references in the single OpenCode comment stay accurate.

### Validation rules

- Obtain the diff hunk list from `gh pr diff "$PR_NUMBER"` (already gathered in step 2).
- For each finding, check whether its `line` appears in the diff or diff context for `file`.
  - A line is valid if: it falls within a `+` hunk in the diff for the given file, or within the surrounding unchanged-context lines of that hunk.
- If a finding's line **cannot be safely matched** to the diff, keep it in the summary body but reference the nearest valid anchor line (or the file alone) instead of an unverified line number. Do **not** drop it — the file is a changed file, only the line is unverifiable.
- Never fail the entire review because one finding's line is unverifiable. Adjust the reference and continue.

## 7. Return the results

### PR mode

Return a **single concise markdown review response**. Do **not** call `gh api`, `gh pr review`, or `gh pr comment` — the surrounding `opencode github run` integration is responsible for posting the final response to the PR as `opencode-agent[bot]`. Calling GitHub write APIs directly would create a duplicate `github-actions[bot]` posting.

Include all findings (whether or not their line matched the diff) in the summary body as `file:line` references so the single top-level OpenCode comment stays actionable.

**Summary body format:**

```markdown
## OpenCode PR Review

Reviewed <N> files across <M> areas: <comma-separated agent names>.

### Critical (<count>)

- `file:line` — issue

### Important (<count>)

- `file:line` — issue

### Suggestions (<count>)

- `file:line` — issue
```

When a root cause affects multiple files, add a single summary entry naming all affected files (e.g. `Same inconsistency across README.md, SKILL.md, review-pr.md`).

If there are **no findings at all**, return:

```text
No noteworthy issues found.
```

Do not spam praise or padding. One concise confirmation is sufficient.

### Local mode

Print the same summary to the user. Do not call `gh`.

## 8. Notes

- Keep feedback concise. A short review with real signal beats a long review with padding.
- Never include secrets, tokens, or full file contents in the review response.
- The `opencode github run` integration posts your final response to the PR as `opencode-agent[bot]`; do not call `gh api`, `gh pr review`, or `gh pr comment` yourself. The workflow may still grant `pull-requests: write` for the integration's posting, and `GH_TOKEN` or `GITHUB_TOKEN` is needed only for `gh pr diff` / `gh pr view` reads. Do not attempt to push commits or merge.
- If `$ARGUMENTS` lists specific aspects, respect them and skip the rest.
- Re-run after fixes to verify issues are resolved.
