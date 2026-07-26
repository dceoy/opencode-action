#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  prepare_script="${repo_root}/scripts/prepare-opencode-config.sh"
  fake_action="${BATS_TEST_TMPDIR}/action"
  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_action}/.opencode/scripts" "${fake_home}"
  printf '%s\n' bundled >"${fake_action}/.opencode/bundled.txt"
  printf '%s\n' resolver >"${fake_action}/.opencode/scripts/resolve-app-token.sh"
  printf '%s\n' github >"${fake_action}/.opencode/scripts/review-pr-gh.sh"
  printf '%s\n' submit >"${fake_action}/.opencode/scripts/review-pr-submit.sh"
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
  [ "$(cat "${fake_home}/.config/opencode/scripts/resolve-app-token.sh")" = resolver ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/review-pr-gh.sh")" = github ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/review-pr-submit.sh")" = submit ]
  [ -f "${fake_home}/.opencode/bin/opencode" ]
  [ ! -e "${fake_home}/.opencode/plugins" ]
}

@test "normal config preparation preserves config and installs helpers directly" {
  mkdir -p "${fake_home}/.config/opencode"
  printf '%s\n' keep >"${fake_home}/.config/opencode/keep.txt"

  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    opencode_prepare_config "$2" false
  ' _ "${prepare_script}" "${fake_action}"

  [ "${status}" -eq 0 ]
  [ -f "${fake_home}/.config/opencode/keep.txt" ]
  [ -f "${fake_home}/.config/opencode/bundled.txt" ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/resolve-app-token.sh")" = resolver ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/review-pr-gh.sh")" = github ]
  [ "$(cat "${fake_home}/.config/opencode/scripts/review-pr-submit.sh")" = submit ]
  [ ! -e "${fake_home}/.config/opencode/scripts/opencode-action" ]
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

@test "config preparation fails closed before changes when any helper is missing" {
  local helper
  local -a required_helpers=(
    resolve-app-token.sh
    review-pr-gh.sh
    review-pr-submit.sh
  )

  for helper in "${required_helpers[@]}"; do
    rm -f "${fake_action}/.opencode/scripts/${helper}"
    rm -rf "${fake_home}/.config/opencode"
    mkdir -p "${fake_home}/.config/opencode"
    printf '%s\n' keep >"${fake_home}/.config/opencode/keep.txt"

    run env HOME="${fake_home}" bash -euo pipefail -c '
      source "$1"
      opencode_prepare_config "$2" true
    ' _ "${prepare_script}" "${fake_action}"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"${helper}"* ]]
    [ "$(cat "${fake_home}/.config/opencode/keep.txt")" = keep ]
    [ ! -e "${fake_home}/.config/opencode/bundled.txt" ]

    printf '%s\n' restored >"${fake_action}/.opencode/scripts/${helper}"
  done
}
