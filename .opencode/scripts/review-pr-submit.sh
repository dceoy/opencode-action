#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
state_dir="${HOME}/.config/opencode/review-state"
initial_payload="${state_dir}/initial.json"
update_payload="${state_dir}/update.json"
review_id_file="${state_dir}/review_id"

load_token_lib() {
  local token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  [[ -f "${token_lib}" ]] || fail "OpenCode App token resolver is unavailable."
  # shellcheck source=/dev/null
  source "${token_lib}"
}

trusted_context() {
  repo="${GITHUB_REPOSITORY:-}"
  event_path="${GITHUB_EVENT_PATH:-}"
  [[ "${repo}" =~ ^[^/]+/[^/]+$ && -f "${event_path}" ]] || return 1
  pr_number="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")"
  [[ "${pr_number}" =~ ^[1-9][0-9]*$ ]] || return 1
  head_sha="$(jq -r '.pull_request.head.sha // empty' "${event_path}")"
  if [[ ! "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    head_sha="$(gh pr view "${pr_number}" --json headRefOid --jq .headRefOid)"
  fi
  [[ "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]]
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take no arguments."

case "${operation}" in
  prepare)
    rm -rf "${state_dir}"
    (umask 077; mkdir -p "${state_dir}"; : >"${initial_payload}"; : >"${update_payload}")
    ;;
  submit-initial)
    trusted_context || fail "Trusted pull request context is unavailable."
    jq -e 'keys == ["body", "comments"] and (.body | type == "string" and length > 0) and (.comments | type == "array" and length > 0)' "${initial_payload}" >/dev/null ||
      fail "Invalid initial review payload."
    request="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    trap 'rm -f "${request}"' EXIT
    jq --arg commit_id "${head_sha}" '. + {commit_id: $commit_id, event: "COMMENT"}' "${initial_payload}" >"${request}"
    load_token_lib
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    response="$(gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "${request}")"
    review_id="$(jq -r '.id // empty' <<<"${response}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Review ID was not returned."
    printf '%s' "${review_id}" >"${review_id_file}"
    printf '%s\n' "${response}"
    ;;
  update)
    trusted_context || fail "Trusted pull request context is unavailable."
    jq -e 'keys == ["body"] and (.body | type == "string" and length > 0)' "${update_payload}" >/dev/null ||
      fail "Invalid review update payload."
    [[ -f "${review_id_file}" ]] || fail "This run has no recorded review ID."
    review_id="$(cat "${review_id_file}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Recorded review ID is invalid."
    load_token_lib
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "${update_payload}"
    ;;
  *) fail "Unsupported review submission operation." ;;
esac
