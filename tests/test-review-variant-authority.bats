#!/usr/bin/env bats

@test "isolated review passes variants through when persisted auth survives isolation" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_home}/.local/share/opencode"
  printf '{}\n' > "${fake_home}/.local/share/opencode/auth.json"

  run env \
    HOME="${fake_home}" \
    USE_BUNDLED_TOOLKIT=true \
    REVIEW_ONLY=true \
    GITHUB_ACTIONS=true \
    RUNNER_ENVIRONMENT=github-hosted \
    RUNNER_OS=Linux \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ \
    "${repo_root}/scripts/run-opencode.sh" \
    "${repo_root}/scripts/opencode-action-lib.sh" \
    "${repo_root}/.opencode/opencode.jsonc"

  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"persisted OpenCode authentication"* ]]
  [[ "${output}" == *"passed through to OpenCode"* ]]
}
