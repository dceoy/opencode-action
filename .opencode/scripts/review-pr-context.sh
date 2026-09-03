#!/usr/bin/env bash
# Shared trusted GitHub Actions context validation for the PR review helpers.
# This file is sourced only by its installed sibling helpers.

opencode_review_event_pr_number() {
  local event_path="${GITHUB_EVENT_PATH:-}" number

  [[ -f "${event_path}" ]] || return 1
  number="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")" || return 1
  [[ "${number}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "${number}"
}

opencode_review_sha_is_valid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{7,64}$ ]]
}

opencode_review_pinned_context() {
  local state_dir context_file repo pr_number base_sha head_sha event_pr

  state_dir="${HOME}/.config/opencode/review-state"
  context_file="${state_dir}/context.json"
  [[ -s "${context_file}" ]] || return 1

  repo="$(jq -er '.repository | select(type == "string")' "${context_file}")" || return 1
  pr_number="$(jq -er '.pr_number | select(type == "number" and floor == . and . > 0) | tostring' "${context_file}")" || return 1
  base_sha="$(jq -er '.base_sha | select(type == "string")' "${context_file}")" || return 1
  head_sha="$(jq -er '.head_sha | select(type == "string")' "${context_file}")" || return 1

  [[ "${repo}" =~ ^[^/]+/[^/]+$ ]] || return 1
  opencode_review_sha_is_valid "${base_sha}" || return 1
  opencode_review_sha_is_valid "${head_sha}" || return 1
  [[ "${repo}" == "${GITHUB_REPOSITORY:-}" ]] || return 1
  event_pr="$(opencode_review_event_pr_number)" || return 1
  [[ "${event_pr}" == "${pr_number}" ]] || return 1

  printf '%s\t%s\t%s\t%s\n' "${repo}" "${pr_number}" "${base_sha}" "${head_sha}"
}

opencode_review_verify_commit() {
  local repo="${1:-}" head_sha="${2:-}" resolved_sha

  [[ "$#" -eq 2 ]] || return 1
  [[ "${repo}" =~ ^[^/]+/[^/]+$ ]] || return 1
  opencode_review_sha_is_valid "${head_sha}" || return 1

  resolved_sha="$(gh api "repos/${repo}/commits/${head_sha}" --jq .sha)" || return 1
  [[ "${resolved_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 1
  [[ "${resolved_sha}" == "${head_sha}" ]]
}

opencode_review_trusted_context() {
  local context repo pr_number base_sha head_sha

  context="$(opencode_review_pinned_context)" || return 1
  IFS=$'\t' read -r repo pr_number base_sha head_sha <<< "${context}"
  opencode_review_verify_commit "${repo}" "${head_sha}" || return 1

  printf '%s\t%s\t%s\t%s\n' "${repo}" "${pr_number}" "${base_sha}" "${head_sha}"
}
