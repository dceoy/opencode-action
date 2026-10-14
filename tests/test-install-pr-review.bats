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

@test "normalizes uppercase release pins and installs the pnpm-linked skill" {
  export OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD
  install_home="${BATS_TEST_TMPDIR}/install-home"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}" "${install_home}"
  cat > "${fake_bin}/corepack" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == pnpm && "${2:-}" == install ]] || exit 91
grep -q 'pr-loop.git#abcdefabcdefabcdefabcdefabcdefabcdefabcd' package.json
grep -q 'pr-loop@git+https://github.com/dceoy/pr-loop.git' pnpm-workspace.yaml
grep -q 'skills: true' pnpm-workspace.yaml
grep -q 'build: false' pnpm-workspace.yaml
mkdir -p node_modules/pr-loop/skills .agents/skills
cp -R "${SKILL_FIXTURE}" node_modules/pr-loop/skills/pr-review
printf '%s\n' "pr-loop: git+https://github.com/dceoy/pr-loop.git#abcdefabcdefabcdefabcdefabcdefabcdefabcd" > pnpm-lock.yaml
ln -s ../../node_modules/pr-loop/skills/pr-review .agents/skills/pnpm-pr-loop-pr-review
STUB
  chmod +x "${fake_bin}/corepack"
  run env HOME="${install_home}" PATH="${fake_bin}:${PATH}" SKILL_FIXTURE="${source_dir}" \
    bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -eq 0 ]
  [ -f "${install_home}/.config/opencode/skills/pr-review/SKILL.md" ]
  [[ "${output}" == *"Installed pr-loop/pr-review at abcdef"* ]]
}

@test "fails closed when pnpm resolves a different commit" {
  fake_bin="${BATS_TEST_TMPDIR}/mismatched-pnpm"
  install_home="${BATS_TEST_TMPDIR}/mismatched-home"
  mkdir -p "${fake_bin}" "${install_home}"
  cat > "${fake_bin}/corepack" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p node_modules/pr-loop/skills .agents/skills
cp -R "${SKILL_FIXTURE}" node_modules/pr-loop/skills/pr-review
printf '%s\n' 'pr-loop: git+https://github.com/dceoy/pr-loop.git#0000000000000000000000000000000000000000' > pnpm-lock.yaml
ln -s ../../node_modules/pr-loop/skills/pr-review .agents/skills/pnpm-pr-loop-pr-review
STUB
  chmod +x "${fake_bin}/corepack"
  run env HOME="${install_home}" PATH="${fake_bin}:${PATH}" SKILL_FIXTURE="${source_dir}" \
    OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD \
    bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not resolve pr-loop to the pinned commit"* ]]
  [ ! -e "${install_home}/.config/opencode/skills/pr-review" ]
}

@test "fails closed when pnpm returns no approved skill link" {
  fake_bin="${BATS_TEST_TMPDIR}/empty-pnpm"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "pr-loop: git+https://github.com/dceoy/pr-loop.git#abcdefabcdefabcdefabcdefabcdefabcdefabcd" > pnpm-lock.yaml' \
    'exit 0' > "${fake_bin}/corepack"
  chmod +x "${fake_bin}/corepack"
  run env HOME="${BATS_TEST_TMPDIR}/missing-home" PATH="${fake_bin}:${PATH}" \
    USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
    OPENCODE_VERSION=1.2.14 bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pnpm did not link"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/missing-home/.config/opencode/skills/pr-review" ]
}

@test "review version accepts supported semantic versions" {
  for version in 1.2.14 v1.2.14 1.2.14+build.1 1.2.15 1.3.0 2.0.0 1.3.0-beta.1; do
    run opencode_validate_review_version "${version}"
    [ "${status}" -eq 0 ]
  done
}

@test "installer rejects unsupported versions before pnpm or skill writes" {
  fake_bin="${BATS_TEST_TMPDIR}/version-bin"
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/corepack" << 'STUB'
#!/usr/bin/env bash
touch "${PNPM_CALL_LOG}"
exit 99
STUB
  chmod +x "${fake_bin}/corepack"
  for version in 0.9.0 1.1.99 1.2.13 1.2.14-beta.1 latest invalid 1.2 ''; do
    run env HOME="${BATS_TEST_TMPDIR}/version-home" PATH="${fake_bin}:${PATH}" \
      USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
      OPENCODE_VERSION="${version}" PNPM_CALL_LOG="${BATS_TEST_TMPDIR}/pnpm-calls" \
      bash "${repo_root}/scripts/install-pr-review.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Review-only mode requires"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/pnpm-calls" ]
    [ ! -e "${BATS_TEST_TMPDIR}/version-home/.config/opencode/skills/pr-review" ]
  done
}
