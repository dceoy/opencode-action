#!/usr/bin/env bats
# Exercise the actual pin-resolution step with a mocked GitHub API.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  script="${BATS_TEST_TMPDIR}/resolve-pin.sh"
  awk '
    $0 == "      - name: Resolve default pr-loop pin" { step=1; next }
    step && /^      - name: / { exit }
    step && /^        run: \|$/ { script=1; next }
    script { sub(/^          /, ""); print }
  ' "${repo_root}/.github/workflows/opencode-review.yml" > "${script}"
  [ -s "${script}" ]
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == api && "${2:-}" == "repos/dceoy/opencode-action/contents/action.yml?ref=${EXPECTED_REF}" ]] && {
  printf '%s\n' "${MOCK_ACTION_METADATA}"
  exit 0
}
[[ "${1:-}" == api && "${2:-}" == "repos/dceoy/opencode-action/contents/.github/workflows/opencode-review.yml?ref=${EXPECTED_REF}" ]] && {
  printf '%s\n' "${MOCK_LEGACY_WORKFLOW:-}"
  exit 0
}
exit 1
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env"
  export WORKFLOW_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  export PR_BASE_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  export EXPECTED_REF="${WORKFLOW_SHA}"
  export EVENT_NAME='workflow_call'
  export GITHUB_REPOSITORY='external/caller'
  MOCK_ACTION_METADATA="$(cat "${repo_root}/action.yml")"
  export MOCK_ACTION_METADATA
  expected_pin="$(sed -n -E '/^  pr-review-ref:$/,/^  timeout-minutes:$/s/^    default: ([0-9a-f]{40}).*$/\1/p' <<< "${MOCK_ACTION_METADATA}")"
  export expected_pin
}

@test "reusable workflow always reads the pin at its own immutable SHA" {
  run bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${expected_pin}" "${GITHUB_ENV}"
}

@test "self-repository pull request reads its trusted base instead of the PR checkout" {
  run env GITHUB_REPOSITORY=dceoy/opencode-action EVENT_NAME=pull_request \
    EXPECTED_REF="${PR_BASE_SHA}" bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${expected_pin}" "${GITHUB_ENV}"
}

@test "legacy base pin is accepted only during self-repository migration" {
  legacy="env:
  PR_LOOP_REF: ${expected_pin}  # v1.0.0"
  old_action="inputs:
  pr-review-ref:
    default: ''"
  run env GITHUB_REPOSITORY=dceoy/opencode-action EVENT_NAME=pull_request \
    EXPECTED_REF="${PR_BASE_SHA}" MOCK_ACTION_METADATA="${old_action}" MOCK_LEGACY_WORKFLOW="${legacy}" \
    bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${expected_pin}" "${GITHUB_ENV}"
}

@test "a missing pin fails closed in calls from external repositories" {
  run env MOCK_ACTION_METADATA="inputs:
  pr-review-ref:
    default: ''" bash -euo pipefail "${script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid default pr-loop release pin."* ]]
  [ ! -e "${GITHUB_ENV}" ]
}

@test "invalid pin content is rejected without exporting it" {
  run env MOCK_ACTION_METADATA="  pr-review-ref:
    default: v1.0.0
  timeout-minutes:" bash -euo pipefail "${script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid default pr-loop release pin."* ]]
  [ ! -e "${GITHUB_ENV}" ]
}

@test "invalid workflow identity fails before fetching pin" {
  run env WORKFLOW_SHA=refs/heads/main bash -euo pipefail "${script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid reusable workflow/base commit SHA."* ]]
  [ ! -e "${GITHUB_ENV}" ]
}
