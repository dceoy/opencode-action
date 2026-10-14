#!/usr/bin/env bash
# Install only provider configuration for regular runs; isolate review support.
opencode_prepare_config() {
  local action_path="${1}" review_only="${2:-false}" config_dir
  config_dir="${HOME}/.config/opencode"
  if [[ ! -d "${action_path}/.opencode" ]]; then
    echo "::error::Bundled OpenCode config is unavailable at '${action_path}/.opencode'." >&2
    return 1
  fi
  if [[ -L "${HOME}/.config" || -L "${config_dir}" ]]; then
    echo "::error::OpenCode config parent is a symlink; refusing to write through it." >&2
    return 1
  fi
  case "${review_only}" in
    true)
      # action.yml supplies a fresh temporary HOME in review-only mode.
      # Never delete inherited OpenCode state on a persistent runner.
      if [[ -e "${config_dir}" || -L "${config_dir}" ]]; then
        echo "::error::Review-only requires a fresh, empty OpenCode config directory." >&2
        return 1
      fi
      export XDG_CONFIG_HOME="${HOME}/.config"
      mkdir -p "${config_dir}"
      cp -r "${action_path}/.opencode/." "${config_dir}/"
      ;;
    false)
      mkdir -p "${config_dir}"
      # Only the provider registry belongs in general OpenCode runs. The
      # native API bridge and token resolver are restricted review-only tools.
      if [[ ! -e "${config_dir}/opencode.jsonc" && ! -L "${config_dir}/opencode.jsonc" ]]; then
        cp "${action_path}/.opencode/opencode.jsonc" "${config_dir}/opencode.jsonc"
      fi
      ;;
    *)
      echo "::error::Invalid review-only mode '${review_only}'." >&2
      return 1
      ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  opencode_prepare_config "${ACTION_PATH:?ACTION_PATH is required}" "${REVIEW_ONLY:-false}"
fi
