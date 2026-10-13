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
  [ -f "${BATS_TEST_TMPDIR}/config/commands/pr-review.md" ]
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
