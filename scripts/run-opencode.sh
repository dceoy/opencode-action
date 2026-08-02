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
# .opencode/opencode.jsonc at $3 could determine the final provider/model
# config, so that file can no longer be trusted as the single source of truth
# for $1/$2. False (prints nothing, returns 1) when the bundled registry is
# authoritative. Review-only runs always discard caller/project config before
# invoking OpenCode (see opencode_configure_run), so the bundled registry
# stays authoritative there against every check below except the managed
# config directory, MDM-managed preferences, and persisted auth state, which
# OpenCode loads with higher precedence than anything review-only isolation
# clears. Checks project config OpenCode itself would load with higher
# precedence than the bundled registry: repository-root opencode.json(c),
# then .opencode/opencode.json(c) (OpenCode 1.2.14+). Also checks for any
# plugin that could mutate provider/model metadata via its config hook before
# OpenCode builds the effective registry: a nonempty "plugin" array in any
# checked config, or a populated project/global .opencode/plugins directory
# that OpenCode auto-loads regardless of config. Also checks that the bundled
# registry actually reaches OpenCode's global config: prepare-opencode-config.sh
# (opencode_prepare_config) installs it into "${HOME}/.config/opencode" only,
# and only when nothing already sits at that destination, so a caller-set
# XDG_CONFIG_HOME or a pre-existing config on a reused runner can both leave a
# different file authoritative. Also checks OpenCode's managed config
# directory (managedConfigDir(): "/etc/opencode" on Linux, "/Library/Application
# Support/opencode" on macOS, "%ProgramData%/opencode" on Windows; overridable
# for testing via OPENCODE_TEST_MANAGED_CONFIG_DIR) and, on macOS, the
# "ai.opencode.managed" MDM preference domain OpenCode applies after those
# files -- both outside $HOME, so nothing in this action clears or replaces
# them. Also checks for a persisted OpenCode auth state under XDG_DATA_HOME,
# since an authenticated account is the precondition for the remote or
# active-organization configuration OpenCode can merge after
# OPENCODE_CONFIG_CONTENT, which this action cannot reach or inspect.
_opencode_variant_override_reason() {
  local provider="${1}" model_id="${2}" bundled_config_file="${3}"
  local relative project_file project_content
  local default_global_config_dir global_config_dir global_file name
  local managed_config_dir managed_name managed_file managed_content
  local data_dir

  if [[ "${USE_BUNDLED_TOOLKIT:-false}" != "true" ]]; then
    printf "use-bundled-toolkit is false, so the bundled model registry is not installed"
    return 0
  fi

  # OpenCode loads this directory last, with the highest precedence of any
  # config source -- above even OPENCODE_CONFIG_CONTENT -- and it is not
  # scoped under $HOME, so review-only isolation (opencode_configure_run)
  # cannot clear it. Check it before the review-only early return below.
  managed_config_dir="$(_opencode_managed_config_dir)"
  for managed_name in opencode.json opencode.jsonc; do
    managed_file="${managed_config_dir}/${managed_name}"
    if [[ -f "${managed_file}" ]]; then
      managed_content="$(cat "${managed_file}")"
      if _opencode_config_defines_model "${managed_content}" "${provider}" "${model_id}"; then
        printf "the managed OpenCode configuration at '%s' redefines '%s/%s', and OpenCode loads managed config with the highest precedence of any source" \
          "${managed_file}" "${provider}" "${model_id}"
        return 0
      fi
      if _opencode_config_declares_plugin "${managed_content}"; then
        printf "the managed OpenCode configuration at '%s' declares a plugin, which can mutate provider/model metadata before OpenCode validates it" \
          "${managed_file}"
        return 0
      fi
    fi
  done

  if _opencode_mdm_preference_present; then
    printf "the host applies macOS MDM-managed OpenCode preferences ('ai.opencode.managed'), which OpenCode loads after managed config files with higher precedence than any source this action controls"
    return 0
  fi

  # A persisted auth.json is the precondition for OpenCode merging remote or
  # active-organization configuration; its contents are account/server-side
  # state this action cannot reach, so presence alone is the signal. Outside
  # $HOME/.config and $HOME/.opencode, review-only isolation does not clear
  # it either.
  data_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
  if [[ -f "${data_dir}/auth.json" ]]; then
    printf "a persisted OpenCode auth state exists at '%s', and an authenticated account can merge remote or active-organization configuration that OpenCode loads after OPENCODE_CONFIG_CONTENT" \
      "${data_dir}/auth.json"
    return 0
  fi

  [[ "${REVIEW_ONLY:-false}" != "true" ]] || return 1

  if [[ -n "${OPENCODE_CONFIG:-}" || -n "${OPENCODE_CONFIG_DIR:-}" ]]; then
    printf "the workflow sets OPENCODE_CONFIG or OPENCODE_CONFIG_DIR, which can redefine any provider"
    return 0
  fi

  if [[ -n "${OPENCODE_CONFIG_CONTENT:-}" ]]; then
    if _opencode_config_defines_model "${OPENCODE_CONFIG_CONTENT}" "${provider}" "${model_id}"; then
      printf "OPENCODE_CONFIG_CONTENT redefines '%s/%s'" "${provider}" "${model_id}"
      return 0
    fi
    if _opencode_config_declares_plugin "${OPENCODE_CONFIG_CONTENT}"; then
      printf "OPENCODE_CONFIG_CONTENT declares a plugin, which can mutate provider/model metadata before OpenCode validates it"
      return 0
    fi
  fi

  # OpenCode 1.2.14+ loads a project's own opencode.json(c) at the repository
  # root, then .opencode/opencode.json(c) after it, so either can redefine
  # the same provider/model the bundled registry declares, or declare a
  # plugin that mutates provider/model metadata before validation.
  for relative in opencode.json opencode.jsonc .opencode/opencode.jsonc .opencode/opencode.json; do
    project_file="${GITHUB_WORKSPACE:-${PWD}}/${relative}"
    if [[ -f "${project_file}" ]]; then
      project_content="$(cat "${project_file}")"
      if _opencode_config_defines_model "${project_content}" "${provider}" "${model_id}"; then
        printf "the repository's %s redefines '%s/%s'" "${relative}" "${provider}" "${model_id}"
        return 0
      fi
      if _opencode_config_declares_plugin "${project_content}"; then
        printf "the repository's %s declares a plugin, which can mutate provider/model metadata before OpenCode validates it" \
          "${relative}"
        return 0
      fi
    fi
  done

  # OpenCode auto-loads plugins from this directory regardless of config.
  if _opencode_dir_has_entries "${GITHUB_WORKSPACE:-${PWD}}/.opencode/plugins"; then
    printf "the repository's .opencode/plugins directory is not empty, and OpenCode auto-loads plugins from it, which can mutate provider/model metadata before validation"
    return 0
  fi

  default_global_config_dir="${HOME}/.config"
  global_config_dir="${XDG_CONFIG_HOME:-${default_global_config_dir}}/opencode"
  if [[ "${global_config_dir}" != "${default_global_config_dir}/opencode" ]]; then
    printf "the workflow sets XDG_CONFIG_HOME to '%s', which OpenCode reads global config from instead of the directory the action installs the bundled registry into" \
      "${XDG_CONFIG_HOME}"
    return 0
  fi

  # _opencode_copy_missing_config leaves a pre-existing
  # "${global_config_dir}/opencode.json(c)" in place instead of overwriting
  # it, so on a reused runner that file -- not $3 -- is what OpenCode loads.
  for name in opencode.json opencode.jsonc; do
    global_file="${global_config_dir}/${name}"
    if [[ -f "${global_file}" ]] && ! cmp -s "${global_file}" "${bundled_config_file}" 2> /dev/null; then
      printf "the installed OpenCode config at '%s' is not the bundled registry, so a pre-existing config may be authoritative" \
        "${global_file}"
      return 0
    fi
  done

  # A pre-existing global plugins directory survives _opencode_copy_missing_config
  # the same way a pre-existing opencode.json(c) does.
  if _opencode_dir_has_entries "${global_config_dir}/plugins"; then
    printf "'%s/plugins' is not empty, and OpenCode auto-loads plugins from it, which can mutate provider/model metadata before validation" \
      "${global_config_dir}"
    return 0
  fi

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

_opencode_config_declares_plugin() {
  local content="${1}" json rc
  json="$(opencode_jsonc_to_json <<< "${content}" 2> /dev/null)" || return 1
  set +e
  jq -e '(.plugin // []) | length > 0' <<< "${json}" > /dev/null 2>&1
  rc=$?
  set -e
  return "${rc}"
}

_opencode_dir_has_entries() {
  local dir="${1}"
  local -a entries
  [[ -d "${dir}" ]] || return 1
  entries=("${dir}"/*)
  [[ -e "${entries[0]}" ]]
}

# Resolves the same directory OpenCode's managedConfigDir() does, so
# admin-controlled config is found regardless of the runner's OS. Override
# for testing via OPENCODE_TEST_MANAGED_CONFIG_DIR.
_opencode_managed_config_dir() {
  if [[ -n "${OPENCODE_TEST_MANAGED_CONFIG_DIR:-}" ]]; then
    printf '%s' "${OPENCODE_TEST_MANAGED_CONFIG_DIR}"
    return 0
  fi
  case "$(uname -s 2> /dev/null)" in
    Darwin)
      printf '%s' "/Library/Application Support/opencode"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      printf '%s' "${ProgramData:-C:/ProgramData}/opencode"
      ;;
    *)
      printf '%s' "/etc/opencode"
      ;;
  esac
}

# True when the host applies macOS's "ai.opencode.managed" MDM preference
# domain, which OpenCode loads after managedConfigDir()'s files. Its content
# is enterprise device-management state this action cannot parse, so
# presence alone is the signal. Override for testing via
# OPENCODE_TEST_MDM_PREFERENCE_PRESENT.
_opencode_mdm_preference_present() {
  if [[ -n "${OPENCODE_TEST_MDM_PREFERENCE_PRESENT:-}" ]]; then
    [[ "${OPENCODE_TEST_MDM_PREFERENCE_PRESENT}" == "true" ]]
    return
  fi
  [[ "$(uname -s 2> /dev/null)" == "Darwin" ]] || return 1
  command -v defaults > /dev/null 2>&1 || return 1
  [[ -n "$(defaults read ai.opencode.managed 2> /dev/null)" ]]
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

  override_reason="$(_opencode_variant_override_reason "${provider}" "${model_id}" "${bundled_config_file}")" || true
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
