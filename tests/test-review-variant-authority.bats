#!/usr/bin/env bats
# shellcheck disable=SC2016

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

@test "isolated review passes variants through when OPENCODE_DB can preserve account state" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/db-override-home"
  mkdir -p "${fake_home}"

  run env \
    HOME="${fake_home}" \
    OPENCODE_DB="${BATS_TEST_TMPDIR}/external-opencode.db" \
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
  [[ "${output}" == *"OPENCODE_DB is set"* ]]
  [[ "${output}" == *"passed through to OpenCode"* ]]
}

@test "isolated review passes variants through when persisted account database survives isolation" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/account-db-home"
  data_dir="${fake_home}/.local/share/opencode"
  mkdir -p "${data_dir}"
  : > "${data_dir}/opencode-1.18.16.db"

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
  [[ "${output}" == *"persisted OpenCode account database"* ]]
  [[ "${output}" == *"passed through to OpenCode"* ]]
}

@test "isolated review passes variants through when managed config survives isolation" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/managed-home"
  program_data="${BATS_TEST_TMPDIR}/ProgramData"
  mkdir -p "${fake_home}" "${program_data}/opencode"
  printf '{}\n' > "${program_data}/opencode/opencode.jsonc"

  run env \
    HOME="${fake_home}" \
    ProgramData="${program_data}" \
    USE_BUNDLED_TOOLKIT=true \
    REVIEW_ONLY=true \
    GITHUB_ACTIONS=true \
    RUNNER_ENVIRONMENT=github-hosted \
    RUNNER_OS=Windows \
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
  [[ "${output}" == *"managed OpenCode state exists"* ]]
  [[ "${output}" == *"passed through to OpenCode"* ]]
}

@test "isolated review passes variants through when macOS MDM preferences survive isolation" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/mdm-home"
  fake_bin="${BATS_TEST_TMPDIR}/mdm-bin"
  mkdir -p "${fake_home}" "${fake_bin}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${fake_bin}/defaults"
  chmod +x "${fake_bin}/defaults"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    USE_BUNDLED_TOOLKIT=true \
    REVIEW_ONLY=true \
    GITHUB_ACTIONS=true \
    RUNNER_ENVIRONMENT=github-hosted \
    RUNNER_OS=Darwin \
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
  [[ "${output}" == *"macOS MDM-managed OpenCode preferences"* ]]
  [[ "${output}" == *"passed through to OpenCode"* ]]
}

@test "authoritative review fails closed when bundled config is missing" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/missing-config-home"
  program_data="${BATS_TEST_TMPDIR}/missing-config-ProgramData"
  mkdir -p "${fake_home}" "${program_data}"

  run env \
    HOME="${fake_home}" \
    ProgramData="${program_data}" \
    USE_BUNDLED_TOOLKIT=true \
    REVIEW_ONLY=true \
    GITHUB_ACTIONS=true \
    RUNNER_ENVIRONMENT=github-hosted \
    RUNNER_OS=Windows \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ \
    "${repo_root}/scripts/run-opencode.sh" \
    "${repo_root}/scripts/opencode-action-lib.sh" \
    "${BATS_TEST_TMPDIR}/missing-opencode.jsonc"

  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"Bundled OpenCode configuration not found"* ]]
}

@test "authoritative review fails closed when bundled config is invalid JSONC" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  fake_home="${BATS_TEST_TMPDIR}/invalid-config-home"
  program_data="${BATS_TEST_TMPDIR}/invalid-config-ProgramData"
  fixture="${BATS_TEST_TMPDIR}/invalid-opencode.jsonc"
  mkdir -p "${fake_home}" "${program_data}"
  printf '{"provider":' > "${fixture}"

  run env \
    HOME="${fake_home}" \
    ProgramData="${program_data}" \
    USE_BUNDLED_TOOLKIT=true \
    REVIEW_ONLY=true \
    GITHUB_ACTIONS=true \
    RUNNER_ENVIRONMENT=github-hosted \
    RUNNER_OS=Windows \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ \
    "${repo_root}/scripts/run-opencode.sh" \
    "${repo_root}/scripts/opencode-action-lib.sh" \
    "${fixture}"

  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"Failed to read the bundled OpenCode model registry"* ]]
}
