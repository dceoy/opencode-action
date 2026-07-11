#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

trusted_context() {
  repo="${GITHUB_REPOSITORY:-}"
  event_path="${GITHUB_EVENT_PATH:-}"
  [[ "${repo}" =~ ^[^/]+/[^/]+$ && -f "${event_path}" ]] || return 1
  pr_number="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")"
  head_sha="$(jq -r '.pull_request.head.sha // empty' "${event_path}")"
  [[ "${pr_number}" =~ ^[1-9][0-9]*$ && "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]]
}

state_file() {
  local root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s/opencode-review-id.%s.%s' "${root}" "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT}"
}

load_token() {
  local token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  [[ -f "${token_lib}" ]] || fail "OpenCode App token resolver is unavailable."
  source "${token_lib}"
  opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
}

operation="${1:-}"
case "${operation}" in
  build-initial)
    [[ "$#" -eq 3 ]] || fail "Invalid initial payload arguments."
    trusted_context || fail "Trusted pull request context is unavailable."
    payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    chmod 600 "${payload}"
    jq -n --arg commit_id "${head_sha}" --arg body "$2" --argjson comments "$3" \
      '{commit_id: $commit_id, event: "COMMENT", body: $body, comments: $comments}' >"${payload}"
    jq -e '.body != "" and (.comments | type == "array" and length > 0)' "${payload}" >/dev/null ||
      fail "Invalid initial review payload."
    printf '%s\n' "${payload}"
    ;;
  build-update)
    [[ "$#" -eq 2 && -n "$2" ]] || fail "Invalid update payload arguments."
    payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review-update.XXXXXX.json")"
    chmod 600 "${payload}"
    jq -n --arg body "$2" '{body: $body}' >"${payload}"
    printf '%s\n' "${payload}"
    ;;
  submit-initial)
    [[ "$#" -eq 2 && -f "$2" ]] || fail "Invalid initial submission arguments."
    trusted_context || fail "Trusted pull request context is unavailable."
    [[ "$(jq -r '.commit_id' "$2")" == "${head_sha}" ]] || fail "Payload head SHA mismatch."
    load_token
    response="$(gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "$2")"
    review_id="$(jq -r '.id // empty' <<<"${response}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Review ID was not returned."
    file="$(state_file)" || fail "Workflow run context is unavailable."
    (umask 077; printf '%s' "${review_id}" >"${file}")
    printf '%s\n' "${response}"
    ;;
  update)
    [[ "$#" -eq 2 && -f "$2" ]] || fail "Invalid update arguments."
    trusted_context || fail "Trusted pull request context is unavailable."
    file="$(state_file)" || fail "Workflow run context is unavailable."
    [[ -f "${file}" ]] || fail "This run has no recorded review ID."
    review_id="$(cat "${file}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Recorded review ID is invalid."
    load_token
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "$2"
    ;;
  *) fail "Unsupported review submission operation." ;;
esac
