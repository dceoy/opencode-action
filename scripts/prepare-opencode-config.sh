#!/usr/bin/env bash
# Install the bundled OpenCode configuration after review-mode detection.
# The function is sourceable for focused tests.

_opencode_copy_missing_config() {
  local source_dir="${1}" destination_dir="${2}" source relative destination

  # Validate every destination directory before copying anything: a symlinked
  # destination encountered mid-copy would otherwise get written through
  # before its own turn in the loop is reached.
  while IFS= read -r -d '' source; do
    relative="${source#"${source_dir}/"}"
    destination="${destination_dir}/${relative}"
    if [[ -d "${source}" && -L "${destination}" ]]; then
      echo "::error::'${destination}' is a symlink; refusing to install bundled OpenCode config through it." >&2
      return 1
    fi
  done < <(find "${source_dir}" -mindepth 1 -print0)

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
    review-pr-context.sh
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
  if [[ -L "${config_dir}" ]]; then
    echo "::error::'${config_dir}' is a symlink; refusing to write the OpenCode config through it." >&2
    return 1
  fi

  case "${review_only}" in
    true)
      if [[ -L "${HOME}/.opencode" ]]; then
        echo "::error::'${HOME}/.opencode' is a symlink; refusing to run review-only isolation without a trustworthy state directory." >&2
        return 1
      fi
      if [[ -L "${HOME}/.opencode/bin" ]]; then
        echo "::error::'${HOME}/.opencode/bin' is a symlink; refusing to run review-only isolation without a trustworthy state directory." >&2
        return 1
      fi
      if [[ -L "${HOME}/.config" ]]; then
        echo "::error::'${HOME}/.config' is a symlink; refusing to run review-only isolation without a trustworthy config directory." >&2
        return 1
      fi
      export XDG_CONFIG_HOME="${HOME}/.config"
      rm -rf "${config_dir}"
      mkdir -p "${config_dir}"
      cp -r "${action_path}/.opencode/." "${config_dir}/"
      if [[ -d "${HOME}/.opencode" ]]; then
        # Remove inherited plugins, agents, config, and "bin" so no
        # executable left on PATH (via GITHUB_PATH) survives from prior
        # runner state; the Install step that follows repopulates "bin"
        # with only the expected OpenCode binary for this job (Cache is
        # skipped for review-only runs, see action.yml).
        find "${HOME}/.opencode" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      fi
      echo "Installed fresh review-only OpenCode config"
      ;;
    false)
      mkdir -p "${config_dir}"
      # OpenCode invokes trusted review helpers only from this installed config;
      # never execute helpers from the untrusted checkout's .opencode/scripts/.
      _opencode_copy_missing_config "${action_path}/.opencode" "${config_dir}" || return 1
      mkdir -p "${config_dir}/scripts"
      if [[ -L "${config_dir}/scripts" ]]; then
        echo "::error::'${config_dir}/scripts' is a symlink; refusing to install trusted review helpers without a trustworthy destination." >&2
        return 1
      fi
      for helper in "${required_helpers[@]}"; do
        # Unlink any existing destination first so a symlinked helper path
        # left over from prior runner state is replaced, not written through.
        rm -f "${config_dir}/scripts/${helper}"
        cp "${action_path}/.opencode/scripts/${helper}" "${config_dir}/scripts/${helper}"
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
