#!/usr/bin/env bash
# Install the bundled OpenCode configuration after review-mode detection.
# The function is sourceable for focused tests.

opencode_prepare_config() {
  local action_path="${1}" review_only="${2:-false}" config_dir helper
  local -a required_helpers=(
    resolve-app-token.sh
    review-pr-gh.sh
    review-pr-submit.sh
  )
  config_dir="${HOME}/.config/opencode"

  if [[ ! -d "${action_path}/.opencode" ]]; then
    echo "::error::Bundled OpenCode config is unavailable at '${action_path}/.opencode'." >&2
    return 1
  fi
  for helper in "${required_helpers[@]}"; do
    if [[ ! -f "${action_path}/.opencode/scripts/${helper}" ]]; then
      echo "::error::Bundled OpenCode helper '${helper}' is unavailable." >&2
      return 1
    fi
  done

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
      # OpenCode invokes trusted review helpers only from this installed config;
      # never execute helpers from the untrusted checkout's .opencode/scripts/.
      cp -rn "${action_path}/.opencode/." "${config_dir}/"
      echo "Copied bundled OpenCode config into ~/.config/opencode/"
      ;;
    *)
      echo "::error::Invalid review-only mode '${review_only}'." >&2
      return 1
      ;;
  esac
}

_opencode_prepare_main() {
  opencode_prepare_config "${ACTION_PATH:?ACTION_PATH is required}" "${REVIEW_ONLY:-false}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_prepare_main
fi
