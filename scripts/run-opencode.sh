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

_opencode_report_annotation() {
  local level="${1}" message="${2}"
  message="${message//'%'/'%25'}"
  message="${message//$'\r'/'%0D'}"
  message="${message//$'\n'/'%0A'}"
  printf '::%s::%s\n' "${level}" "${message}"
}

opencode_report_error() {
  _opencode_report_annotation error "${1}"
}

_opencode_dir_has_entries() (
  local dir="${1}"
  local -a entries
  [[ -d "${dir}" ]] || return 1
  shopt -s nullglob dotglob
  entries=("${dir}"/*)
  ((${#entries[@]} > 0))
)

_opencode_data_has_account_db() (
  local data_dir="${1}"
  local -a dbs
  [[ -d "${data_dir}" ]] || return 1
  shopt -s nullglob
  dbs=("${data_dir}"/opencode*.db)
  ((${#dbs[@]} > 0))
)

# Print a reason and return success when the bundled model registry is not a
# deterministic authority for variant metadata. Normal runs deliberately do
# not inspect or enumerate OpenCode project/global/plugin configuration: they
# pass variants through. Review-only runs validate only when the action's fresh
# GitHub-hosted isolation leaves no known higher-trust OpenCode state behind.
_opencode_variant_passthrough_reason() {
  local data_dir managed_config_dir runner_os

  if [[ "${USE_BUNDLED_TOOLKIT:-false}" != "true" ]]; then
    printf "use-bundled-toolkit is false, so the bundled model registry is not installed"
    return 0
  fi
  if [[ "${REVIEW_ONLY:-false}" != "true" ]]; then
    printf "normal OpenCode runs may load external provider/model configuration that the action does not mirror"
    return 0
  fi
  if [[ "${GITHUB_ACTIONS:-false}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
    printf "the review is not running in the action's isolated GitHub-hosted environment"
    return 0
  fi

  runner_os="${RUNNER_OS:-$(uname -s 2> /dev/null || true)}"
  case "${runner_os}" in
    Linux)
      managed_config_dir="/etc/opencode"
      ;;
    macOS | Darwin)
      managed_config_dir="/Library/Application Support/opencode"
      ;;
    Windows | MINGW* | MSYS* | CYGWIN*)
      managed_config_dir="${ProgramData:-C:/ProgramData}/opencode"
      ;;
    *)
      printf "the runner OS '%s' is not recognized, so managed OpenCode state cannot be ruled out" "${runner_os:-unknown}"
      return 0
      ;;
  esac

  if _opencode_dir_has_entries "${managed_config_dir}"; then
    printf "managed OpenCode state exists at '%s' outside the action's review isolation" "${managed_config_dir}"
    return 0
  fi

  if [[ -n "${OPENCODE_DB:-}" ]]; then
    printf "OPENCODE_DB is set, so persisted OpenCode account or active-organization state may affect model metadata"
    return 0
  fi

  data_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
  if _opencode_data_has_account_db "${data_dir}"; then
    printf "a persisted OpenCode account database exists under '%s', so active-organization configuration may affect model metadata" "${data_dir}"
    return 0
  fi
  if [[ -f "${data_dir}/auth.json" ]]; then
    printf "persisted OpenCode authentication exists at '%s', so remote or organization configuration may affect model metadata" "${data_dir}/auth.json"
    return 0
  fi

  if [[ "${runner_os}" == "macOS" || "${runner_os}" == "Darwin" ]]; then
    if command -v defaults > /dev/null 2>&1 && defaults read ai.opencode.managed > /dev/null 2>&1; then
      printf "macOS MDM-managed OpenCode preferences are present outside the action's review isolation"
      return 0
    fi
  fi

  return 1
}

# Reject a variant the bundled model registry does not declare only when that
# registry is authoritative. An empty variant is always allowed. Models absent
# from the registry pass through silently; models present without a variants
# key pass through with a warning. Nothing is substituted or normalized.
opencode_validate_variant() {
  local model="${1:-}" variant="${2:-}" bundled_config_file="${3:-}"
  local provider model_id candidate passthrough_reason bundled_json result jq_rc
  local -a supported=()

  [[ -n "${variant}" ]] || return 0

  provider="${model%%/*}"
  model_id="${model#*/}"

  passthrough_reason="$(_opencode_variant_passthrough_reason)" || true
  if [[ -n "${passthrough_reason}" ]]; then
    _opencode_report_annotation warning \
      "Model '${model}' variant compatibility was not validated (${passthrough_reason}), so variant '${variant}' was passed through to OpenCode. If the provider rejects the request, rerun with an empty variant."
    return 0
  fi

  if [[ ! -f "${bundled_config_file}" ]]; then
    opencode_report_error "Bundled OpenCode configuration not found at '${bundled_config_file}' while validating variant '${variant}' for model '${model}'."
    return 1
  fi
  if ! bundled_json="$(opencode_jsonc_to_json < "${bundled_config_file}")"; then
    opencode_report_error "Failed to parse the bundled OpenCode configuration at '${bundled_config_file}' while validating variant '${variant}' for model '${model}'."
    return 1
  fi

  set +e
  result="$(jq -r --arg provider "${provider}" --arg model "${model_id}" '
    if ((.provider[$provider].models // {}) | has($model) | not) then
      "absent"
    elif (.provider[$provider].models[$model] | has("variants") | not) then
      "no-variants"
    else
      (.provider[$provider].models[$model].variants | keys | join(","))
    end
  ' <<< "${bundled_json}" 2> /dev/null)"
  jq_rc=$?
  set -e
  if ((jq_rc != 0)); then
    opencode_report_error "Failed to read the bundled OpenCode model registry for '${model}' while validating variant '${variant}' (jq exited ${jq_rc})."
    return 1
  fi

  case "${result}" in
    absent)
      return 0
      ;;
    no-variants)
      _opencode_report_annotation warning \
        "Model '${model}' is in the action's bundled model registry but does not declare supported variants, so variant '${variant}' was passed through to OpenCode without validating compatibility. If the provider rejects the request, rerun with an empty variant."
      return 0
      ;;
    "")
      opencode_report_error "Model '${model}' does not support variant '${variant}'. This model declares no variants. Remove the 'variant' input, or set it to an empty string, to run the model with its default configuration."
      return 1
      ;;
    *)
      IFS=',' read -r -a supported <<< "${result}"
      for candidate in "${supported[@]}"; do
        if [[ "${candidate}" == "${variant}" ]]; then
          return 0
        fi
      done
      opencode_report_error "Model '${model}' does not support variant '${variant}'. Supported variants: ${result//,/, }. Set 'variant' to one of those values, or leave it empty to run the model with its default configuration."
      return 1
      ;;
  esac
}

opencode_report_failure() {
  local status="${1}" output_file="${2}" timeout_minutes="${3}" model="${4:-unknown}" opencode_version="${5:-unknown}"
  local terminal_error terminal_json_parse terminal_rest_failure context
  context="model '${model:-unknown}' (opencode ${opencode_version:-unknown})"

  if [[ "${status}" -eq 124 ]]; then
    opencode_report_error "OpenCode timed out after ${timeout_minutes} minutes for ${context}."
    return
  fi

  terminal_error="$(
    grep -Ei \
      'Request timed out|SSE read timed out|TimeoutError|AI_APICallError|Insufficient credits|rate[ -]?limit|HTTP[^[:digit:]]*(402|429)|status(Code)?[^[:digit:]]*(402|429)|"code"[^[:digit:]]*(402|429)' \
      "${output_file}" | tail -n 1 || true
  )"

  if grep -Eiq 'Request timed out|SSE read timed out|TimeoutError' <<< "${terminal_error}"; then
    opencode_report_error "OpenCode provider request timed out for ${context}."
    return
  elif grep -Eiq 'rate[ -]?limit|HTTP[^[:digit:]]*429|status(Code)?[^[:digit:]]*429|"code"[^[:digit:]]*429' <<< "${terminal_error}"; then
    opencode_report_error "OpenCode failed because the model provider rate limited the request (HTTP 429) for ${context}."
    return
  elif grep -Eiq 'Insufficient credits|HTTP[^[:digit:]]*402|status(Code)?[^[:digit:]]*402|"code"[^[:digit:]]*402' <<< "${terminal_error}"; then
    opencode_report_error "OpenCode failed because of model provider billing or quota (HTTP 402 or insufficient credits) for ${context}."
    return
  elif grep -Eiq 'AI_APICallError' <<< "${terminal_error}"; then
    opencode_report_error "OpenCode failed with a model provider API error for ${context}. Check provider credentials and service status."
    return
  fi

  read -r terminal_json_parse terminal_rest_failure < <(
    awk '
      function normalize(value) {
        gsub(sprintf("%c", 27) "\\[[0-9;?]*[ -/]*[@-~]", "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return tolower(value)
      }

      function is_json_parse_error(value) {
        return value ~ /^(error:[[:space:]]*)?(failed to parse json|syntaxerror:.*json.*|unexpected token.*json.*)$/
      }

      function is_rest_error(value) {
        return value ~ /is not an object \(evaluating [^)]*\.rest[^)]*\)$/
      }

      {
        normalized = normalize($0)
        if (normalized != "") {
          previous_three = previous_two
          previous_two = previous
          previous = terminal
          terminal = normalized
        }
      }

      END {
        if (is_json_parse_error(terminal)) {
          print "true false"
        } else if (terminal == "creating comment..." && is_json_parse_error(previous)) {
          print "true false"
        } else if (is_rest_error(terminal) && is_json_parse_error(previous)) {
          print "true true"
        } else if (is_rest_error(terminal) && previous == "creating comment..." && is_json_parse_error(previous_two)) {
          print "true true"
        } else if (is_rest_error(terminal) && previous == "error: unexpected error" && previous_two == "creating comment..." && is_json_parse_error(previous_three)) {
          print "true true"
        } else {
          print "false false"
        }
      }
    ' "${output_file}"
  )

  if [[ "${terminal_json_parse}" == "true" ]]; then
    local message="OpenCode failed to parse a JSON response while running for ${context}."
    if [[ "${terminal_rest_failure}" == "true" ]]; then
      message+=" OpenCode then hit a secondary failure while accessing '.rest' on a non-object value, masking further output."
    fi
    message+=" The underlying failure may be in OpenCode or the provider response path; do not assume OIDC or credentials are at fault unless the log shows direct evidence of that."
    opencode_report_error "${message}"
    return
  fi

  opencode_report_error "OpenCode failed with exit code ${status} for ${context}."
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

  opencode_apply_streaming_option

  opencode_validate_variant \
    "${MODEL:-}" "${VARIANT:-}" "${ACTION_PATH:-}/.opencode/opencode.jsonc" || return 1

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
