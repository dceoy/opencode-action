#!/usr/bin/env bash
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }
state_dir="${HOME}/.config/opencode/review-state"
context_file="${state_dir}/context.json"

load_read_token() {
  local opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  if [[ -f "${opencode_app_token_lib}" ]]; then
    # shellcheck source=/dev/null
    source "${opencode_app_token_lib}"
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
  fi
}

event_pr_number() {
  local event_path="${GITHUB_EVENT_PATH:-}" number
  [[ -f "${event_path}" ]] || return 1
  number="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")"
  [[ "${number}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "${number}"
}

read_context() {
  local pinned_repo pinned_number pinned_head current_head
  [[ -s "${context_file}" ]] || fail "Pinned review context is unavailable."
  pinned_repo="$(jq -r '.repository' "${context_file}")"
  pinned_number="$(jq -r '.pr_number' "${context_file}")"
  pinned_head="$(jq -r '.head_sha' "${context_file}")"
  [[ "${pinned_repo}" == "${GITHUB_REPOSITORY:-}" ]] || fail "Pinned repository no longer matches the event."
  [[ "${pinned_number}" == "$(event_pr_number)" ]] || fail "Pinned PR number no longer matches the event."
  current_head="$(gh pr view "${pinned_number}" --repo "${pinned_repo}" --json headRefOid --jq .headRefOid)"
  [[ "${current_head}" == "${pinned_head}" ]] || fail "PR head changed after review context was pinned."
  printf '%s\t%s\t%s\n' "${pinned_repo}" "${pinned_number}" "${pinned_head}"
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take no arguments."
load_read_token

case "${operation}" in
  context)
    [[ -d "${state_dir}" && ! -s "${context_file}" ]] || fail "Run prepare exactly once before pinning context."
    repo="${GITHUB_REPOSITORY:-}"
    number="$(event_pr_number)" || fail "Trusted pull request number is unavailable."
    [[ "${repo}" =~ ^[^/]+/[^/]+$ ]] || fail "Trusted repository is unavailable."
    event_path="${GITHUB_EVENT_PATH:-}"
    head_sha="$(jq -r '.pull_request.head.sha // empty' "${event_path}")"
    if [[ ! "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
      head_sha="$(gh pr view "${number}" --repo "${repo}" --json headRefOid --jq .headRefOid)"
    fi
    [[ "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]] || fail "Trusted PR head SHA is unavailable."
    jq -n --arg repository "${repo}" --arg pr_number "${number}" --arg head_sha "${head_sha}" \
      '{repository: $repository, pr_number: ($pr_number | tonumber), head_sha: $head_sha}' >"${context_file}"
    chmod 600 "${context_file}"
    cat "${context_file}"
    ;;
  metadata)
    IFS=$'\t' read -r repo number _ < <(read_context)
    exec gh pr view "${number}" --repo "${repo}" --json number,title,body,baseRefName,headRefName,headRefOid,files,url
    ;;
  diff)
    IFS=$'\t' read -r repo number _ < <(read_context)
    exec gh pr diff "${number}" --repo "${repo}"
    ;;
  *) fail "Unsupported review-pr GitHub read operation." ;;
esac
