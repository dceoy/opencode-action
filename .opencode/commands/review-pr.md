---
description: Comprehensive GitHub PR review — gathers the PR via gh, runs specialized review subagents in parallel, normalizes and deduplicates findings, validates inline comment anchoring, and posts a single review with inline and summary comments back to the PR.
agent: general
---

# Comprehensive PR Review

Perform a comprehensive pull request review by orchestrating specialized review subagents in parallel. Each subagent returns only noteworthy findings in a normalized format. You then deduplicate and filter across agents, validate that findings can be anchored to the diff, and post a single review back to the PR.

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
  - If it succeeds, you are in **PR mode**: post results back with `gh` (step 7).
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
- `simplify` → run `code-simplifier` as a refinement step only; **do not post a review**; stop after simplification
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

Do **not** let subagents post comments themselves. The orchestrator is the only one that posts.

## 5. Normalize, filter, and aggregate findings

### Normalization

Collect all findings from all subagents. Each finding must have `file`, `line`, `severity`, `source`, and `message`.

### Filtering rules (apply in order)

1. **Drop praise-only items**: remove any entry whose message is only positive (no actionable issue).
2. **Drop nitpicks**: remove cosmetic preferences, style-only feedback, or issues with no real-world impact.
3. **Drop findings not supported by the diff**: if the file referenced is not in the changed-file set, drop the finding. Do **not** compare `line` against the changed-file set — it contains paths, not line numbers. Leave line validation to the diff-anchoring step (step 6).
4. **Deduplicate across agents**: if two or more agents report substantially the same issue at the same location, keep the most specific one (usually from the specialized agent) and discard the duplicate.
5. **Aggregate by root cause**: when several findings share the same underlying root cause (for example, the same inconsistency repeated across README, SKILL.md, and command files), keep **one representative finding** as an inline comment and collapse the remaining occurrences into the summary body. Prefer root-cause aggregation over line-by-line repetition. Cross-document or cross-file consistency problems should usually be summarized once in the review body instead of repeated at each affected location.
6. **Orchestrator second filter**: review every remaining finding yourself and remove any you do not also deem noteworthy. This filter keeps the signal high.

### Grouping

Group surviving findings by severity:

- **Critical** — must fix before merge
- **Important** — should fix
- **Suggestions** — optional improvements

Prefer fewer, higher-signal comments over exhaustive lists. Optional guardrail suggestions (such as adding tests for agent frontmatter or reference validation) should be downgraded to `suggestion` severity at most.

## 6. Validate inline comment anchoring

Before building the review payload, validate every finding against the PR diff.

### Anchoring rules

- Obtain the diff hunk list from `gh pr diff "$PR_NUMBER"` (already gathered in step 2).
- For each finding, check whether its `line` appears in the diff or diff context for `file`.
  - A line is anchored if: it falls within a `+` hunk in the diff for the given file, or within the surrounding unchanged-context lines of that hunk.
  - Use `side: "RIGHT"` and the head-file line number for every inline comment.
- If a finding's line **cannot be safely anchored** to the diff, move it to the summary body as a `file:line` reference instead of an inline comment. Do **not** drop it — the file is a changed file, only the line is unanchorable.
- Never fail the entire review because one comment is unanchorable. Move it and continue.

## 7. Post the results

### PR mode

Post a **single review** via:

```bash
gh api -X POST repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews --input - <<'EOF'
{
  "event": "COMMENT",
  "body": "<summary — see format below>",
  "comments": [
    {"path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "**important**: ..."}
  ]
}
EOF
```

Use `{owner}` and `{repo}` from the git remote. Use the explicit `PR_NUMBER` from step 1.

**Review event policy:**

- Use `event: "COMMENT"` for normal reviews.
- Use `event: "REQUEST_CHANGES"` only when there are critical findings that block merge.

**Posting policy:**

- **Anchored findings** → inline comments on the specific representative line.
- **Unanchorable findings** (changed file but no safe diff line) → summary body as `file:line` references.
- **Duplicated root causes** → one representative inline comment plus a summary-body entry listing all affected files.
- Reserve inline comments for issues tied to a specific representative line. Cross-document or cross-file consistency problems should usually be summarized once in the review body instead of repeated across every affected file.

**Inline comment format:**

Each inline comment body should begin with the severity tag: `**critical**:`, `**important**:`, or `**suggestion**:`, followed by the finding message.

**Summary body format:**

```markdown
## OpenCode PR Review

Reviewed <N> files across <M> areas: <comma-separated agent names>.

### Critical (<count>)

- `file:line` — issue (unanchorable findings and aggregated root-cause occurrences; anchored ones appear inline)

### Important (<count>)

- `file:line` — issue (unanchorable findings and aggregated root-cause occurrences)

### Suggestions (<count>)

- `file:line` — issue (unanchorable findings and aggregated root-cause occurrences)
```

When a root cause affects multiple files, list the representative inline comment once and add a single summary entry naming all affected files (e.g. `Same inconsistency across README.md, SKILL.md, review-pr.md — see inline comment on README.md:42`).

If there are **no findings at all**, post:

```text
No noteworthy issues found.
```

Do not spam praise or padding. One concise confirmation is sufficient.

### Failure fallback

If `gh api .../reviews` fails:

1. **Retry without invalid inline comments**: if the error message identifies a specific invalid comment, remove it (move that finding to the summary body) and retry once.
2. **Fall back to top-level comment**: if still failing, post a single top-level comment with the full summary plus all findings as `file:line` references:

```bash
gh pr comment "$PR_NUMBER" --body "$SUMMARY"
```

Never leave the user with no feedback.

### Local mode

Print the same summary to the user. Do not call `gh`.

## 8. Notes

- Keep feedback concise. A short review with real signal beats a long review with padding.
- Never post secrets, tokens, or full file contents in comments.
- The workflow grants `pull-requests: write`, so `GH_TOKEN` or `GITHUB_TOKEN` can post reviews when passed to the OpenCode step. Do not attempt to push commits or merge.
- If `$ARGUMENTS` lists specific aspects, respect them and skip the rest.
- Re-run after fixes to verify issues are resolved.
