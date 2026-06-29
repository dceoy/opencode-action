---
description: Comprehensive GitHub PR review — gathers the PR via gh, runs specialized review subagents in parallel, filters to noteworthy findings, and posts inline + summary review comments back to the PR.
agent: general
---

# Comprehensive PR Review

Perform a comprehensive pull request review by orchestrating specialized review subagents. Each subagent focuses on one area and returns **only noteworthy findings**. You then review every finding and keep only the ones **you also deem noteworthy**, then post the results back to the PR. Keep feedback concise; do not spam praise or nitpicks.

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
  - If it succeeds, you are in **PR mode**: post results back with `gh` (step 6).
  - If it fails (no PR or not in CI), fall back to **local mode**: review `git diff` and `git status`, and report findings directly to the user without posting anything to GitHub.
- Do not rely on the current git branch to identify the PR. GitHub Actions pull request workflows usually check out a detached merge ref.

## 2. Gather the diff

- **PR mode:** run `gh pr diff "$PR_NUMBER"` for the full diff and use the `files` list from `gh pr view "$PR_NUMBER"` for the changed-file set. Prefer `gh pr diff "$PR_NUMBER"` over `git diff` because CI checkouts are shallow (`fetch-depth: 1`).
- **Local mode:** run `git diff --name-only HEAD` plus untracked files from `git status --short` for the changed-file set, then `git diff` for content.

Capture both the changed-file list and the full diff to hand to the subagents.

## 3. Choose applicable reviewers

Default: run all applicable reviewers. Honor any aspects named in `$ARGUMENTS`:

- **code** - `code-reviewer` (general quality; **always applicable**)
- **performance** - `performance-reviewer` (loops, queries, allocations, hot paths)
- **security** - `security-code-reviewer` (external input, auth, secrets, trust boundaries)
- **tests** - `pr-test-analyzer` (if test files changed)
- **errors** - `silent-failure-hunter` (if error handling / catch blocks changed)
- **comments** - `comment-analyzer` (if comments or docs changed)
- **types** - `type-design-analyzer` (if new types are introduced)
- **simplify** - refinement only; do **not** run as part of the review. If the user passes `simplify`, run `code-simplifier` on the changed files instead of a review and stop.
- **all** - run all applicable reviewers (default)

Always run `code-reviewer`. Add the others when their trigger condition holds or the user explicitly requests them.

## 4. Launch the subagents

Spawn each applicable reviewer with the `task` tool, using its name as `subagent_type`. Pass the changed files, the full diff, and the PR metadata (title/body) as input. Launch them **in parallel** for speed.

Instruct every subagent to:

- Review only the changed lines (the diff) and the functions they belong to, not the whole repository.
- Return **only noteworthy findings** (confidence >= 80, real impact). No nitpicks, no praise spam.
- Format each finding as:
  - `file`: path
  - `line`: line number in the PR head file (so an inline review comment can anchor to it)
  - `severity`: `critical` | `important` | `suggestion`
  - `message`: concise description and concrete fix
- If nothing noteworthy, return an empty finding list and a one-line "no issues" note.

Do **not** let subagents post comments themselves. You are the only one who posts.

## 5. Filter and aggregate

Review every finding returned by the subagents. Keep only the findings **you also deem noteworthy**. Discard duplicates across agents, false positives, and trivial nits. This second filter is what keeps the review signal high.

Group surviving findings by severity:

- **Critical** — must fix before merge
- **Important** — should fix
- **Suggestions** — optional improvements

## 6. Post the results

### PR mode

Post a **single review** carrying the summary body plus inline comments, using the GitHub API via `gh api`. Use the explicit `PR_NUMBER` derived in step 1, and let `{owner}`/`{repo}` resolve from the git remote.

For inline comments, build a JSON payload with one entry per finding. Each inline comment must anchor to a line that is part of the diff for that file; use `side: "RIGHT"` and the head-file line number. For multi-line spans, add `start_line`/`start_side`. If a finding's line is not in the diff, move it into the summary body instead of an inline comment.

```bash
gh api -X POST repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews --input - <<'EOF'
{
  "event": "COMMENT",
  "body": "<summary markdown, see below>",
  "comments": [
    {"path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "**important**: ..."}
  ]
}
EOF
```

Summary body (`body` field) format:

```markdown
## OpenCode PR Review

Reviewed <N> files across <M> areas: <list areas>.

### Critical (X)

- `file:line` — issue

### Important (X)

- `file:line` — issue

### Suggestions (X)

- `file:line` — issue
```

If there are **no findings at all**, post a concise review body such as `No noteworthy issues found — looks good.` (one line, no inline comments). Do not open a review when there is nothing to say beyond noise, but a one-line confirmation is acceptable so users know the review ran.

If `gh api .../reviews` fails (e.g. a comment line is out of range), fall back to a single top-level `gh pr comment "$PR_NUMBER" --body "..."` with the summary plus a "findings with file:line" list. Never leave the user with no feedback.

Use `event: "COMMENT"` for normal reviews. Only use `event: "REQUEST_CHANGES"` when there are critical findings that block merge, and prefer `COMMENT` otherwise.

### Local mode

Print the same summary to the user. Do not call `gh`.

## 7. Notes

- Keep feedback concise. A short review with real signal beats a long review with padding.
- Never post secrets, tokens, or full file contents in comments.
- The workflow grants `pull-requests: write`, so `GH_TOKEN` or `GITHUB_TOKEN` can post reviews when passed to the OpenCode step. Do not attempt to push commits or merge.
- If `$ARGUMENTS` lists specific aspects, respect them and skip the rest.
- Re-run after fixes to verify issues are resolved.
