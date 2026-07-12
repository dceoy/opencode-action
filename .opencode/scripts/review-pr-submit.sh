#!/usr/bin/env bash
# Validate and submit one structured pull request review.
#
# The repository and PR number are derived from the GitHub Actions context.
# The caller supplies only a JSON payload containing commit_id, body, and a
# non-empty comments array. The helper injects event: COMMENT and refuses to
# submit when the live PR head differs from commit_id.
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

payload="${1:-}"
[[ -n "${payload}" && -f "${payload}" ]] || \
  fail "Usage: review-pr-submit.sh <review-payload.json>"

repo="${GITHUB_REPOSITORY:-}"
[[ "${repo}" == */* ]] || fail "GITHUB_REPOSITORY is missing or malformed."

pr_number=""
if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  pr_number="$(jq -r '.pull_request.number // .issue.number // empty' "${GITHUB_EVENT_PATH}")"
fi
if [[ -z "${pr_number}" && "${GITHUB_REF:-}" =~ ^refs/pull/([1-9][0-9]*)/(merge|head)$ ]]; then
  pr_number="${BASH_REMATCH[1]}"
fi
[[ "${pr_number}" =~ ^[1-9][0-9]*$ ]] || \
  fail "Unable to derive a pull request number from the GitHub event."

jq -e '
  keys == ["body", "comments", "commit_id"]
  and ((.commit_id | type) == "string"
    and (.commit_id | test("^[0-9a-f]{40}$")))
  and ((.body | type) == "string" and (.body | length) > 0)
  and ((.comments | type) == "array" and (.comments | length) > 0)
  and all(.comments[];
    type == "object"
    and ((.path | type) == "string" and (.path | length) > 0)
    and ((.body | type) == "string" and (.body | length) > 0)
    and (
      (keys == ["body", "line", "path", "side"]
        and ((.line | type) == "number"
          and (.line | floor) == .line and .line > 0)
        and (.side == "LEFT" or .side == "RIGHT"))
      or
      (keys == ["body", "line", "path", "side", "start_line", "start_side"]
        and ((.line | type) == "number"
          and (.line | floor) == .line and .line > 0)
        and ((.start_line | type) == "number"
          and (.start_line | floor) == .start_line and .start_line > 0)
        and .start_line <= .line
        and (.side == "LEFT" or .side == "RIGHT")
        and .start_side == .side)
    )
  )
' "${payload}" >/dev/null || \
  fail "Invalid review payload: expected exactly {commit_id, body, comments} with exact line or line-range comment fields."

resolver="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
[[ -f "${resolver}" ]] || fail "OpenCode App token resolver not found at ${resolver}."
# shellcheck source=/dev/null
source "${resolver}"

commit_id="$(jq -r '.commit_id' "${payload}")"
opencode_require_app_token_for_review \
  "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || exit 1
opencode_assert_pr_head_unchanged "${repo}" "${pr_number}" "${commit_id}" || exit 1

final_payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
trap 'rm -f "${final_payload}"' EXIT
chmod 600 "${final_payload}"
jq '{commit_id, event: "COMMENT", body, comments}' "${payload}" > "${final_payload}"

gh api --method POST \
  "repos/${repo}/pulls/${pr_number}/reviews" \
  --input "${final_payload}"
