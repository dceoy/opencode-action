#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
state_dir="${HOME}/.config/opencode/review-state"
context_file="${state_dir}/context.json"
initial_payload="${state_dir}/initial.json"
update_payload="${state_dir}/update.json"
review_id_file="${state_dir}/review_id"

load_token_lib() {
  local opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  [[ -f "${opencode_app_token_lib}" ]] || fail "OpenCode App token resolver is unavailable."
  # shellcheck source=/dev/null
  source "${opencode_app_token_lib}"
}

trusted_context() {
  local repo pr_number head_sha event_path event_pr current_head
  [[ -s "${context_file}" ]] || return 1
  repo="$(jq -r '.repository' "${context_file}")"
  pr_number="$(jq -r '.pr_number' "${context_file}")"
  head_sha="$(jq -r '.head_sha' "${context_file}")"
  event_path="${GITHUB_EVENT_PATH:-}"
  [[ "${repo}" == "${GITHUB_REPOSITORY:-}" && -f "${event_path}" ]] || return 1
  event_pr="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")"
  [[ "${event_pr}" == "${pr_number}" ]] || return 1
  current_head="$(gh pr view "${pr_number}" --json headRefOid --jq .headRefOid)"
  [[ "${current_head}" == "${head_sha}" ]] || return 1
  printf '%s\t%s\t%s\n' "${repo}" "${pr_number}" "${head_sha}"
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take no arguments."

case "${operation}" in
  prepare)
    rm -rf "${state_dir}"
    (umask 077; mkdir -p "${state_dir}"; : >"${context_file}"; : >"${initial_payload}"; : >"${update_payload}")
    ;;
  submit-initial)
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    context="$(trusted_context)" || fail "Pinned PR context is unavailable or the PR head changed."
    IFS=$'\t' read -r repo pr_number head_sha <<<"${context}"
    jq -e '
      keys == ["body", "comments"]
      and (.body | type == "string" and length > 0)
      and (.comments | type == "array" and length > 0)
      and all(.comments[];
        type == "object"
        and (.path | type == "string" and length > 0)
        and (.body | type == "string" and length > 0)
        and (
          (keys == ["body", "line", "path", "side"]
            and (.line | type == "number" and floor == . and . > 0)
            and (.side == "LEFT" or .side == "RIGHT"))
          or
          (keys == ["body", "line", "path", "side", "start_line", "start_side"]
            and (.line | type == "number" and floor == . and . > 0)
            and (.start_line | type == "number" and floor == . and . > 0)
            and .start_line <= .line
            and (.side == "LEFT" or .side == "RIGHT")
            and .start_side == .side)
        ))
    ' "${initial_payload}" >/dev/null ||
      fail "Invalid initial review payload."
    request="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    trap 'rm -f "${request}"' EXIT
    jq --arg commit_id "${head_sha}" '. + {commit_id: $commit_id, event: "COMMENT"}' "${initial_payload}" >"${request}"
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    context="$(trusted_context)" || fail "Pinned PR context is unavailable or the PR head changed during token verification."
    response="$(gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "${request}")"
    review_id="$(jq -r '.id // empty' <<<"${response}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Review ID was not returned."
    printf '%s' "${review_id}" >"${review_id_file}"
    printf '%s\n' "${response}"
    ;;
  update)
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    context="$(trusted_context)" || fail "Pinned PR context is unavailable or the PR head changed."
    IFS=$'\t' read -r repo pr_number _ <<<"${context}"
    jq -e 'keys == ["body"] and (.body | type == "string" and length > 0)' "${update_payload}" >/dev/null ||
      fail "Invalid review update payload."
    [[ -f "${review_id_file}" ]] || fail "This run has no recorded review ID."
    review_id="$(cat "${review_id_file}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Recorded review ID is invalid."
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    context="$(trusted_context)" || fail "Pinned PR context is unavailable or the PR head changed during token verification."
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "${update_payload}"
    ;;
  *) fail "Unsupported review submission operation." ;;
esac
