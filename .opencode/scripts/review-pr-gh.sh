#!/usr/bin/env bash
# Best-effort GH_TOKEN preparation for /review-pr's read-only `gh pr` calls,
# then exec gh. Reads never need a verified bot identity, only a candidate
# token, so this does not call opencode_require_app_token_for_review.
set -euo pipefail

opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
if [[ -f "${opencode_app_token_lib}" ]]; then
  # shellcheck source=/dev/null
  source "${opencode_app_token_lib}"
  opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
fi

exec gh "$@"
