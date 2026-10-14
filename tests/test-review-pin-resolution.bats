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
[[ "${1:-}" == api && "${2:-}" == "repos/dceoy/opencode-action/contents/.github/pr-loop-ref?ref=${EXPECTED_REF}" ]] && {
  [[ "${MOCK_MISSING_PIN:-false}" != true ]] || exit 1
  printf '%s\n' "${MOCK_PR_LOOP_PIN}"
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
  MOCK_PR_LOOP_PIN="$(cat "${repo_root}/.github/pr-loop-ref")"
  export MOCK_PR_LOOP_PIN
}

@test "reusable workflow always reads the pin at its own immutable SHA" {
  run bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${MOCK_PR_LOOP_PIN%% *}" "${GITHUB_ENV}"
}

@test "self-repository pull request reads its trusted base instead of the PR checkout" {
  run env GITHUB_REPOSITORY=dceoy/opencode-action EVENT_NAME=pull_request \
    EXPECTED_REF="${PR_BASE_SHA}" bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${MOCK_PR_LOOP_PIN%% *}" "${GITHUB_ENV}"
}

@test "legacy base pin is accepted only during self-repository migration" {
  legacy="env:
  PR_LOOP_REF: ${MOCK_PR_LOOP_PIN}"
  run env GITHUB_REPOSITORY=dceoy/opencode-action EVENT_NAME=pull_request \
    EXPECTED_REF="${PR_BASE_SHA}" MOCK_MISSING_PIN=true MOCK_LEGACY_WORKFLOW="${legacy}" \
    bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${MOCK_PR_LOOP_PIN%% *}" "${GITHUB_ENV}"
}

@test "a missing pin fails closed in calls from external repositories" {
  run env MOCK_MISSING_PIN=true bash -euo pipefail "${script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Could not resolve default pr-loop pin."* ]]
  [ ! -e "${GITHUB_ENV}" ]
}

@test "invalid pin content is rejected without exporting it" {
  run env MOCK_PR_LOOP_PIN=v1.0.0 bash -euo pipefail "${script}"
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
