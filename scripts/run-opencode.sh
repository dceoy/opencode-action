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

# True (prints a reason and returns 0) when something other than the bundled
# .opencode/opencode.jsonc could determine the final provider/model config,
# so that file can no longer be trusted as the single source of truth for
# $1/$2. False (prints nothing, returns 1) when the bundled registry is
# authoritative. Review-only runs always discard caller/project config before
# invoking OpenCode (see opencode_configure_run), so the bundled registry
# stays authoritative there regardless of what the caller's environment sets.
_opencode_variant_override_reason() {
  local provider="${1}" model_id="${2}" name project_file

  if [[ "${USE_BUNDLED_TOOLKIT:-false}" != "true" ]]; then
    printf "use-bundled-toolkit is false, so the bundled model registry is not installed"
    return 0
  fi

  [[ "${REVIEW_ONLY:-false}" != "true" ]] || return 1

  if [[ -n "${OPENCODE_CONFIG:-}" || -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
    printf "the workflow sets OPENCODE_CONFIG or OPENCODE_CONFIG_DIR, which can redefine any provider"
    return 0
  fi

  if [[ -n "${OPENCODE_CONFIG_CONTENT:-}" ]] \
    && _opencode_config_defines_model "${OPENCODE_CONFIG_CONTENT}" "${provider}" "${model_id}"; then
    printf "OPENCODE_CONFIG_CONTENT redefines '%s/%s'" "${provider}" "${model_id}"
    return 0
  fi

  for name in opencode.json opencode.jsonc; do
    project_file="${GITHUB_WORKSPACE:-${PWD}}/${name}"
    if [[ -f "${project_file}" ]] \
      && _opencode_config_defines_model "$(cat "${project_file}")" "${provider}" "${model_id}"; then
      printf "the repository's %s redefines '%s/%s'" "${name}" "${provider}" "${model_id}"
      return 0
    fi
  done

  return 1
}

_opencode_config_defines_model() {
  local content="${1}" provider="${2}" model_id="${3}" json rc
  json="$(opencode_jsonc_to_json <<< "${content}" 2> /dev/null)" || return 1
  set +e
  jq -e --arg provider "${provider}" --arg model "${model_id}" \
    '(.provider[$provider].models // {}) | has($model)' \
    <<< "${json}" > /dev/null 2>&1
  rc=$?
  set -e
  return "${rc}"
}

# Reject a variant the bundled model registry does not declare, before
# OpenCode starts. An empty variant is always allowed. Validation only
# applies while the bundled .opencode/opencode.jsonc is authoritative for
# this model (see _opencode_variant_override_reason); within that registry:
# - a model absent entirely (for example a dynamically discovered OpenCode Go
#   model, never listed in opencode.json) passes the variant through
#   silently, since its absence says nothing about compatibility;
# - a model present but without a "variants" key passes the variant through
#   with a warning, since compatibility is unknown rather than unsupported;
# - a model with an empty "variants" object rejects every nonempty variant;
# - a model with a nonempty "variants" object accepts only its keys.
# Nothing is substituted or normalized. Depends on opencode_jsonc_to_json, so
# opencode-action-lib.sh must be sourced before this is called.
#
# $1: model input, in provider/model format
# $2: variant input
# $3: path to the bundled .opencode/opencode.jsonc
opencode_validate_variant() {
  local model="${1:-}" variant="${2:-}" bundled_config_file="${3:-}"
  local provider model_id candidate override_reason bundled_json result jq_rc
  local -a supported=()

  [[ -n "${variant}" ]] || return 0

  provider="${model%%/*}"
  model_id="${model#*/}"

  override_reason="$(_opencode_variant_override_reason "${provider}" "${model_id}")" || true
  if [[ -n "${override_reason}" ]]; then
    _opencode_report_annotation warning \
      "Model '${model}' variant compatibility was not validated (${override_reason}), so variant '${variant}' was passed through to OpenCode. If the provider rejects the request, rerun with an empty variant."
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
