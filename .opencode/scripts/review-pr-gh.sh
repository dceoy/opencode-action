#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

state_dir="${HOME}/.config/opencode/review-state"
context_file="${state_dir}/context.json"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_context_lib="${script_dir}/review-pr-context.sh"
[[ -f "${trusted_context_lib}" ]] || fail "Trusted review context helper is unavailable."
# shellcheck source=/dev/null
source "${trusted_context_lib}"

load_read_token() {
  local opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  if [[ -f "${opencode_app_token_lib}" ]]; then
    # shellcheck source=/dev/null
    source "${opencode_app_token_lib}"
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
  fi
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take exactly one operation name and no additional arguments."
load_read_token

case "${operation}" in
  context)
    [[ -d "${state_dir}" && ! -s "${context_file}" ]] || fail "Run prepare exactly once before pinning context."
    repo="${GITHUB_REPOSITORY:-}"
    number="$(opencode_review_event_pr_number)" || fail "Trusted pull request number is unavailable."
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
    trusted_context="$(opencode_review_trusted_context)" ||
      fail "Pinned review context is unavailable or invalid, or the PR head changed."
    IFS=$'\t' read -r repo number _ <<<"${trusted_context}"
    exec gh pr view "${number}" --repo "${repo}" --json number,title,body,baseRefName,headRefName,headRefOid,files,url
    ;;
  diff)
    trusted_context="$(opencode_review_trusted_context)" ||
      fail "Pinned review context is unavailable or invalid, or the PR head changed."
    IFS=$'\t' read -r repo number _ <<<"${trusted_context}"
    exec gh pr diff "${number}" --repo "${repo}"
    ;;
  validate)
    opencode_review_trusted_context >/dev/null ||
      fail "Pinned review context is unavailable or invalid, or the PR head changed."
    ;;
  *) fail "Unsupported review-pr GitHub read operation." ;;
esac
