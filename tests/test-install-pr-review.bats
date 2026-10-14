#!/usr/bin/env bats
setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  install_step="${BATS_TEST_TMPDIR}/install.sh"
  version_step="${BATS_TEST_TMPDIR}/version.sh"
  for item in "Install pr-loop pr-review skill:${install_step}" "Get OpenCode version:${version_step}"; do
    name="${item%%:*}"
    file="${item#*:}"
    awk -v name="${name}" '
      $0 == "    - name: " name { step=1; next }
      step && /^    - name: / { exit }
      step && /^      run: \|$/ { script=1; next }
      script { sub(/^        /, ""); print }
    ' "${repo_root}/action.yml" > "${file}"
    [ -s "${file}" ]
  done
  install_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${install_home}"
  pin=ddd538f6e9347b13cf6aaebfbda86ba704ee8415
}

@test "rejects invalid OpenCode review-only versions" {
  for version in 0.9.0 1.2.13 1.2.14-beta.1 invalid; do
    run env INPUT_VERSION="${version}" REVIEW_ONLY=true GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output" bash "${version_step}"
    [ "${status}" -ne 0 ]
  done
  for version in 1.2.14 v1.2.14 1.2.14+build.1 1.3.0 2.0.0; do
    run env INPUT_VERSION="${version}" REVIEW_ONLY=true GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output" bash "${version_step}"
    [ "${status}" -eq 0 ]
  done
}

@test "rejects mutable refs and disabled bundled toolkit" {
  run env HOME="${install_home}" PR_REVIEW_REF=main USE_BUNDLED_TOOLKIT=true bash "${install_step}"
  [ "${status}" -ne 0 ]
  run env HOME="${install_home}" PR_REVIEW_REF="${pin}" USE_BUNDLED_TOOLKIT=false bash "${install_step}"
  [ "${status}" -ne 0 ]
  [ ! -e "${install_home}/.config/opencode/skills/pr-review" ]
}

@test "rejects unsafe existing destinations before invoking gh" {
  mkdir -p "${install_home}/.config/opencode/skills/pr-review"
  run env HOME="${install_home}" PR_REVIEW_REF="${pin}" USE_BUNDLED_TOOLKIT=true bash "${install_step}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unsafe or existing"* ]]
}

@test "real gh skill installs only the SHA-pinned review skill" {
  if [[ "${GH_SKILL_SMOKE:-false}" != true ]]; then
    skip "real gh skill install runs in CI"
  fi
  pin="$(sed -n -E 's/^  PR_LOOP_REF: ([a-f0-9]{40}).*/\1/p' "${repo_root}/.github/workflows/opencode-review.yml")"
  [[ "${pin}" =~ ^[a-f0-9]{40}$ ]]
  run env HOME="${install_home}" PR_REVIEW_REF="${pin}" USE_BUNDLED_TOOLKIT=true bash "${install_step}"
  if [ "${status}" -ne 0 ]; then
    echo "${output}" >&3
    false
  fi
  skill="${install_home}/.config/opencode/skills/pr-review"
  for file in SKILL.md references/review-lenses.md references/finding-validation.md references/github-posting.md; do
    [ -f "${skill}/${file}" ]
  done
  grep -q '^name: pr-review$' "${skill}/SKILL.md"
  grep -q 'github-repo:' "${skill}/SKILL.md"
}
