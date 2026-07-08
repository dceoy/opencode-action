#!/usr/bin/env bash
# Deletes the top-level PR completion comment that `opencode github run`
# posts after a run, but only when the bundled /review-pr command already
# submitted a structured PR review (with inline comments) during that run.
#
# The decision is driven entirely by a JSON marker file that /review-pr
# writes on success (repository, pr_number, actor_login, submitted_at) -
# never by matching against comment body text - so this only ever removes
# the exact completion comment authored by the same actor immediately after
# the review was submitted. It never touches user comments, unrelated bots,
# or the review itself.
set -euo pipefail

marker_file="${1:-${OPENCODE_REVIEW_MARKER_FILE:-}}"

if [[ -z "${marker_file}" || ! -s "${marker_file}" ]]; then
  exit 0
fi

cleanup() {
  rm -f "${marker_file}"
}
trap cleanup EXIT

# This is a best-effort cleanup step: a malformed marker file or an API
# hiccup here must never fail the job for an otherwise-successful run, so
# every extraction below tolerates parse/lookup failure by falling back to
# an empty value and skipping cleanup instead of propagating an error.
repository="$(jq -r '.repository // empty' "${marker_file}" 2>/dev/null || true)"
pr_number="$(jq -r '.pr_number // empty' "${marker_file}" 2>/dev/null || true)"
actor_login="$(jq -r '.actor_login // empty' "${marker_file}" 2>/dev/null || true)"
submitted_at="$(jq -r '.submitted_at // empty' "${marker_file}" 2>/dev/null || true)"

if [[ -z "${repository}" || -z "${pr_number}" || -z "${actor_login}" || -z "${submitted_at}" ]]; then
  echo "::warning::Skipping duplicate PR completion comment cleanup: the review marker file is missing required fields."
  exit 0
fi

comments_json="$(gh api "repos/${repository}/issues/${pr_number}/comments" --paginate 2>/dev/null || echo '[]')"

mapfile -t comment_ids < <(
  jq -r \
    --arg actor_login "${actor_login}" \
    --arg submitted_at "${submitted_at}" \
    '.[] | select(.user.login == $actor_login and .created_at >= $submitted_at) | .id' \
    <<<"${comments_json}"
)

deleted=0
for comment_id in "${comment_ids[@]}"; do
  [[ -z "${comment_id}" ]] && continue
  if gh api --method DELETE "repos/${repository}/issues/comments/${comment_id}" >/dev/null 2>&1; then
    deleted=$((deleted + 1))
  fi
done

if [[ "${deleted}" -gt 0 ]]; then
  echo "Removed ${deleted} duplicate PR completion comment(s) authored by ${actor_login} after the structured review was submitted."
fi
