#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  library="${repo_root}/scripts/expand-command.sh"
  project_commands="${BATS_TEST_TMPDIR}/project"
  global_commands="${BATS_TEST_TMPDIR}/global"
  bundled_commands="${BATS_TEST_TMPDIR}/bundled"
  mkdir -p "${project_commands}" "${global_commands}" "${bundled_commands}"
}

write_command() {
  local dir="${1}" name="${2}" agent="${3}" body="${4}"
  cat >"${dir}/${name}.md" <<EOF_INNER
---
description: test
agent: ${agent}
---

${body}
EOF_INNER
}

@test "expands a command and lets its frontmatter agent win" {
  write_command "${project_commands}" review-pr build 'Review: $ARGUMENTS'
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "/review-pr security" "plan" "$2" "$3"
    printf "%s\n%s\n" "$OPENCODE_RESOLVED_PROMPT" "$OPENCODE_RESOLVED_AGENT"
  ' _ "${library}" "${project_commands}" "${global_commands}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Review: security"* ]]
  [[ "${output}" == *$'\nbuild' ]]
}

@test "extracts a slash command after a configured comment mention" {
  write_command "${project_commands}" review-pr build 'Review: $ARGUMENTS'
  event_path="${BATS_TEST_TMPDIR}/event.json"
  printf '%s\n' '{"comment":{"body":"Please /OC /review-pr security"}}' >"${event_path}"

  run bash -euo pipefail -c '
    source "$1"
    opencode_effective_prompt "" "/opencode,/oc" "$2"
    opencode_resolve_prompt_and_agent "$OPENCODE_EFFECTIVE_PROMPT" "plan" "$3"
    printf "%s\n%s\n" "$OPENCODE_RESOLVED_PROMPT" "$OPENCODE_RESOLVED_AGENT"
  ' _ "${library}" "${event_path}" "${project_commands}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Review: security"* ]]
  [[ "${output}" == *$'\nbuild' ]]
}

@test "comment mention matching avoids Bash 4 lowercase expansion" {
  run grep -F '${body,,}' "${library}"
  [ "${status}" -ne 0 ]
  run grep -F '${mention,,}' "${library}"
  [ "${status}" -ne 0 ]
}

@test "project command has precedence over global and bundled fallbacks" {
  write_command "${project_commands}" inspect build 'project'
  write_command "${global_commands}" inspect plan 'global'
  write_command "${bundled_commands}" inspect plan 'bundled'
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "/inspect" "build" "$2" "$3" "$4"
    printf "%s" "$OPENCODE_RESOLVED_PROMPT"
  ' _ "${library}" "${project_commands}" "${global_commands}" "${bundled_commands}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"project"* ]]
  [[ "${output}" != *"global"* ]]
}

@test "rejects unsupported command execution semantics" {
  write_command "${project_commands}" inspect general 'inspect'
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "/inspect" "build" "$2"
  ' _ "${library}" "${project_commands}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot be verified as a primary agent"* ]]

  cat >"${project_commands}/inspect.md" <<'EOF_INNER'
---
description: test
agent: build
model: provider/model
---
inspect
EOF_INNER
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "/inspect" "build" "$2"
  ' _ "${library}" "${project_commands}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"frontmatter 'model' is not supported"* ]]
}

@test "ordinary prompts preserve the prompt and use the agent input" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "explain this" "plan" "$2"
    printf "%s\n%s\n" "$OPENCODE_RESOLVED_PROMPT" "$OPENCODE_RESOLVED_AGENT"
  ' _ "${library}" "${project_commands}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == $'explain this\nplan' ]]
}

@test "unknown commands pass through unchanged" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "/missing x" "build" "$2"
    printf "%s\n%s\n" "$OPENCODE_RESOLVED_PROMPT" "$OPENCODE_RESOLVED_AGENT"
  ' _ "${library}" "${project_commands}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == $'/missing x\nbuild' ]]
}

@test "argument substitution is literal for ampersands and backslashes" {
  write_command "${project_commands}" inspect build 'Args: $ARGUMENTS'
  run bash -euo pipefail -c '
    source "$1"
    opencode_resolve_prompt_and_agent "/inspect a&b\\c" "build" "$2"
    printf "%s" "$OPENCODE_RESOLVED_PROMPT"
  ' _ "${library}" "${project_commands}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *'Args: a&b\c'* ]]
}

@test "JSONC conversion preserves comment-like string content" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_jsonc_to_json <<EOF_INNER | jq -e ".url == \"https://example.test/a//b\" and .enabled"
    {
      // comment
      "url": "https://example.test/a//b",
      "enabled": true,
    }
EOF_INNER
  ' _ "${library}"

  [ "${status}" -eq 0 ]
}
