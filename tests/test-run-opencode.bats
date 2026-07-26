#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  run_script="${repo_root}/scripts/run-opencode.sh"
  fake_action="${BATS_TEST_TMPDIR}/action"
  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_action}/.opencode" "${fake_home}"
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

@test "review-only run configuration isolates bundled command resolution" {
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${workspace}/.opencode/commands"
  cat >"${workspace}/.opencode/commands/review-pr.md" <<'EOF'
---
description: untrusted project command
agent: plan
---

MALICIOUS PROJECT REVIEW: $ARGUMENTS
EOF

  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${repo_root}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/review-pr security" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="true" \
    USE_BUNDLED_TOOLKIT="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      [[ "$OPENCODE_RESOLVED_COMMAND_FILE" == "$2/.opencode/commands/review-pr.md" ]]
      [[ "$PROMPT" == *"Strictly Read-Only PR Review"* ]]
      [[ "$PROMPT" == *"security"* ]]
      [[ "$PROMPT" != *"MALICIOUS PROJECT REVIEW"* ]]
      jq -e '\''
        .default_agent == "review-pr-orchestrator" and
        .default_agent != "plan"
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}" "${repo_root}"

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

@test "run script expands a command and invokes mocked OpenCode successfully" {
  fake_bin="${BATS_TEST_TMPDIR}/success-bin"
  workspace="${BATS_TEST_TMPDIR}/success-workspace"
  invocation_file="${BATS_TEST_TMPDIR}/success-invocation"
  prompt_file="${BATS_TEST_TMPDIR}/success-prompt"
  config_file="${BATS_TEST_TMPDIR}/success-config"
  mkdir -p "${fake_bin}" "${workspace}/.opencode/commands"
  cat >"${workspace}/.opencode/commands/inspect.md" <<'EOF'
---
description: inspect with the plan agent
agent: plan
---

Inspect securely: $ARGUMENTS
EOF
  cat >"${fake_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  cat >"${fake_bin}/opencode" <<'EOF'
#!/usr/bin/env bash
printf 'opencode %s\n' "$*" >"${INVOCATION_FILE}"
printf '%s' "${PROMPT}" >"${PROMPT_FILE}"
printf '%s' "${OPENCODE_CONFIG_CONTENT}" >"${CONFIG_FILE}"
EOF
  chmod +x "${fake_bin}/timeout" "${fake_bin}/opencode"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/inspect security" \
    AGENT="build" \
    MENTIONS="/oc" \
    MODEL="provider/model" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="false" \
    TIMEOUT_MINUTES="5" \
    INVOCATION_FILE="${invocation_file}" \
    PROMPT_FILE="${prompt_file}" \
    CONFIG_FILE="${config_file}" \
    "${run_script}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${invocation_file}")" = "opencode github run" ]
  [[ "$(cat "${prompt_file}")" == *"Inspect securely: security"* ]]
  jq -e '.default_agent == "plan"' "${config_file}"
}
