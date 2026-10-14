#!/usr/bin/env bash
# Copy the bundled provider configuration; review runs replace inherited state.
_opencode_copy_missing_config() {
  local source_dir="${1}" destination_dir="${2}" source relative destination
  while IFS= read -r -d '' source; do
    relative="${source#"${source_dir}/"}"
    destination="${destination_dir}/${relative}"
    if [[ -d "${source}" && -L "${destination}" ]]; then
      echo "::error::'${destination}' is a symlink; refusing to copy config through it." >&2
      return 1
    fi
  done < <(find "${source_dir}" -mindepth 1 -print0)
  while IFS= read -r -d '' source; do
    relative="${source#"${source_dir}/"}"
    # These helpers are exclusively for the restricted review agent.
    case "${relative}" in
      tools/pr-review-api.js | scripts/pr-review-gh.sh | scripts/resolve-app-token.sh) continue ;;
    esac
    destination="${destination_dir}/${relative}"
    if [[ -d "${source}" ]]; then
      mkdir -p "${destination}"
    elif [[ ! -e "${destination}" && ! -L "${destination}" ]]; then
      cp -P "${source}" "${destination}"
    fi
  done < <(find "${source_dir}" -mindepth 1 -print0)
}
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
      _opencode_copy_missing_config "${action_path}/.opencode" "${config_dir}" || return 1
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
