#!/usr/bin/env bash
# Detect review-only runs and install the bundled OpenCode configuration.
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

opencode_prepare_config() {
  local action_path="${1}" review_only="${2:-false}" config_dir helper_dir
  config_dir="${HOME}/.config/opencode"

  if [[ ! -d "${action_path}/.opencode" ]]; then
    echo "::error::Bundled OpenCode config is unavailable at '${action_path}/.opencode'." >&2
    return 1
  fi
  if [[ ! -f "${action_path}/.opencode/scripts/resolve-app-token.sh" ||
    ! -f "${action_path}/.opencode/scripts/review-pr-submit.sh" ]]; then
    echo "::error::Bundled OpenCode helper scripts are unavailable." >&2
    return 1
  fi

  case "${review_only}" in
    true)
      export XDG_CONFIG_HOME="${HOME}/.config"
      rm -rf "${config_dir}"
      mkdir -p "${config_dir}"
      cp -r "${action_path}/.opencode/." "${config_dir}/"
      if [[ -d "${HOME}/.opencode" ]]; then
        # Remove inherited plugins, agents, and config that could affect the
        # isolated review run, while retaining the installed binary.
        find "${HOME}/.opencode" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
      fi
      echo "Installed fresh review-only OpenCode config"
      ;;
    false)
      mkdir -p "${config_dir}"
      cp -rn "${action_path}/.opencode/." "${config_dir}/"
      helper_dir="${config_dir}/scripts/opencode-action"
      rm -rf "${helper_dir}"
      mkdir -p "${helper_dir}"
      cp -f "${action_path}/.opencode/scripts/resolve-app-token.sh" \
        "${action_path}/.opencode/scripts/review-pr-submit.sh" \
        "${helper_dir}/"
      echo "Copied bundled OpenCode config into ~/.config/opencode/"
      ;;
    *)
      echo "::error::Invalid review-only mode '${review_only}'." >&2
      return 1
      ;;
  esac
}

_opencode_prepare_main() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  case "${1:-}" in
    detect)
      # shellcheck source=scripts/expand-command.sh
      source "${script_dir}/expand-command.sh"
      opencode_detect_review_mode \
        "${PROMPT:-}" "${MENTIONS:-}" "${GITHUB_EVENT_PATH:-}" \
        "${USE_BUNDLED_TOOLKIT:-}" "${OPENCODE_VERSION:-}"
      printf 'enabled=%s\n' "${OPENCODE_REVIEW_ONLY}" >>"${GITHUB_OUTPUT}"
      ;;
    prepare)
      opencode_prepare_config "${ACTION_PATH:?ACTION_PATH is required}" "${REVIEW_ONLY:-false}"
      ;;
    *)
      echo "usage: $0 {detect|prepare}" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_prepare_main "$@"
fi
