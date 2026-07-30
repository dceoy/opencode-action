#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  detect_script="${repo_root}/scripts/detect-review-mode.sh"
  action_library="${repo_root}/scripts/opencode-action-lib.sh"
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
  ' _ "${action_library}" "${detect_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]

  run bash -euo pipefail -c '
    source "$1"
    source "$2"
    opencode_detect_review_mode "/review-pr" "/oc" "" false 1.2.14
  ' _ "${action_library}" "${detect_script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"requires use-bundled-toolkit: true"* ]]
}

@test "detect review mode entrypoint enables review from a comment mention" {
  event_path="${BATS_TEST_TMPDIR}/event.json"
  github_output="${BATS_TEST_TMPDIR}/github-output"
  printf '%s\n' '{"comment":{"body":"/oc /review-pr security"}}' > "${event_path}"

  run env \
    GITHUB_EVENT_PATH="${event_path}" \
    GITHUB_OUTPUT="${github_output}" \
    MENTIONS="/oc" \
    USE_BUNDLED_TOOLKIT="true" \
    OPENCODE_VERSION="1.2.14" \
    "${detect_script}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${github_output}")" = "enabled=true" ]
}

@test "detect review mode entrypoint allows ordinary prompts without review validation" {
  github_output="${BATS_TEST_TMPDIR}/github-output"

  run env \
    GITHUB_OUTPUT="${github_output}" \
    PROMPT="summarize this change" \
    USE_BUNDLED_TOOLKIT="false" \
    OPENCODE_VERSION="latest" \
    "${detect_script}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${github_output}")" = "enabled=false" ]
}
