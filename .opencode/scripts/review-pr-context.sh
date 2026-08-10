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

opencode_review_trusted_context() {
  local state_dir context_file repo pr_number head_sha event_pr current_head

  state_dir="${HOME}/.config/opencode/review-state"
  context_file="${state_dir}/context.json"
  [[ -s "${context_file}" ]] || return 1

  repo="$(jq -er '.repository | select(type == "string")' "${context_file}")" || return 1
  pr_number="$(jq -er '.pr_number | select(type == "number" and floor == . and . > 0) | tostring' "${context_file}")" || return 1
  head_sha="$(jq -er '.head_sha | select(type == "string")' "${context_file}")" || return 1

  [[ "${repo}" =~ ^[^/]+/[^/]+$ ]] || return 1
  [[ "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 1
  [[ "${repo}" == "${GITHUB_REPOSITORY:-}" ]] || return 1
  event_pr="$(opencode_review_event_pr_number)" || return 1
  [[ "${event_pr}" == "${pr_number}" ]] || return 1

  current_head="$(gh pr view "${pr_number}" --repo "${repo}" --json headRefOid --jq .headRefOid)" || return 1
  [[ "${current_head}" == "${head_sha}" ]] || return 1

  printf '%s\t%s\t%s\n' "${repo}" "${pr_number}" "${head_sha}"
}
