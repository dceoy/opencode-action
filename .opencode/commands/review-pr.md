---
description: Comprehensive GitHub PR review — gathers the PR via gh, runs specialized review subagents in parallel, normalizes and deduplicates findings, validates diff anchors, and submits GitHub inline review comments when findings can be anchored.
agent: general
---

# Comprehensive PR Review

Perform a comprehensive pull request review by orchestrating specialized review subagents in parallel. Each subagent returns only noteworthy findings in a normalized format. You then deduplicate and filter across agents, validate each finding against the PR diff, and submit a single GitHub pull request review with inline comments for every finding that has a valid diff anchor.

When a structured GitHub review is submitted successfully, that review is the PR review summary; capture the submitted review ID and update that same review with the final status/run link (step 7). Never call `gh pr comment` or the issue comment API yourself to post a status comment. You may still return a short final assistant message after a successful submission — `opencode github run` posts it as a separate top-level completion comment, authored the same way the review was (see the token/identity section below), so at most one additional top-level comment appears alongside the review and its inline comments. Do not treat "exactly one top-level comment" as a requirement; a review plus an optional completion comment is the expected result.

**Requested review aspects (optional):** "$ARGUMENTS"

## 1. Detect the review context

Determine whether you are reviewing a real GitHub PR in GitHub Actions or working locally.

- In GitHub Actions the environment provides `GITHUB_EVENT_NAME`, `GITHUB_REPOSITORY`, `GITHUB_REF` (for example, `refs/pull/42/merge`), and `GITHUB_EVENT_PATH`. The `gh` CLI also requires `GH_TOKEN` or `GITHUB_TOKEN`.
- Before using `gh`, prefer the OpenCode GitHub App token that `opencode github run` installs into git credential configuration when `use-github-token` is false. This makes direct `gh api` review submissions appear as `opencode-agent[bot]` instead of `github-actions[bot]`.

Load the shared token resolver that the bundled toolkit installs alongside this command, falling back to inline stubs if it is ever missing:

```bash
opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
if [[ -f "${opencode_app_token_lib}" ]]; then
  # shellcheck source=/dev/null
  source "${opencode_app_token_lib}"
else
  opencode_resolve_app_token() { return 1; }
  opencode_prepare_gh_token() { return 1; }
  opencode_require_app_token_for_review() {
    [[ "${1:-false}" == "true" ]] && return 0
    echo "::error::OpenCode App token resolver script not found at ${HOME}/.config/opencode/scripts/resolve-app-token.sh; refusing to submit the PR review with a fallback token." >&2
    return 1
  }
fi

opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}"
```

`opencode_resolve_app_token` checks, in order: the exact local git-config key `http.https://github.com/.extraheader`, `git config --get-urlmatch http.extraheader https://github.com/`, every `http.*.extraheader` key via `git config --get-regexp 'http\..*\.extraheader'`, and the same via `git config --show-origin --get-regexp 'http\..*\.extraheader'` for includeIf/global-style credential files, matching only keys whose URL host is exactly `github.com` (not a substring match, so `notgithub.com` and `github.com.example.com` are rejected). It decodes only GitHub basic-auth extraheaders (`AUTHORIZATION: basic <base64 of x-access-token:<token>>`) and never prints the token, the decoded header, or other credential material.

Every resolved value is only a _candidate_: the exact local key actions/checkout uses to persist its own `GITHUB_TOKEN`-derived credential is indistinguishable, by format alone, from an OpenCode App token written to the same key. A workflow can legitimately have both a checkout-persisted credential at that highest-priority key and a real OpenCode App token from a lower-priority source (e.g. includeIf/global), so `opencode_resolve_app_token_candidates` enumerates every distinct candidate instead of stopping at the first. `opencode_require_app_token_for_review` (used in step 7) tries each candidate in order and does not trust any of them on format alone — for each one it calls `opencode_verify_app_token_identity`, which proves the candidate authors GitHub API writes as `opencode-agent[bot]` by creating a throwaway pending PR review with it, checking `.user.login` on the response, and deleting the pending review immediately regardless of the outcome. GitHub has no read-only "whoami" endpoint for GitHub App installation tokens (`GET /user` 403s for every installation token alike, including the workflow's own `GITHUB_TOKEN`), so this pending-review probe — a real API write, not a true read-only check — is the safest available alternative. A pending review is never visible to anyone but its own author until submitted, so a failed or mismatched check never publishes anything to the PR.

- `opencode_prepare_gh_token` above is a best-effort call for read operations (`gh pr view`, `gh pr diff`): when `use-github-token` is **not** `true`, it exports `GH_TOKEN`/`GITHUB_TOKEN` when a candidate App token is found, without verifying its identity. When `use-github-token` is `true`, it is a no-op and never touches `GH_TOKEN`/`GITHUB_TOKEN`, so an unverified git-config candidate (for example a checkout-persisted credential at the same extraheader key an App token would use) can never silently replace the workflow's own token that the caller explicitly opted into.
- **Credential precedence, exact:** for every write (step 7), every resolved candidate is tried and the first one that verifies as `opencode-agent[bot]` always wins and is exported, regardless of `use-github-token`. Only when _no_ candidate verifies does `use-github-token` decide the outcome: `true` falls back to the caller's original `GH_TOKEN`/`GITHUB_TOKEN` (left untouched since `opencode_prepare_gh_token` never overwrote it), `false` fails the run. Reads may use the unverified candidate token when `use-github-token` is not `true`. Structured PR review **submissions** (step 7) must not; they call `opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${GITHUB_REPOSITORY}" "${PR_NUMBER}"` immediately before every write, which re-resolves, re-verifies, and fails fast per that step's rules.
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
  - If it fails, fall back to **local mode**: review `git diff` and `git status`, and report findings directly to the user without posting anything to GitHub.
- Do not rely on the current git branch to identify the PR. GitHub Actions pull request workflows usually check out a detached merge ref.

## 2. Gather the diff

- **PR mode:** run `gh pr diff "$PR_NUMBER"` for the full diff and use the `files` list from `gh pr view "$PR_NUMBER"` for the changed-file set. Prefer `gh pr diff "$PR_NUMBER"` over `git diff` because CI checkouts are often shallow.
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
- `simplify` → run `code-simplifier` as a refinement step only; do not return a review; stop after simplification
- `all` or no argument → run all applicable reviewers

When `all` is requested or no aspect is specified, run the core reviewers unconditionally: `code-quality-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, `security-code-reviewer`, and `code-reviewer`.

Also run specialty reviewers conditionally: `pr-test-analyzer` for test changes, `silent-failure-hunter` for error-handling/fallback paths, `comment-analyzer` for comments/docstrings, and `type-design-analyzer` for type/schema changes. Do not include `code-simplifier` in the `all` review set.

## 4. Launch the subagents in parallel

Spawn each applicable reviewer as a subagent using the `task` tool with its agent name as `subagent_type`. Pass the changed-file list, full diff, PR title/body, and head branch.

Instruct every subagent to:

- Review only the changed lines and the functions they belong to, not the whole repository.
- Return only high-confidence, noteworthy findings (no nitpicks, no praise-only output).
- Format every finding using this normalized structure:

  ```yaml
  - file: path/to/file
    line: <head-file line number>
    severity: critical | important | suggestion
    source: <agent-name>
    message: <concise issue description and concrete fix>
  ```

- If no noteworthy findings exist, return an empty list and a one-line "no issues" note.

Do not let subagents post comments themselves. The orchestrator validates, deduplicates, and posts the final review.

## 5. Normalize, filter, and aggregate findings

Collect all findings from all subagents. Each finding must have `file`, `line`, `severity`, `source`, and `message`.

Apply these filtering rules in order:

1. Drop praise-only items.
2. Drop nitpicks, cosmetic preferences, and style-only feedback without real-world impact.
3. Drop findings whose `file` is not in the changed-file set. Do not validate `line` here; leave line validation to the anchoring step.
4. Deduplicate across agents. Keep the most specific finding when multiple agents report substantially the same issue at the same location.
5. Aggregate by root cause only when it still preserves an actionable inline anchor. Do not collapse anchorable findings into a top-level-only summary.
6. Perform an orchestrator second filter and remove any remaining finding you do not also deem noteworthy.

Group surviving findings by severity: critical (must fix before merge), important (should fix), and suggestion (optional improvement). Prefer fewer, higher-signal comments over exhaustive lists.

## 6. Validate anchors and build inline review comments

Before submitting a GitHub review, validate every finding against the PR diff and classify it as either `inline` or `summary_only`.

Inline-first contract:

- Every finding with a valid `file` and diff-anchorable `line` must become an inline review comment.
- Do not skip inline comments merely because the same finding is also listed in a summary.
- Do not convert all findings into a single top-level markdown response when one or more valid inline anchors exist.
- Summary-only findings are allowed only when the issue is real but cannot be safely anchored to the diff, such as a cross-file design issue or a stale/unavailable line.

Anchor validation rules:

- Obtain the diff hunk list from `gh pr diff "$PR_NUMBER"` in PR mode or `git diff` in local mode.
- A line is valid when it can be anchored on the head side of a hunk for the given file.
- Prefer anchoring to an added or modified line that directly caused the issue.
- If the reported line is not anchorable but the same finding has a nearby valid head-side diff line in the same file, adjust to the nearest relevant line and keep it inline.
- If no safe anchor exists, mark the finding `summary_only` with a short reason. Do not silently drop it.

Each inline comment body must be concise and self-contained:

```markdown
**<severity> · <source>**: <issue and concrete fix>
```

Avoid repeating the file path or line number inside the inline body because GitHub already displays the anchor.

## 7. Submit the review in PR mode

### No findings

If there are no findings after filtering, return exactly:

```text
No noteworthy issues found.
```

Do not post a GitHub review with an empty comments array.

### Findings with at least one inline anchor

Submit one GitHub pull request review via `gh api` using a structured review payload with `comments` entries. Use `gh api` instead of `gh pr review` because this workflow needs explicit per-line anchors.

The token policy is enforced immediately before each write below (first the review submission, then its summary update), not before any of the local payload-building steps in between, since re-running the gate without an intervening write would just repeat the same result at extra cost:

- If a candidate OpenCode App token is resolvable and verifies as `opencode-agent[bot]` (via a throwaway pending-review identity probe), this exports it as `GH_TOKEN`/`GITHUB_TOKEN` so the submission is authored by `opencode-agent[bot]`.
- If no token verifies and `USE_GITHUB_TOKEN` is not `"true"`, this fails fast (`::error::...` plus non-zero exit) instead of silently submitting the review under the workflow's `GH_TOKEN`/`GITHUB_TOKEN` or an unverified candidate, either of which could make the review appear under the wrong identity.
- If no token verifies and `USE_GITHUB_TOKEN` is `"true"`, this succeeds and the existing `GH_TOKEN`/`GITHUB_TOKEN` is used deliberately; a `github-actions[bot]`-authored review is expected in that mode.

Build the initial review body from trusted strings and normalized findings. Omit the summary-only count and the "Summary-only findings" section entirely when there are no summary-only findings:

- With summary-only findings (`summary_only_count > 0`):

  ```markdown
  OpenCode PR Review: <N> inline finding(s), <M> summary-only finding(s).

  Summary-only findings:

  - `<file>` — <fallback reason>: <issue and concrete fix>
  ```

- With no summary-only findings (`summary_only_count == 0`):

  ```markdown
  OpenCode PR Review: <N> inline finding(s).
  ```

Submit the review, capture the returned review ID, then update that same review with the final status/run link. Use the Pull Request Reviews update endpoint, not issue comments:

```bash
if ! opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${GITHUB_REPOSITORY}" "${PR_NUMBER}"; then
  exit 1
fi

review_payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
review_update_payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review-update.XXXXXX.json")"
chmod 600 "$review_payload" "$review_update_payload"
trap 'rm -f "${review_payload:-}" "${review_update_payload:-}"' EXIT

jq -n \
  --arg commit_id "$head_oid" \
  --arg body "$review_body" \
  --argjson comments "$comments_json" \
  '{commit_id: $commit_id, event: "COMMENT", body: $body, comments: $comments}' \
  > "$review_payload"

review_response="$(gh api \
  --method POST \
  "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews" \
  --input "$review_payload")"
review_id="$(jq -r '.id // empty' <<<"$review_response")"

if [[ -z "$review_id" ]]; then
  echo "Failed to capture submitted review ID; cannot update the review summary." >&2
  exit 1
fi

run_url=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

final_status="Submitted OpenCode PR review with ${inline_count} inline comment(s)."
if [[ "${summary_only_count}" -gt 0 ]]; then
  final_status="Submitted OpenCode PR review with ${inline_count} inline comment(s) and ${summary_only_count} summary-only finding(s)."
fi
if [[ -n "$run_url" ]]; then
  final_status="${final_status}

[github run](${run_url})"
fi

updated_review_body="${review_body}

---

${final_status}"

jq -n --arg body "$updated_review_body" '{body: $body}' > "$review_update_payload"

if ! opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${GITHUB_REPOSITORY}" "${PR_NUMBER}"; then
  exit 1
fi

gh api \
  --method PUT \
  "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews/${review_id}" \
  --input "$review_update_payload"
```

Operational requirements:

- Never submit, update, or retry a structured review without first calling `opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${GITHUB_REPOSITORY}" "${PR_NUMBER}"` immediately beforehand, including inside the retry path below. Do not rely on a token exported or verified earlier in the run; re-resolve and re-verify it right before each write.
- Do not fall back to a bare `GH_TOKEN`/`GITHUB_TOKEN` or an unverified candidate for a structured review submission when `use-github-token` is false and no OpenCode App token verifies — fail the run instead (see the token-policy snippet above).
- When `use-github-token` is true, a `github-actions[bot]`-authored review is expected and acceptable.
- Use the PR head SHA from `gh pr view --json headRefOid` as `commit_id`.
- Include `summary_only` findings in the review `body`, not as fake inline comments.
- Build `inline_count` and `summary_only_count` from the same normalized finding sets used to build the review body.
- Never call `gh pr comment` or the issue comment API yourself, for the success status or anything else. This is a hard rule regardless of whether you return final assistant text.
- If the review summary update fails, do not silently succeed; report the update failure so the workflow surfaces the broken behavior.
- Handle only GitHub 422 anchor-validation failures with the inline-comment retry path. Inspect the response `errors[].field` values such as `comments[0].line` to map failures back to specific `comments[N]` entries.
- If GitHub rejects one or more inline anchors and the offending entries can be identified, move only those findings to `summary_only` with the rejection reason and retry once.
- If a 422 anchor error does not identify the offending `comments[N]` entry, move all inline findings from that failed attempt to `summary_only` before retrying or falling back so no finding is lost.
- If the error indicates the `commit_id` is stale or is no longer part of the pull request, refetch `headRefOid`, rebuild the payload with the new SHA, and retry once. If the refetched SHA still fails, use the fallback path.
- If the retry still fails, do not claim inline comments were posted. Return a concise failure report and convert every attempted inline finding into a summary-only fallback entry, including its file, line, severity, source, message, and failure reason.

After a successful structured review submission and review summary update, the final status is already appended to the review itself. You may optionally return a short final assistant message (for example, confirming the review was submitted and linking the run); `opencode github run` posts it as a separate top-level completion comment authored the same way as the review, so it carries the same `opencode-agent[bot]` identity when `use-github-token` is false. Returning no final text is also fine. Either way, never call `gh pr comment` or the issue comment API yourself.

### Findings without inline anchors

If all findings are valid but none can be safely anchored inline, return a concise markdown review body as a top-level fallback and explicitly state why inline comments were not used.

## 8. Local mode

Print the same normalized review summary to the user. Do not call `gh api`, `gh pr review`, or `gh pr comment`.

## 9. Notes

- Keep feedback concise. A short review with real signal beats a long review with padding.
- Never include secrets, tokens, or full file contents in the review response or GitHub comments.
- Do not print tokens or decoded Git authentication headers in logs.
- Do not call `gh pr comment`; it creates top-level noise and bypasses inline review anchors.
- Use `gh api` only for the token identity-verification probe, the final PR review submission, and the follow-up update of that same review summary.
- If `$ARGUMENTS` lists specific aspects, respect them and skip the rest.
- Re-run after fixes to verify issues are resolved.
