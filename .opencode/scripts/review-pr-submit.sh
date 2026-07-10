#!/usr/bin/env bash
# The only /review-pr helper permitted to write to GitHub. It validates every
# identifier and endpoint before calling gh, and never touches the checkout.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
valid_repo() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_number() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_payload() { jq -e "$1" "$2" >/dev/null 2>&1; }

load_token_resolver() {
  [[ -f "${HOME}/.config/opencode/scripts/resolve-app-token.sh" ]] || fail "OpenCode App token resolver script is unavailable."
  # shellcheck source=/dev/null
  source "${HOME}/.config/opencode/scripts/resolve-app-token.sh"
}

operation="${1:-}"

case "${operation}" in
  build-initial)
    [[ "$#" -eq 4 ]] || fail "Invalid initial review payload arguments."
    commit_id="$2"
    body="$3"
    comments="$4"
    [[ -n "${commit_id}" && -n "${body}" ]] || fail "Initial review payload values must not be empty."
    payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    chmod 600 "${payload}"
    jq -n --arg commit_id "${commit_id}" --arg body "${body}" --argjson comments "${comments}" \
      '{commit_id: $commit_id, event: "COMMENT", body: $body, comments: $comments}' >"${payload}"
    valid_payload '(.commit_id | type == "string" and length > 0) and .event == "COMMENT" and (.body | type == "string" and length > 0) and (.comments | type == "array" and length > 0)' "${payload}" || {
      rm -f "${payload}"
      fail "Invalid initial review payload."
    }
    printf '%s\n' "${payload}"
    ;;
  build-update)
    [[ "$#" -eq 2 ]] || fail "Invalid review update payload arguments."
    body="$2"
    [[ -n "${body}" ]] || fail "Review update body must not be empty."
    payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review-update.XXXXXX.json")"
    chmod 600 "${payload}"
    jq -n --arg body "${body}" '{body: $body}' >"${payload}"
    valid_payload 'keys == ["body"] and (.body | type == "string" and length > 0)' "${payload}" || {
      rm -f "${payload}"
      fail "Invalid review update payload."
    }
    printf '%s\n' "${payload}"
    ;;
  submit-initial)
    [[ "$#" -eq 4 ]] || fail "Invalid initial review submission arguments."
    repo="$2"
    pr_number="$3"
    valid_repo "${repo}" || fail "Invalid repository name for PR review submission."
    valid_number "${pr_number}" || fail "Invalid pull request number for review submission."
    payload="$4"
    [[ "${payload}" == "${TMPDIR:-/tmp}"/* && -f "${payload}" ]] || fail "Review payload must be a temporary file."
    valid_payload '(.commit_id | type == "string" and length > 0) and .event == "COMMENT" and (.body | type == "string" and length > 0) and (.comments | type == "array" and length > 0)' "${payload}" || fail "Invalid initial review payload."
    load_token_resolver
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || exit 1
    gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "${payload}"
    ;;
  update)
    [[ "$#" -eq 5 ]] || fail "Invalid review update arguments."
    repo="$2"
    pr_number="$3"
    valid_repo "${repo}" || fail "Invalid repository name for PR review submission."
    valid_number "${pr_number}" || fail "Invalid pull request number for review submission."
    review_id="$4"
    payload="$5"
    valid_number "${review_id}" || fail "Invalid review ID for review update."
    [[ "${payload}" == "${TMPDIR:-/tmp}"/* && -f "${payload}" ]] || fail "Review payload must be a temporary file."
    valid_payload 'keys == ["body"] and (.body | type == "string" and length > 0)' "${payload}" || fail "Invalid review update payload."
    load_token_resolver
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || exit 1
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "${payload}"
    ;;
  *) fail "Unsupported PR review submission operation." ;;
esac
