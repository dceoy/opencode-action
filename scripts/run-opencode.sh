#!/usr/bin/env bash
# Resolve action inputs into an OpenCode invocation. Functions are sourceable
# so prompt/config/timeout/error behavior can be tested without the service.

opencode_select_timeout_command() {
  local timeout_minutes="${1}"
  OPENCODE_TIMEOUT_COMMAND=()
  if command -v timeout > /dev/null 2>&1; then
    OPENCODE_TIMEOUT_COMMAND=(timeout "${timeout_minutes}m")
  elif command -v gtimeout > /dev/null 2>&1; then
    OPENCODE_TIMEOUT_COMMAND=(gtimeout "${timeout_minutes}m")
  else
    echo "::warning::No timeout command found (timeout/gtimeout); running OpenCode without an enforced timeout."
  fi
}

opencode_report_failure() {
  local status="${1}" output_file="${2}" timeout_minutes="${3}" model="${4:-unknown}" opencode_version="${5:-unknown}"
  local terminal_error json_parse_error secondary_rest_error context
  context="model '${model:-unknown}' (opencode ${opencode_version:-unknown})"

  if [[ "${status}" -eq 124 ]]; then
    echo "::error::OpenCode timed out after ${timeout_minutes} minutes for ${context}."
    return
  fi

  terminal_error="$(
    grep -Ei \
      'Request timed out|SSE read timed out|TimeoutError|AI_APICallError|Insufficient credits|rate[ -]?limit|HTTP[^[:digit:]]*(402|429)|status(Code)?[^[:digit:]]*(402|429)|"code"[^[:digit:]]*(402|429)' \
      "${output_file}" | tail -n 1 || true
  )"

  if grep -Eiq 'Request timed out|SSE read timed out|TimeoutError' <<< "${terminal_error}"; then
    echo "::error::OpenCode provider request timed out for ${context}."
    return
  elif grep -Eiq 'rate[ -]?limit|HTTP[^[:digit:]]*429|status(Code)?[^[:digit:]]*429|"code"[^[:digit:]]*429' <<< "${terminal_error}"; then
    echo "::error::OpenCode failed because the model provider rate limited the request (HTTP 429) for ${context}."
    return
  elif grep -Eiq 'Insufficient credits|HTTP[^[:digit:]]*402|status(Code)?[^[:digit:]]*402|"code"[^[:digit:]]*402' <<< "${terminal_error}"; then
    echo "::error::OpenCode failed because of model provider billing or quota (HTTP 402 or insufficient credits) for ${context}."
    return
  elif grep -Eiq 'AI_APICallError' <<< "${terminal_error}"; then
    echo "::error::OpenCode failed with a model provider API error for ${context}. Check provider credentials and service status."
    return
  fi

  json_parse_error="$(
    grep -Ei 'Failed to parse JSON|SyntaxError:.*JSON|Unexpected token.*JSON' \
      "${output_file}" | tail -n 1 || true
  )"
  secondary_rest_error="$(
    grep -Ei "is not an object \\(evaluating '[^']*\\.rest[^']*'\\)" \
      "${output_file}" | tail -n 1 || true
  )"

  if [[ -n "${json_parse_error}" ]]; then
    local message="OpenCode failed to parse a JSON response while running for ${context}."
    if [[ -n "${secondary_rest_error}" ]]; then
      message+=" A secondary failure in OpenCode's own error-handling path (an uninitialized GitHub client, '.rest' accessed on undefined) then masked further output."
    fi
    message+=" The underlying failure may be in OpenCode or the provider response path; do not assume OIDC or credentials are at fault unless the log shows direct evidence of that."
    echo "::error::${message}"
    return
  fi

  echo "::error::OpenCode failed with exit code ${status} for ${context}."
}

opencode_configure_run() {
  local script_dir base_config
  local -a command_dirs
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ "${REVIEW_ONLY:-false}" == "true" ]]; then
    export XDG_CONFIG_HOME="${HOME}/.config"
    export OPENCODE_DISABLE_PROJECT_CONFIG=1
    # OPENCODE_DISABLE_PROJECT_CONFIG does not stop OpenCode's separate
    # discovery of project-level .claude/skills/**/SKILL.md and
    # .agents/skills/**/SKILL.md; only this flag does. Without it, a PR could
    # add a same-named external skill alongside the trusted bundled one.
    export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
    # Composite steps inherit caller env. Remove every explicit config
    # override before constructing the action's trusted inline config.
    unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT
  fi

  # shellcheck source=scripts/opencode-action-lib.sh
  source "${script_dir}/opencode-action-lib.sh"
  opencode_effective_prompt "${PROMPT:-}" "${MENTIONS:-}" "${GITHUB_EVENT_PATH:-}"
  if [[ "${REVIEW_ONLY:-false}" == "true" ]]; then
    command_dirs=("${ACTION_PATH}/.opencode/commands")
  else
    command_dirs=(
      "${GITHUB_WORKSPACE:-${PWD}}/.opencode/commands"
      "${HOME}/.config/opencode/commands"
    )
  fi
  if [[ "${USE_BUNDLED_TOOLKIT:-false}" == "true" && "${REVIEW_ONLY:-false}" != "true" ]]; then
    command_dirs+=("${ACTION_PATH}/.opencode/commands")
  fi

  opencode_resolve_prompt_and_agent \
    "${OPENCODE_EFFECTIVE_PROMPT}" "${AGENT:-}" "${command_dirs[@]}"
  if [[ -n "${PROMPT:-}" || -n "${OPENCODE_RESOLVED_COMMAND_FILE}" ]]; then
    export PROMPT="${OPENCODE_RESOLVED_PROMPT}"
  fi

  if [[ -n "${OPENCODE_RESOLVED_AGENT}" ]]; then
    base_config="{}"
    if [[ -n "${OPENCODE_CONFIG_CONTENT:-}" ]]; then
      base_config="$(opencode_jsonc_to_json <<< "${OPENCODE_CONFIG_CONTENT}")"
    fi
    OPENCODE_CONFIG_CONTENT="$(jq -nc \
      --arg agent "${OPENCODE_RESOLVED_AGENT}" \
      --argjson base "${base_config}" \
      '$base * {default_agent: $agent}')"
    export OPENCODE_CONFIG_CONTENT
  fi
}

_opencode_run_main() {
  local output_file opencode_status timeout_minutes
  timeout_minutes="${TIMEOUT_MINUTES:?TIMEOUT_MINUTES is required}"

  opencode_configure_run
  output_file="$(mktemp)"
  trap 'rm -f "${output_file}"' EXIT
  opencode_select_timeout_command "${timeout_minutes}"

  set +e
  "${OPENCODE_TIMEOUT_COMMAND[@]}" opencode github run 2>&1 | tee "${output_file}"
  opencode_status="${PIPESTATUS[0]}"
  set -e

  if [[ "${opencode_status}" -ne 0 ]]; then
    opencode_report_failure \
      "${opencode_status}" "${output_file}" "${timeout_minutes}" \
      "${MODEL:-unknown}" "${OPENCODE_VERSION:-unknown}"
    rm -f "${output_file}"
    trap - EXIT
    return "${opencode_status}"
  fi
  rm -f "${output_file}"
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_run_main "$@"
fi
