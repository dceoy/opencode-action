---
description: Comprehensive GitHub PR review with stale-head protection and inline findings.
agent: build
---

# Comprehensive PR Review

Review the pull request, aggregate high-confidence findings from specialized reviewers, validate diff anchors, and submit one structured GitHub review when inline comments are available.

**Requested review aspects:** "$ARGUMENTS"

## 1. Detect and pin the review context

Load the bundled token resolver for GitHub reads:

```bash
opencode_app_token_lib="${HOME}/.config/opencode/scripts/opencode-action/resolve-app-token.sh"
if [[ -f "${opencode_app_token_lib}" ]]; then
  # shellcheck source=/dev/null
  source "${opencode_app_token_lib}"
else
  echo "OpenCode App token resolver not found." >&2
  exit 1
fi
opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
```

Derive the pull request number from `GITHUB_EVENT_PATH`, then from a `refs/pull/<number>/(merge|head)` `GITHUB_REF` fallback. When `GITHUB_REPOSITORY` and a PR number are available:

1. Fetch metadata with:

   ```text
   gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json number,title,body,baseRefName,headRefName,headRefOid,files,url
   ```

2. Record the returned `headRefOid` as `PINNED_HEAD_SHA`.
3. Fetch the full diff with:

   ```text
   gh pr diff "$PR_NUMBER" --repo "$GITHUB_REPOSITORY"
   ```

4. Immediately call:

   ```text
   opencode_assert_pr_head_unchanged "$GITHUB_REPOSITORY" "$PR_NUMBER" "$PINNED_HEAD_SHA"
   ```

Abort and request a rerun if the head moved while context was gathered. Never replace `PINNED_HEAD_SHA` with a newer commit after analysis begins.

If no PR can be resolved, use local mode: inspect `git status --short`, `git diff --name-only HEAD`, and `git diff`, then report findings directly without posting to GitHub.

## 2. Select reviewers

Supported aspects:

- `code`: `code-reviewer`, `code-quality-reviewer`
- `quality`: `code-quality-reviewer`
- `performance`: `performance-reviewer`
- `security`: `security-code-reviewer`
- `tests` or `coverage`: `test-coverage-reviewer`, `pr-test-analyzer`
- `docs` or `documentation`: `documentation-accuracy-reviewer`
- `comments`: `comment-analyzer`
- `errors`: `silent-failure-hunter`
- `types`: `type-design-analyzer`
- `simplify`: `code-simplifier` only
- `all` or no argument: all applicable reviewers except `code-simplifier`

`/review-pr simplify` is a review operation. It must return behavior-preserving simplification proposals as `suggestion` findings and must never edit files.

For `all` or no argument, always run `code-reviewer`, `code-quality-reviewer`, `performance-reviewer`, `security-code-reviewer`, `test-coverage-reviewer`, and `documentation-accuracy-reviewer`. Add specialty reviewers only when their subject appears in the diff.

## 3. Delegate analysis

Run applicable agents in parallel with the `task` tool. Pass the PR metadata, changed-file list, full diff, and pinned head SHA. Instruct each agent to inspect changed lines and their containing functions only and return:

```yaml
- file: path/to/file
  line: <head-file line number>
  severity: critical | important | suggestion
  source: <agent-name>
  message: <concise issue and concrete fix>
```

Subagents must not post comments. For `simplify`, require concrete, behavior-preserving proposals and keep severity `suggestion`.

## 4. Normalize and anchor

- Remove praise, nitpicks, style-only feedback, duplicates, and findings outside changed files.
- Keep the most specific finding for each root cause.
- Validate each proposed line against the captured diff for `PINNED_HEAD_SHA`.
- Move material but unanchorable findings into the review body as summary-only findings.
- Inline comment bodies must use:

  ```markdown
  **<severity> · <source>**: <issue and concrete fix>
  ```

## 5. Return or submit

Before returning any PR-mode conclusion, including “No noteworthy issues found” or an all-summary-only fallback, call:

```text
opencode_assert_pr_head_unchanged "$GITHUB_REPOSITORY" "$PR_NUMBER" "$PINNED_HEAD_SHA"
```

If no noteworthy findings remain, return exactly:

```text
No noteworthy issues found.
```

If findings exist but none has a safe inline anchor, return a concise markdown review body directly and state why inline comments were not used.

If at least one inline finding exists:

1. Build a temporary JSON file with exactly:

   ```json
   {
     "commit_id": "<PINNED_HEAD_SHA>",
     "body": "<review summary and summary-only findings>",
     "comments": [
       {
         "path": "path/to/file",
         "line": 123,
         "side": "RIGHT",
         "body": "**important · code-reviewer**: ..."
       }
     ]
   }
   ```

   Keep file-level findings in the review body as summary-only items; batch review comments require line anchors.

2. Submit it only through:

   ```text
   bash "$HOME/.config/opencode/scripts/opencode-action/review-pr-submit.sh" "$PAYLOAD_FILE"
   ```

The helper derives the repository and PR from the GitHub Actions context, validates the payload shape, injects `event: COMMENT`, verifies the review author token, and checks that the live head still equals `commit_id` immediately before the POST.

Do not call `gh pr comment`, the issue-comment API, or the review update `PUT`. Do not retry by moving findings to a newer head SHA. A rejected or stale submission must fail and be rerun against the current head.

## 6. Local mode

Print the normalized review summary directly. Do not call the review submission helper or any GitHub write API.

## 7. Notes

- Keep feedback concise and high signal.
- Never include credentials or full secret-bearing files in findings.
- Respect requested aspects and skip unrelated reviewers.
