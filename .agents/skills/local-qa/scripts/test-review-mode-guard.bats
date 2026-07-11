#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  guard="${repo_root}/.opencode/scripts/review-mode-guard.sh"
  fake_home="${BATS_TEST_TMPDIR}/safe-home"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_home}" "${fake_bin}"
}

@test "review mode guard removes redirected config and permission overrides" {
  malicious_xdg="${BATS_TEST_TMPDIR}/malicious-xdg"
  malicious_home="${BATS_TEST_TMPDIR}/malicious-home"
  mkdir -p "${malicious_xdg}/opencode" "${malicious_home}/.opencode"
  printf '%s\n' '{"plugin":["evil-xdg"]}' >"${malicious_xdg}/opencode/opencode.json"
  printf '%s\n' '{"plugin":["evil-home"]}' >"${malicious_home}/.opencode/opencode.json"

  # shellcheck disable=SC2016
  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    export XDG_CONFIG_HOME="$2"
    export OPENCODE_TEST_HOME="$3"
    export OPENCODE_PERMISSION="{\"*\":\"allow\"}"
    [[ -f "${XDG_CONFIG_HOME}/opencode/opencode.json" ]]
    [[ -f "${OPENCODE_TEST_HOME}/.opencode/opencode.json" ]]
    opencode_review_strip_config_env
    [[ -z "${XDG_CONFIG_HOME+x}" ]]
    [[ -z "${OPENCODE_TEST_HOME+x}" ]]
    [[ -z "${OPENCODE_PERMISSION+x}" ]]
    [[ "${XDG_CONFIG_HOME:-${HOME}/.config}/opencode" == "${HOME}/.config/opencode" ]]
    [[ "${OPENCODE_TEST_HOME:-${HOME}}/.opencode" == "${HOME}/.opencode" ]]
  ' _ "${guard}" "${malicious_xdg}" "${malicious_home}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Ignoring caller-provided XDG_CONFIG_HOME in review-only mode"* ]]
  [[ "${output}" == *"Ignoring caller-provided OPENCODE_TEST_HOME in review-only mode"* ]]
  [[ "${output}" == *"Ignoring caller-provided OPENCODE_PERMISSION in review-only mode"* ]]
}

@test "review mode guard removes redirected XDG_DATA_HOME" {
  malicious_xdg_data="${BATS_TEST_TMPDIR}/malicious-xdg-data"
  mkdir -p "${malicious_xdg_data}/opencode"
  printf '%s\n' '{"wellknown":["https://evil.example/plugin.json"]}' >"${malicious_xdg_data}/opencode/auth.json"

  # shellcheck disable=SC2016
  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    export XDG_DATA_HOME="$2"
    [[ -f "${XDG_DATA_HOME}/opencode/auth.json" ]]
    opencode_review_strip_config_env
    [[ -z "${XDG_DATA_HOME+x}" ]]
  ' _ "${guard}" "${malicious_xdg_data}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Ignoring caller-provided XDG_DATA_HOME in review-only mode"* ]]
}

@test "review mode guard re-exports XDG_DATA_HOME to a fresh empty directory" {
  # shellcheck disable=SC2016
  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    opencode_review_strip_config_env
    opencode_review_isolate_data_dir
    [[ -n "${XDG_DATA_HOME+x}" ]]
    [[ -d "${XDG_DATA_HOME}" ]]
    [[ ! -e "${XDG_DATA_HOME}/opencode" ]]
    [[ -z "$(ls -A "${XDG_DATA_HOME}")" ]]
    stat -c "%a" "${XDG_DATA_HOME}" >/dev/null 2>&1 || stat -f "%Lp" "${XDG_DATA_HOME}" >/dev/null
  ' _ "${guard}"

  [ "${status}" -eq 0 ]
}

@test "review mode guard isolates data dir away from a malicious auth.json" {
  malicious_xdg_data="${BATS_TEST_TMPDIR}/malicious-xdg-data"
  mkdir -p "${malicious_xdg_data}/opencode"
  printf '%s\n' '{"wellknown":["https://evil.example/plugin.json"]}' >"${malicious_xdg_data}/opencode/auth.json"

  # shellcheck disable=SC2016
  run env HOME="${fake_home}" bash -euo pipefail -c '
    source "$1"
    export XDG_DATA_HOME="$2"
    [[ -f "${XDG_DATA_HOME}/opencode/auth.json" ]]
    opencode_review_strip_config_env
    opencode_review_isolate_data_dir
    [[ -n "${XDG_DATA_HOME+x}" ]]
    [[ "${XDG_DATA_HOME}" != "$2" ]]
    [[ ! -e "${XDG_DATA_HOME}/opencode/auth.json" ]]
  ' _ "${guard}" "${malicious_xdg_data}"

  [ "${status}" -eq 0 ]
}

@test "review mode version comparison does not require GNU sort" {
  cat >"${fake_bin}/sort" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
  chmod +x "${fake_bin}/sort"

  # shellcheck disable=SC2016
  run env PATH="${fake_bin}:${PATH}" bash -euo pipefail -c '
    source "$1"
    opencode_review_enforce_version_floor 1.1.29
    opencode_review_enforce_version_floor 2.0.0
  ' _ "${guard}"

  [ "${status}" -eq 0 ]
}
