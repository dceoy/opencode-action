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
      [[ "$OPENCODE_DISABLE_EXTERNAL_SKILLS" == 1 ]]
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
  cat > "${workspace}/.opencode/commands/review-pr.md" << 'EOF'
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
      [[ "$PROMPT" == *"Load and follow the "*" skill."* ]]
      [[ "$PROMPT" == *"pr-review"* ]]
      [[ "$PROMPT" == *"security"* ]]
      [[ "$PROMPT" != *"MALICIOUS PROJECT REVIEW"* ]]
      jq -e '\''
        .default_agent == "review-pr-orchestrator" and
        .default_agent != "plan"
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}" "${repo_root}"

  [ "${status}" -eq 0 ]
}

@test "review-only runtime loads the bundled skill and excludes external skills" {
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${workspace}/.agents/skills/untrusted-review"
  cat > "${workspace}/.agents/skills/untrusted-review/SKILL.md" << 'EOF'
---
name: untrusted-review
description: untrusted project skill
---

# Untrusted review
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
      source "$2"
      opencode_prepare_config "$3" true
      opencode_configure_run
      cd "$GITHUB_WORKSPACE"
      opencode debug skill >/dev/null
      skills="$(opencode debug skill)"
      jq -e \
        --arg location "$HOME/.config/opencode/skills/pr-review/SKILL.md" \
        '\''
          any(
            .[];
            .name == "pr-review"
            and .location == $location
            and (.content | contains("# Strictly Read-Only PR Review"))
          )
          and all(.[]; .name != "untrusted-review")
        '\'' <<<"$skills"
    ' _ "${run_script}" "${repo_root}/scripts/prepare-opencode-config.sh" "${repo_root}"

  [ "${status}" -eq 0 ]
}

@test "normal run configuration falls back to the bundled toolkit's commands" {
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${workspace}" "${fake_action}/.opencode/commands"
  cat > "${fake_action}/.opencode/commands/inspect.md" << 'EOF'
---
description: bundled inspect command
agent: plan
---

Bundled inspect: $ARGUMENTS
EOF

  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/inspect security" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      [[ "$OPENCODE_RESOLVED_COMMAND_FILE" == "$2/.opencode/commands/inspect.md" ]]
      [[ "$PROMPT" == *"Bundled inspect: security"* ]]
      jq -e '\''.default_agent == "plan"'\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}" "${fake_action}"

  [ "${status}" -eq 0 ]
}

@test "OpenCode failure classification uses the terminal provider error" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'AI_APICallError: rate limit exceeded (statusCode: 429)' \
    'UnknownError: "Request timed out"' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"provider request timed out"* ]]
  [[ "${output}" != *"rate limited"* ]]

  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 124 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"timed out after 10 minutes"* ]]

  printf '%s\n' 'Error: SSE read timed out' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"provider request timed out"* ]]

  printf '%s\n' 'TimeoutError: The operation timed out' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"provider request timed out"* ]]

  printf '%s\n' 'AI_APICallError: statusCode: 429' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"rate limited"* ]]

  printf '%s\n' 'AI_APICallError: Insufficient credits (statusCode: 402)' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"billing or quota"* ]]

  printf '%s\n' 'AI_APICallError: provider unavailable' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"model provider API error"* ]]

  printf '%s\n' unrelated > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
}

@test "OpenCode failure classification surfaces a JSON parse failure alone" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' 'Failed to parse JSON' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"provider/model"* ]]
  [[ "${output}" == *"opencode 1.18.10"* ]]
  [[ "${output}" != *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification ignores ordinary JSON.parse output" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'const value = JSON.parse(raw)' \
    'Error: unrelated failure' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
}

@test "OpenCode failure classification recognizes a SyntaxError JSON signature" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'SyntaxError: Unexpected token } in JSON at position 123' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification ignores nonterminal JSON error text" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'SyntaxError: Unexpected token } in JSON at position 123' \
    'Error: unrelated failure' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
}

@test "OpenCode failure classification surfaces a JSON parse failure masked by the .rest handler crash" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' \
    "Error: Unexpected error: undefined is not an object (evaluating 'p.rest')" > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"secondary failure"* ]]
  [[ "${output}" == *".rest"* ]]
  [[ "${output}" == *"provider/model"* ]]
  [[ "${output}" == *"opencode 1.18.10"* ]]
  [[ "${output}" == *"do not assume OIDC or credentials are at fault"* ]]
  [[ "${output}" != *"caused by OIDC"* ]]
}

@test "OpenCode failure classification recognizes the ANSI-decorated four-line failure sequence" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' \
    $'\033[31mError:\033[0m \033[1mUnexpected error\033[0m' \
    '' \
    "undefined is not an object (evaluating 'p.rest')" > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification ignores trailing ANSI-only lines" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' \
    $'\033[31mError:\033[0m \033[1mUnexpected error\033[0m' \
    "undefined is not an object (evaluating 'p.rest')" \
    $'\033[0m' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification requires the .rest failure after the JSON error" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    "Error: Unexpected error: undefined is not an object (evaluating 'p.rest')" \
    'Failed to parse JSON' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"secondary failure"* ]]
}

@test "OpenCode failure classification ignores a nonterminal JSON and .rest sequence" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    "Error: Unexpected error: undefined is not an object (evaluating 'p.rest')" \
    'Error: unrelated failure' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"secondary failure"* ]]
}

@test "OpenCode failure classification still prefers evidenced provider errors over JSON parse noise" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'AI_APICallError: rate limit exceeded (statusCode: 429)' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"rate limited"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
}

@test "OpenCode failure annotations escape workflow command message data" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' unrelated > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" "$3" "$4" "$5"
  ' _ "${run_script}" "${output_file}" \
    $'10\n::notice::injected' \
    $'provider/model%\n::warning::injected' \
    $'1.18.10\r::debug::injected'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == *"provider/model%25%0A::warning::injected"* ]]
  [[ "${output}" == *"opencode 1.18.10%0D::debug::injected"* ]]

  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 124 "$2" "$3" provider/model 1.18.10
  ' _ "${run_script}" "${output_file}" $'10\n::notice::injected'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == *"after 10%0A::notice::injected minutes"* ]]
}

@test "run script preserves mocked OpenCode status and classifies its output" {
  fake_bin="${BATS_TEST_TMPDIR}/run-bin"
  invocation_file="${BATS_TEST_TMPDIR}/invocation"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'shift' \
    'exec "$@"' > "${fake_bin}/timeout"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >"${INVOCATION_FILE}"' \
    'echo "Insufficient credits"' \
    'exit 23' > "${fake_bin}/opencode"
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
  [[ "${output}" == *"billing or quota"* ]]
  [ "$(cat "${invocation_file}")" = "github run" ]
}

@test "run script expands a command and invokes mocked OpenCode successfully" {
  fake_bin="${BATS_TEST_TMPDIR}/success-bin"
  workspace="${BATS_TEST_TMPDIR}/success-workspace"
  invocation_file="${BATS_TEST_TMPDIR}/success-invocation"
  prompt_file="${BATS_TEST_TMPDIR}/success-prompt"
  config_file="${BATS_TEST_TMPDIR}/success-config"
  mkdir -p "${fake_bin}" "${workspace}/.opencode/commands"
  cat > "${workspace}/.opencode/commands/inspect.md" << 'EOF'
---
description: inspect with the plan agent
agent: plan
---

Inspect securely: $ARGUMENTS
EOF
  cat > "${fake_bin}/timeout" << 'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  cat > "${fake_bin}/opencode" << 'EOF'
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
