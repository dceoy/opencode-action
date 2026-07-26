#!/usr/bin/env bash
# Detect review-only runs before preparing the bundled OpenCode configuration.
# Functions are sourceable for focused tests.

opencode_is_review_prompt() {
  local effective_prompt="${1:-}" first_line
  first_line="${effective_prompt%%$'\n'*}"
  [[ "${first_line}" =~ ^/review-pr([[:space:]].*)?$ ]]
}

opencode_validate_review_version() {
  local original_version="${1:-}" version major minor patch prerelease
  version="${original_version#v}"

  if [[ ! "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z]+([.-][0-9A-Za-z]+)*))?(\+([0-9A-Za-z]+([.-][0-9A-Za-z]+)*))?$ ]]; then
    echo "::error::Review-only mode requires a semantic OpenCode version at or above 1.2.14 (got '${original_version}')." >&2
    return 1
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  prerelease="${BASH_REMATCH[5]:-}"
  if (( 10#${major} < 1 ||
    (10#${major} == 1 && 10#${minor} < 2) ||
    (10#${major} == 1 && 10#${minor} == 2 && 10#${patch} < 14) )) ||
    [[ "${major}.${minor}.${patch}" == "1.2.14" && -n "${prerelease}" ]]; then
    echo "::error::Review-only mode requires OpenCode 1.2.14 or newer (got '${original_version}')." >&2
    return 1
  fi
}

opencode_detect_review_mode() {
  local prompt="${1:-}" mentions="${2:-}" event_path="${3:-}"
  local use_bundled_toolkit="${4:-}" opencode_version="${5:-}"

  opencode_effective_prompt "${prompt}" "${mentions}" "${event_path}"
  OPENCODE_REVIEW_ONLY=false
  opencode_is_review_prompt "${OPENCODE_EFFECTIVE_PROMPT}" || return 0

  OPENCODE_REVIEW_ONLY=true
  if [[ "${use_bundled_toolkit}" != "true" ]]; then
    echo "::error::Review-only mode requires use-bundled-toolkit: true." >&2
    return 1
  fi
  opencode_validate_review_version "${opencode_version}"
}

_opencode_detect_main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # shellcheck source=scripts/expand-command.sh
  source "${script_dir}/expand-command.sh"
  opencode_detect_review_mode \
    "${PROMPT:-}" "${MENTIONS:-}" "${GITHUB_EVENT_PATH:-}" \
    "${USE_BUNDLED_TOOLKIT:-}" "${OPENCODE_VERSION:-}"
  printf 'enabled=%s\n' "${OPENCODE_REVIEW_ONLY}" >>"${GITHUB_OUTPUT}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_detect_main
fi
