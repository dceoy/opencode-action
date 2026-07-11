#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  context)
    [[ "$#" -eq 1 ]]
    repo="${GITHUB_REPOSITORY:-}"
    event_path="${GITHUB_EVENT_PATH:-}"
    [[ "${repo}" =~ ^[^/]+/[^/]+$ && -f "${event_path}" ]]
    jq -e -n \
      --arg repository "${repo}" \
      --arg pr_number "$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")" \
      --arg head_sha "$(jq -r '.pull_request.head.sha // empty' "${event_path}")" \
      '($pr_number | test("^[1-9][0-9]*$")) and ($head_sha | test("^[0-9a-fA-F]{7,64}$")) |
       {repository: $repository, pr_number: ($pr_number | tonumber), head_sha: $head_sha}'
    ;;
  pr)
    shift
    token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
    if [[ -f "${token_lib}" ]]; then
      source "${token_lib}"
      opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    fi
    exec gh pr "$@"
    ;;
  *)
    echo "::error::Unsupported review-pr GitHub read operation." >&2
    exit 2
    ;;
esac
