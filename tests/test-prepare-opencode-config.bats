#!/usr/bin/env bats
setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  source "${repo_root}/scripts/prepare-opencode-config.sh"
  fake_home="${BATS_TEST_TMPDIR}/home"
  fake_action="${BATS_TEST_TMPDIR}/action"
  mkdir -p "${fake_home}" "${fake_action}/.opencode"
  mkdir -p "${fake_action}/.opencode/tools" "${fake_action}/.opencode/scripts"
  cp "${repo_root}/.opencode/tools/pr-review-api.js" "${fake_action}/.opencode/tools/"
  cp "${repo_root}/.opencode/scripts/pr-review-gh.sh" "${fake_action}/.opencode/scripts/"
  printf '%s\n' bundled > "${fake_action}/.opencode/opencode.jsonc"
  export HOME="${fake_home}"
}
@test "review-only prepares fresh config and clears inherited binaries" {
  mkdir -p "${HOME}/.config/opencode/tools" "${HOME}/.opencode/bin"
  printf 'untrusted\n' > "${HOME}/.config/opencode/tools/pr-review-api.js"
  touch "${HOME}/.config/opencode/old" "${HOME}/.opencode/bin/opencode"
  opencode_prepare_config "${fake_action}" true
  [ -f "${HOME}/.config/opencode/opencode.jsonc" ]
  cmp "${repo_root}/.opencode/tools/pr-review-api.js" "${HOME}/.config/opencode/tools/pr-review-api.js"
  cmp "${repo_root}/.opencode/scripts/pr-review-gh.sh" "${HOME}/.config/opencode/scripts/pr-review-gh.sh"
  [ ! -e "${HOME}/.config/opencode/old" ]
  [ ! -e "${HOME}/.opencode/bin" ]
}
@test "normal preparation preserves caller config" {
  mkdir -p "${HOME}/.config/opencode"
  touch "${HOME}/.config/opencode/keep"
  opencode_prepare_config "${fake_action}" false
  [ -f "${HOME}/.config/opencode/keep" ]
  [ -f "${HOME}/.config/opencode/opencode.jsonc" ]
}
@test "review-only refuses a symlinked home config" {
  mkdir -p "${BATS_TEST_TMPDIR}/outside"
  ln -s "${BATS_TEST_TMPDIR}/outside" "${HOME}/.config"
  run opencode_prepare_config "${fake_action}" true
  [ "${status}" -ne 0 ]
  [ -L "${HOME}/.config" ]
}
@test "review-only refuses a symlinked binary directory" {
  mkdir -p "${HOME}/.opencode" "${BATS_TEST_TMPDIR}/outside"
  ln -s "${BATS_TEST_TMPDIR}/outside" "${HOME}/.opencode/bin"
  run opencode_prepare_config "${fake_action}" true
  [ "${status}" -ne 0 ]
}
@test "missing bundle fails before deleting config" {
  mkdir -p "${HOME}/.config/opencode"
  touch "${HOME}/.config/opencode/keep"
  run opencode_prepare_config "${BATS_TEST_TMPDIR}/missing" true
  [ "${status}" -ne 0 ]
  [ -f "${HOME}/.config/opencode/keep" ]
}
