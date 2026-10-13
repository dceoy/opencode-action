#!/usr/bin/env bash
# Run GitHub CLI commands through a verified OpenCode GitHub App identity.
# This runs inside opencode github run, after its OIDC token exchange.
set -euo pipefail

pr_review_gh_main() {
  local script_dir repo pr_number url
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if (($# == 0)); then
    echo "::error::Usage: pr-review-gh.sh <gh subcommand> [args...]" >&2
    return 2
  fi
  case "${1}" in
    api) ;;
    pr)
      case "${2:-}" in
        view | diff | checks | status) ;;
        *)
          echo "::error::Unsupported gh pr subcommand in review-only mode." >&2
          return 2
          ;;
      esac
      ;;
    *)
      echo "::error::Unsupported gh subcommand in review-only mode." >&2
      return 2
      ;;
  esac

  url="${PR_REVIEW_URL:-}"
  if [[ -n "${url}" ]]; then
    if [[ "${url}" =~ ^https://github\.com/([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)/pull/([0-9]+)/?$ ]]; then
      repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      pr_number="${BASH_REMATCH[3]}"
    else
      echo "::error::Invalid PR_REVIEW_URL for verified GitHub App token use." >&2
      return 1
    fi
  else
    repo="${GITHUB_REPOSITORY:-}"
    pr_number=""
    if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
      pr_number="$(jq -r '.pull_request.number // .issue.number // .number // empty' "${GITHUB_EVENT_PATH}")"
    fi
  fi
  if [[ ! "${repo:-}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ || ! "${pr_number:-}" =~ ^[0-9]+$ ]]; then
    echo "::error::Cannot determine trusted owner/repo and PR number for GitHub App identity verification." >&2
    return 1
  fi

  # shellcheck source=.opencode/scripts/resolve-app-token.sh
  source "${script_dir}/resolve-app-token.sh"
  opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || return 1
  exec gh "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  pr_review_gh_main "$@"
fi
