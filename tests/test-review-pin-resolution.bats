#!/usr/bin/env bats
# Exercise the actual pin-resolution step without contacting GitHub.

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
[[ "${1:-}" == api && "${2:-}" == 'repos/dceoy/opencode-action/contents/.github/pr-loop-ref?ref=main' ]] || exit 1
printf '%s\n' "${MOCK_PR_LOOP_PIN}"
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  export GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env"
}

@test "default pr-loop pin is resolved to a full immutable SHA" {
  pin="$(cat "${repo_root}/.github/pr-loop-ref")"
  run env GITHUB_REPOSITORY='external/caller' MOCK_PR_LOOP_PIN="${pin}" bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  expected="${pin%% *}"
  grep -Fx "PR_LOOP_REF=${expected}" "${GITHUB_ENV}"
}

@test "rejects invalid release pin without exporting it" {
  run env GITHUB_REPOSITORY='external/caller' MOCK_PR_LOOP_PIN='v1.0.0' bash -euo pipefail "${script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid default pr-loop release pin."* ]]
  [ ! -e "${GITHUB_ENV}" ]
}

@test "uses the checkout pin for review runs in the same repository" {
  cd "${repo_root}"
  pin="$(cat .github/pr-loop-ref)"
  run env GITHUB_REPOSITORY='dceoy/opencode-action' MOCK_PR_LOOP_PIN='invalid' bash -euo pipefail "${script}"
  [ "${status}" -eq 0 ]
  grep -Fx "PR_LOOP_REF=${pin%% *}" "${GITHUB_ENV}"
}
