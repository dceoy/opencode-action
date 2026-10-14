#!/usr/bin/env bats
setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  source "${repo_root}/scripts/install-pr-review.sh"
  source_dir="${BATS_TEST_TMPDIR}/source"
  target_dir="${BATS_TEST_TMPDIR}/config/skills/pr-review"
  mkdir -p "${source_dir}/references"
  printf '%s\n' '---' 'name: pr-review' '---' > "${source_dir}/SKILL.md"
  for name in review-lenses finding-validation github-posting; do
    touch "${source_dir}/references/${name}.md"
  done
}
@test "copies upstream skill with relative references" {
  pr_review_copy_skill "${source_dir}" "${target_dir}"
  [ -f "${target_dir}/SKILL.md" ]
  [ -f "${target_dir}/references/github-posting.md" ]
  [ ! -e "${BATS_TEST_TMPDIR}/config/commands/pr-review.md" ]
  [[ "$(cat "${target_dir}/SKILL.md")" == *'opencode/slash: "true"'* ]]
}
@test "fails closed when upstream reference is missing" {
  rm "${source_dir}/references/github-posting.md"
  run pr_review_copy_skill "${source_dir}" "${target_dir}"
  [ "${status}" -ne 0 ]
  [ ! -e "${target_dir}" ]
}
@test "rejects symlinks and existing destinations" {
  ln -s /etc/passwd "${source_dir}/references/unsafe.md"
  run pr_review_copy_skill "${source_dir}" "${target_dir}"
  [ "${status}" -ne 0 ]
  rm "${source_dir}/references/unsafe.md"
  mkdir -p "${target_dir}"
  run pr_review_copy_skill "${source_dir}" "${target_dir}"
  [ "${status}" -ne 0 ]
}
@test "rejects mutable branch refs" {
  run env USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=main bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"full immutable 40-character commit SHA"* ]]
}

@test "normalizes uppercase release pins with portable shell syntax" {
  export OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD
  install_home="${BATS_TEST_TMPDIR}/install-home"
  fake_git="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_git}" "${install_home}"
  cat > "${fake_git}/git" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"rev-parse HEAD"* ]]; then
  printf 'abcdefabcdefabcdefabcdefabcdefabcdefabcd\n'
elif [[ "$*" == *"checkout -q --detach FETCH_HEAD"* ]]; then
  mkdir -p "$2/skills"
  cp -R "${SKILL_FIXTURE}" "$2/skills/pr-review"
fi
STUB
  chmod +x "${fake_git}/git"
  run env HOME="${install_home}" PATH="${fake_git}:${PATH}" SKILL_FIXTURE="${source_dir}" \
    bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -eq 0 ]
  [ -f "${install_home}/.config/opencode/skills/pr-review/SKILL.md" ]
  [[ "${output}" == *"Installed pr-loop/pr-review at abcdef"* ]]
}

@test "review version accepts supported semantic versions" {
  for version in 1.2.14 v1.2.14 1.2.14+build.1 1.2.15 1.3.0 2.0.0 1.3.0-beta.1; do
    run opencode_validate_review_version "${version}"
    [ "${status}" -eq 0 ]
  done
}

@test "installer rejects unsupported versions before Git or skill writes" {
  fake_bin="${BATS_TEST_TMPDIR}/version-bin"
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/git" << 'STUB'
#!/usr/bin/env bash
touch "${GIT_CALL_LOG}"
exit 99
STUB
  chmod +x "${fake_bin}/git"
  for version in 0.9.0 1.1.99 1.2.13 1.2.14-beta.1 latest invalid 1.2 ''; do
    run env HOME="${BATS_TEST_TMPDIR}/version-home" PATH="${fake_bin}:${PATH}" \
      USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
      OPENCODE_VERSION="${version}" GIT_CALL_LOG="${BATS_TEST_TMPDIR}/git-calls" \
      bash "${repo_root}/scripts/install-pr-review.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Review-only mode requires"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/git-calls" ]
    [ ! -e "${BATS_TEST_TMPDIR}/version-home/.config/opencode/skills/pr-review" ]
  done
}
