#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  detect_script="${repo_root}/scripts/detect-review-mode.sh"
  expand_script="${repo_root}/scripts/expand-command.sh"
  prepare_script="${repo_root}/scripts/prepare-opencode-config.sh"
  run_script="${repo_root}/scripts/run-opencode.sh"
  fake_action="${BATS_TEST_TMPDIR}/action"
  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_action}/.opencode/scripts" "${fake_home}"
  printf '%s\n' bundled >"${fake_action}/.opencode/bundled.txt"
  printf '%s\n' resolver >"${fake_action}/.opencode/scripts/resolve-app-token.sh"
  printf '%s\n' submit >"${fake_action}/.opencode/scripts/review-pr-submit.sh"
}

@test "review-only version validation accepts the minimum and later releases" {
  for version in 1.2.14 v1.2.14 1.2.15 2.0.0 1.2.15-rc.1; do
    run bash -euo pipefail -c '
      source "$1"
      opencode_validate_review_version "$2"
    ' _ "${detect_script}" "${version}"
    [ "${status}" -eq 0 ]
  done
}

@test "review-only version validation rejects older malformed and minimum prerelease versions" {
  for version in 1.2.13 1.1.99 0.9.0 latest 1.2 1.2.x 1.2.14-rc.1; do
    run bash -euo pipefail -c '
      source "$1"
      opencode_validate_review_version "$2"
    ' _ "${detect_script}" "${version}"
    [ "${status}" -ne 0 ]
  done
}

@test "review-only detection uses the effective prompt and requires the toolkit" {
  run bash -euo pipefail -c '
    source "$1"
    source "$2"
    opencode_detect_review_mode "/review-pr security" "/oc" "" true 1.2.14
    printf "%s" "$OPENCODE_REVIEW_ONLY"
  ' _ "${expand_script}" "${detect_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]

  run bash -euo pipefail -c '
    source "$1"
    source "$2"
    opencode_detect_review_mode "/review-pr" "/oc" "" false 1.2.14
  ' _ "${expand_script}" "${detect_script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires use-bundled-toolkit: true"* ]]
}

@test "review-only config preparation replaces config and cleans inherited state" {
  mkdir -p "${fake_home}/.config/opencode" \
    "${fake_home}/.opencode/bin" "${fake_home}/.opencode/plugins"
  printf '%s\n' old >"${fake_home}/.config/opencode/old.txt"
  printf '%s\n' binary >"${fake_home}/.opencode/bin/opencode"
  printf '%s\n' plugin >"${fake_home}/.opencode/plugins/inherited"

  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    opencode_prepare_config "$2" true
  ' _ "${prepare_script}" "${fake_action}"

  [ "${status}" -eq 0 ]
  [ -f "${fake_home}/.config/opencode/bundled.txt" ]
  [ ! -e "${fake_home}/.config/opencode/old.txt" ]
  [ -f "${fake_home}/.opencode/bin/opencode" ]
  [ ! -e "${fake_home}/.opencode/plugins" ]
}

@test "normal config preparation preserves config and refreshes action helpers" {
  mkdir -p "${fake_home}/.config/opencode/scripts/opencode-action"
  printf '%s\n' keep >"${fake_home}/.config/opencode/keep.txt"
  printf '%s\n' stale >"${fake_home}/.config/opencode/scripts/opencode-action/stale"

  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    opencode_prepare_config "$2" false
  ' _ "${prepare_script}" "${fake_action}"

  [ "${status}" -eq 0 ]
  [ -f "${fake_home}/.config/opencode/keep.txt" ]
  [ -f "${fake_home}/.config/opencode/bundled.txt" ]
  [ ! -e "${fake_home}/.config/opencode/scripts/opencode-action/stale" ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/opencode-action/resolve-app-token.sh")" = resolver ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/opencode-action/review-pr-submit.sh")" = submit ]
}

@test "review-only config preparation fails closed before cleanup when bundle is missing" {
  mkdir -p "${fake_home}/.config/opencode"
  printf '%s\n' keep >"${fake_home}/.config/opencode/keep.txt"

  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    opencode_prepare_config "$2" true
  ' _ "${prepare_script}" "${BATS_TEST_TMPDIR}/missing"

  [ "${status}" -ne 0 ]
  [ -f "${fake_home}/.config/opencode/keep.txt" ]
}

@test "timeout selection prefers timeout then gtimeout and supports no timeout" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  touch "${fake_bin}/timeout" "${fake_bin}/gtimeout"
  chmod +x "${fake_bin}/timeout" "${fake_bin}/gtimeout"

  run env PATH="${fake_bin}" /bin/bash -euo pipefail -c '
    source "$1"
    opencode_select_timeout_command 7
    printf "%s" "${OPENCODE_TIMEOUT_COMMAND[*]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "timeout 7m" ]

  rm "${fake_bin}/timeout"
  run env PATH="${fake_bin}" /bin/bash -euo pipefail -c '
    source "$1"
    opencode_select_timeout_command 8
    printf "%s" "${OPENCODE_TIMEOUT_COMMAND[*]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "gtimeout 8m" ]

  rm "${fake_bin}/gtimeout"
  run env PATH="${fake_bin}" /bin/bash -euo pipefail -c '
    source "$1"
    opencode_select_timeout_command 9
    printf "size=%s" "${#OPENCODE_TIMEOUT_COMMAND[@]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No timeout command found"* ]]
  [[ "${output}" == *"size=0"* ]]
}

@test "run configuration merges default_agent into existing JSONC" {
  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace" \
    PROMPT="explicit prompt" \
    AGENT="plan" \
    MENTIONS="/oc" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="true" \
    OPENCODE_CONFIG_CONTENT='{/* comment */"nested":{"items":[1,2,],},}' \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      jq -e '\''
        .default_agent == "plan" and
        .nested.items == [1, 2]
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}"

  [ "${status}" -eq 0 ]
}

@test "review-only run configuration discards inherited config overrides" {
  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    PROMPT="/review-pr" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="true" \
    USE_BUNDLED_TOOLKIT="true" \
    OPENCODE_CONFIG="untrusted.json" \
    OPENCODE_CONFIG_DIR="untrusted.d" \
    OPENCODE_CONFIG_CONTENT='{"plugin":["untrusted"]}' \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      [[ -z "${OPENCODE_CONFIG+x}" ]]
      [[ -z "${OPENCODE_CONFIG_DIR+x}" ]]
      [[ "$OPENCODE_DISABLE_PROJECT_CONFIG" == 1 ]]
      [[ "$XDG_CONFIG_HOME" == "$HOME/.config" ]]
      jq -e '\''
        .default_agent == "build" and
        (has("plugin") | not)
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}"

  [ "${status}" -eq 0 ]
}

@test "OpenCode failure classification distinguishes timeout provider and generic errors" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' 'AI_APICallError: statusCode: 402' >"${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"model provider API error"* ]]

  printf '%s\n' unrelated >"${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 124 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"timed out after 10 minutes"* ]]

  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
}

@test "run script preserves mocked OpenCode status and classifies its output" {
  fake_bin="${BATS_TEST_TMPDIR}/run-bin"
  invocation_file="${BATS_TEST_TMPDIR}/invocation"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'shift' \
    'exec "$@"' >"${fake_bin}/timeout"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >"${INVOCATION_FILE}"' \
    'echo "Insufficient credits"' \
    'exit 23' >"${fake_bin}/opencode"
  chmod +x "${fake_bin}/timeout" "${fake_bin}/opencode"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace" \
    PROMPT="explicit prompt" \
    AGENT="build" \
    MENTIONS="/oc" \
    MODEL="provider/model" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="false" \
    TIMEOUT_MINUTES="5" \
    INVOCATION_FILE="${invocation_file}" \
    "${run_script}"

  if [[ "${status}" -ne 23 ]]; then
    printf 'unexpected status %s: %s\n' "${status}" "${output}" >&2
  fi
  [ "${status}" -eq 23 ]
  [[ "${output}" == *"model provider API error"* ]]
  [ "$(cat "${invocation_file}")" = "github run" ]
}
