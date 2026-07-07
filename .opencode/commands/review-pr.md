---
description: Comprehensive GitHub PR review — gathers the PR via gh, runs specialized review subagents in parallel, normalizes and deduplicates findings, validates diff anchors, and submits GitHub inline review comments when findings can be anchored.
agent: general
---

# Comprehensive PR Review

Perform a comprehensive pull request review by orchestrating specialized review subagents in parallel. Each subagent returns only noteworthy findings in a normalized format. You then deduplicate and filter across agents, validate each finding against the PR diff, and submit a GitHub pull request review with inline comments for every finding that has a valid diff anchor.

The surrounding `opencode github run` integration always posts your final text as a PR comment. Therefore, when you successfully submit GitHub review comments yourself, return only a short status message instead of a second full review body.

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

- If `PR_NUMBER` is set, run `gh pr view "$PR_NUMBER" --json number,title,body,baseRefName,headRefName,headRefOid,files,url` to confirm a PR is available.
  - If it succeeds, you are in **PR mode**: submit a GitHub PR review when findings exist (step 7).
  - If it fails (no PR or not in CI), fall back to **local mode**: review `git diff` and `git status`, and report findings directly to the user without posting anything to GitHub.
- Do not rely on the current git branch to identify the PR. GitHub Actions pull request workflows usually check out a detached merge ref.

## 2. Gather the diff

- **PR mode:** run `gh pr diff "$PR_NUMBER"` for the full diff and use the `files` list from `gh pr view "$PR_NUMBER"` for the changed-file set. Prefer `gh pr diff "$PR_NUMBER"` over `git diff` because CI checkouts are shallow (`fetch-depth: 1`).
- **Local mode:** run `git diff --name-only HEAD` plus untracked files from `git status --short` for the changed-file set, then `git diff` for content.

Capture the changed-file list, the full diff, and the PR metadata (title, body, base/head branch, head SHA) to hand to the subagents and to build the final review payload.

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

Do **not** let subagents post comments themselves. The orchestrator validates, deduplicates, and posts the final review.

## 5. Normalize, filter, and aggregate findings

### Normalization

Collect all findings from all subagents. Each finding must have `file`, `line`, `severity`, `source`, and `message`.

### Filtering rules (apply in order)

1. **Drop praise-only items**: remove any entry whose message is only positive (no actionable issue).
2. **Drop nitpicks**: remove cosmetic preferences, style-only feedback, or issues with no real-world impact.
3. **Drop findings not supported by the diff**: if the file referenced is not in the changed-file set, drop the finding. Do **not** compare `line` against the changed-file set — it contains paths, not line numbers. Leave line validation to the diff-anchoring step (step 6).
4. **Deduplicate across agents**: if two or more agents report substantially the same issue at the same location, keep the most specific one (usually from the specialized agent) and discard the duplicate.
5. **Aggregate by root cause only when it still preserves actionable anchors**: when several findings share the same underlying root cause, keep one representative inline comment at the best anchor and mention the other affected files briefly in that comment. Do not collapse anchored findings into a top-level-only summary when an inline anchor is available.
6. **Orchestrator second filter**: review every remaining finding yourself and remove any you do not also deem noteworthy. This filter keeps the signal high.

### Grouping

Group surviving findings by severity:

- **Critical** — must fix before merge
- **Important** — should fix
- **Suggestions** — optional improvements

Prefer fewer, higher-signal comments over exhaustive lists. Optional guardrail suggestions (such as adding tests for agent frontmatter or reference validation) should be downgraded to `suggestion` severity at most.

## 6. Validate anchors and build inline review comments

Before submitting a GitHub review, validate every finding against the PR diff and classify it as either `inline` or `summary_only`.

### Inline-first contract

- Every finding with a valid `file` and diff-anchorable `line` must become an inline review comment.
- Do not skip inline comments merely because the same finding is also listed in a summary.
- Do not convert all findings into a single top-level markdown response when one or more valid inline anchors exist.
- Summary-only findings are allowed only when the issue is real but cannot be safely anchored to the diff, such as a cross-file design issue or a stale/unavailable line.

### Anchor validation rules

- Obtain the diff hunk list from `gh pr diff "$PR_NUMBER"` (already gathered in step 2).
- For each finding, check whether its `line` is present in a hunk for `file` on the head side of the PR.
- Prefer anchoring to an added or modified line that directly caused the issue.
- If the reported line is not anchorable but the same finding has a nearby valid head-side diff line in the same file, adjust the anchor to that nearest relevant line and keep it inline.
- If no safe anchor exists, mark the finding `summary_only` with a short reason. Do not silently drop it.

### Inline comment body format

Each inline comment body must be concise and self-contained:

```markdown
**<severity> · <source>**: <issue and concrete fix>
```

Avoid repeating the file path or line number inside the inline body because GitHub already displays the anchor. Keep each body one short paragraph unless a minimal code suggestion is genuinely useful.

## 7. Submit the review in PR mode

### No findings

If there are no findings after filtering, return exactly:

```text
No noteworthy issues found.
```

Do not post a GitHub review with an empty comments array.

### Findings with at least one inline anchor

Submit a single GitHub pull request review using the REST API via `gh api`. Do not use `gh pr review` for inline findings because it cannot submit a structured `comments` array for per-line anchors in this workflow.

Build the review body from trusted strings and normalized findings. It must enumerate every summary-only item, including its fallback reason:

```markdown
OpenCode PR Review: <N> inline finding(s), <M> summary-only finding(s).

Summary-only findings:
- `<file>` — <fallback reason>: <issue and concrete fix>
```

Build the JSON payload with `jq`, not string interpolation, so PR-authored content cannot break JSON structure or inject fields. Write it to a private temporary file and always remove it after submission:

```bash
review_payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
chmod 600 "$review_payload"
trap 'rm -f "$review_payload"' EXIT

jq -n \
  --arg commit_id "$head_oid" \
  --arg body "$review_body" \
  --argjson comments "$comments_json" \
  '{commit_id: $commit_id, event: "COMMENT", body: $body, comments: $comments}' \
  > "$review_payload"

gh api \
  --method POST \
  "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews" \
  --input "$review_payload"
```

Operational requirements:

- `GH_TOKEN` or `GITHUB_TOKEN` must have `pull-requests: write` permission.
- Use the PR head SHA from `gh pr view --json headRefOid` as `commit_id`.
- Include `summary_only` findings in the review `body`, not as fake inline comments.
- Handle only GitHub 422 anchor-validation failures with the inline-comment retry path. Inspect the response `errors[].field` values such as `comments[0].line` to map failures back to specific `comments[N]` entries.
- If GitHub rejects one or more inline anchors and the offending entries can be identified, move only those findings to `summary_only` with the rejection reason and retry once.
- If a 422 anchor error does not identify the offending `comments[N]` entry, move all inline findings from that failed attempt to `summary_only` before retrying or falling back so no finding is lost.
- If the error indicates the `commit_id` is stale or is no longer part of the pull request, refetch `headRefOid`, rebuild the payload with the new SHA, and retry once. If the refetched SHA still fails, use the fallback path.
- If the retry still fails, do not claim inline comments were posted. Return a concise failure report and convert every attempted inline finding into a summary-only fallback entry, including its file, line, severity, source, message, and failure reason.

After a successful submission, return only a concise status for the surrounding OpenCode integration to post, for example:

```text
Submitted OpenCode PR review with 3 inline comment(s) and 1 summary-only finding.
```

### Findings without inline anchors

If all findings are valid but none can be safely anchored inline, return a concise markdown review body as a top-level fallback and explicitly state why inline comments were not used.

## 8. Local mode

Print the same normalized review summary to the user. Do not call `gh api`, `gh pr review`, or `gh pr comment`.

## 9. Notes

- Keep feedback concise. A short review with real signal beats a long review with padding.
- Never include secrets, tokens, or full file contents in the review response or GitHub comments.
- Do not call `gh pr comment`; it creates top-level noise and bypasses inline review anchors.
- Use `gh api` only for the single final PR review submission after all findings are normalized, deduplicated, and anchor-validated.
- If `$ARGUMENTS` lists specific aspects, respect them and skip the rest.
- Re-run after fixes to verify issues are resolved.
