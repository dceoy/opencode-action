#!/usr/bin/env bash
# Install the bundled OpenCode configuration after review-mode detection.
# The function is sourceable for focused tests.

_opencode_copy_missing_config() {
  local source_dir="${1}" destination_dir="${2}" source relative destination

  while IFS= read -r -d '' source; do
    relative="${source#"${source_dir}/"}"
    destination="${destination_dir}/${relative}"
    if [[ -d "${source}" ]]; then
      mkdir -p "${destination}"
    elif [[ ! -e "${destination}" && ! -L "${destination}" ]]; then
      cp -P "${source}" "${destination}"
    fi
  done < <(find "${source_dir}" -mindepth 1 -print0)
}

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
      if [[ -L "${HOME}/.opencode" ]]; then
        echo "::error::'${HOME}/.opencode' is a symlink; refusing to run review-only isolation without a trustworthy state directory." >&2
        return 1
      fi
      export XDG_CONFIG_HOME="${HOME}/.config"
      rm -rf "${config_dir}"
      mkdir -p "${config_dir}"
      cp -r "${action_path}/.opencode/." "${config_dir}/"
      if [[ -d "${HOME}/.opencode" ]]; then
        # Remove inherited plugins, agents, and config that could affect the
        # isolated review run. This now runs before the OpenCode binary is
        # cached or installed, so leave "bin" alone either way: the Cache and
        # Install steps that follow populate it for this job.
        find "${HOME}/.opencode" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
      fi
      echo "Installed fresh review-only OpenCode config"
      ;;
    false)
      mkdir -p "${config_dir}"
      # OpenCode invokes trusted review helpers only from this installed config;
      # never execute helpers from the untrusted checkout's .opencode/scripts/.
      _opencode_copy_missing_config "${action_path}/.opencode" "${config_dir}"
      mkdir -p "${config_dir}/scripts"
      for helper in "${required_helpers[@]}"; do
        cp -f \
          "${action_path}/.opencode/scripts/${helper}" \
          "${config_dir}/scripts/${helper}"
      done
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
