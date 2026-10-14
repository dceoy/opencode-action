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
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/gh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == skill && "${2:-}" == install && "${3:-}" == --help ]]; then
  exit "${GH_HELP_EXIT:-0}"
fi
[[ "${1:-}" == skill && "${2:-}" == install ]] || exit 90
[[ "${3:-}" == dceoy/pr-loop && "${4:-}" == skills/pr-review ]] || exit 91
[[ "${5:-}" == --pin && "${6:-}" == "${PR_REVIEW_REF,,}" ]] || exit 92
[[ "${7:-}" == --agent && "${8:-}" == opencode && "${9:-}" == --scope && "${10:-}" == user ]] || exit 93
if [[ -n "${GH_CALL_LOG:-}" ]]; then
  printf 'install\n' >> "${GH_CALL_LOG}"
fi
[[ "${GH_FAIL:-false}" != true ]] || exit 94
destination="${HOME}/.config/opencode/skills/pr-review"
mkdir -p "${destination}"
cp -R "${SKILL_FIXTURE}/." "${destination}/"
if [[ "${GH_MISSING_FILE:-false}" == true ]]; then
  rm "${destination}/references/github-posting.md"
fi
if [[ "${GH_SYMLINK:-false}" == true ]]; then
  ln -s /etc/passwd "${destination}/references/unsafe.md"
fi
STUB
  chmod +x "${fake_bin}/gh"
}

# GitHub-hosted Ubuntu runners provide Ruby's standard-library YAML parser.
assert_skill_frontmatter() {
  ruby -ryaml -e '
    source = File.read(ARGV.fetch(0))
    match = source.match(/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/m)
    abort "missing YAML frontmatter" unless match
    data = YAML.safe_load(match[1])
    abort "frontmatter is not a mapping" unless data.is_a?(Hash)
    metadata = data.fetch("metadata")
    abort "missing OpenCode slash metadata" unless metadata.is_a?(Hash) && metadata["opencode/slash"] == "true"
    if ENV["EXPECT_GH_METADATA"] == "true"
      abort "gh source metadata was lost" unless metadata.keys.any? { |key| key.start_with?("github-") }
    end
  ' "$1"
}

@test "validates the installed Skill and enables native slash invocation" {
  mkdir -p "${target_dir}"
  cp -R "${source_dir}/." "${target_dir}/"
  pr_review_finalize_skill "${target_dir}"
  [ -f "${target_dir}/references/github-posting.md" ]
  assert_skill_frontmatter "${target_dir}/SKILL.md"
}

@test "preserves four-space gh source metadata and valid YAML" {
  printf '%s\n' '---' 'name: pr-review' 'metadata:' \
    '    github-repo: dceoy/pr-loop' '    github-path: skills/pr-review' '---' > "${source_dir}/SKILL.md"
  pr_review_finalize_skill "${source_dir}"
  EXPECT_GH_METADATA=true assert_skill_frontmatter "${source_dir}/SKILL.md"
  grep -q '^    opencode/slash: "true"$' "${source_dir}/SKILL.md"
  grep -q '^    github-path: skills/pr-review$' "${source_dir}/SKILL.md"
}

@test "updates existing slash metadata at the original indent" {
  printf '%s\n' '---' 'name: pr-review' 'metadata:' \
    '    github-repo: dceoy/pr-loop' '    opencode/slash: "false"' '---' > "${source_dir}/SKILL.md"
  pr_review_finalize_skill "${source_dir}"
  EXPECT_GH_METADATA=true assert_skill_frontmatter "${source_dir}/SKILL.md"
  [ "$(grep -c 'opencode/slash:' "${source_dir}/SKILL.md")" -eq 1 ]
}

@test "retains two-space upstream metadata without changing the structure" {
  printf '%s\n' '---' 'name: pr-review' 'metadata:' '  github-repo: dceoy/pr-loop' '---' > "${source_dir}/SKILL.md"
  pr_review_finalize_skill "${source_dir}"
  EXPECT_GH_METADATA=true assert_skill_frontmatter "${source_dir}/SKILL.md"
  grep -q '^  opencode/slash: "true"$' "${source_dir}/SKILL.md"
}

@test "fails closed on missing required reference and source symlinks" {
  rm "${source_dir}/references/github-posting.md"
  run pr_review_finalize_skill "${source_dir}"
  [ "${status}" -ne 0 ]
  touch "${source_dir}/references/github-posting.md"
  ln -s /etc/passwd "${source_dir}/references/unsafe.md"
  run pr_review_finalize_skill "${source_dir}"
  [ "${status}" -ne 0 ]
}

@test "rejects mutable branch refs before invoking gh" {
  run env USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=main bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"full immutable 40-character commit SHA"* ]]
}

@test "normalizes uppercase pins and invokes native gh skill installer" {
  install_home="${BATS_TEST_TMPDIR}/install-home"
  mkdir -p "${install_home}"
  run env HOME="${install_home}" PATH="${fake_bin}:${PATH}" SKILL_FIXTURE="${source_dir}" \
    OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD \
    bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -eq 0 ]
  [ -f "${install_home}/.config/opencode/skills/pr-review/SKILL.md" ]
  [[ "${output}" == *"Installed pr-loop/pr-review at abcdef"* ]]
}

@test "rejects existing or symlinked Skill destinations without invoking gh" {
  install_home="${BATS_TEST_TMPDIR}/existing-home"
  mkdir -p "${install_home}/.config/opencode/skills/pr-review"
  run env HOME="${install_home}" PATH="${fake_bin}:${PATH}" SKILL_FIXTURE="${source_dir}" \
    OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
}

@test "rejects missing gh skill capability before writing files" {
  install_home="${BATS_TEST_TMPDIR}/missing-gh-home"
  run env HOME="${install_home}" PATH="${fake_bin}:${PATH}" SKILL_FIXTURE="${source_dir}" \
    OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
    GH_HELP_EXIT=1 bash "${repo_root}/scripts/install-pr-review.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GitHub CLI v2.90.0 or newer"* ]]
  [ ! -e "${install_home}/.config/opencode/skills/pr-review" ]
}

@test "cleans up missing files, unsafe symlinks, and failed installs" {
  for failure in GH_FAIL GH_MISSING_FILE GH_SYMLINK; do
    install_home="${BATS_TEST_TMPDIR}/failure-${failure}"
    mkdir -p "${install_home}"
    run env HOME="${install_home}" PATH="${fake_bin}:${PATH}" SKILL_FIXTURE="${source_dir}" \
      OPENCODE_VERSION=1.2.14 USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
      "${failure}=true" bash "${repo_root}/scripts/install-pr-review.sh"
    [ "${status}" -ne 0 ]
    [ ! -e "${install_home}/.config/opencode/skills/pr-review" ]
  done
}

@test "review version accepts supported semantic versions" {
  for version in 1.2.14 v1.2.14 1.2.14+build.1 1.2.15 1.3.0 2.0.0 1.3.0-beta.1; do
    run opencode_validate_review_version "${version}"
    [ "${status}" -eq 0 ]
  done
}

@test "installer rejects unsupported versions before calling gh" {
  for version in 0.9.0 1.1.99 1.2.13 1.2.14-beta.1 latest invalid 1.2 ''; do
    run env HOME="${BATS_TEST_TMPDIR}/version-home" PATH="${fake_bin}:${PATH}" \
      USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
      OPENCODE_VERSION="${version}" GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" \
      bash "${repo_root}/scripts/install-pr-review.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Review-only mode requires"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "real gh skill installs the pinned Skill in CI" {
  if [[ "${GH_SKILL_SMOKE:-false}" != true ]]; then
    skip "real gh skill/network smoke test runs only in CI"
  fi
  ref="$(sed -n -E 's/^  PR_LOOP_REF: ([a-f0-9]{40}).*/\1/p' "${repo_root}/.github/workflows/opencode-review.yml")"
  [[ "${ref}" =~ ^[a-f0-9]{40}$ ]]
  install_home="${BATS_TEST_TMPDIR}/real-install-home"
  mkdir -p "${install_home}"
  run env HOME="${install_home}" USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF="${ref}" \
    OPENCODE_VERSION=1.2.14 bash "${repo_root}/scripts/install-pr-review.sh"
  if [ "${status}" -ne 0 ]; then
    echo "${output}" >&3
    false
  fi
  [ -f "${install_home}/.config/opencode/skills/pr-review/SKILL.md" ]
  [ -f "${install_home}/.config/opencode/skills/pr-review/references/github-posting.md" ]
  EXPECT_GH_METADATA=true assert_skill_frontmatter "${install_home}/.config/opencode/skills/pr-review/SKILL.md"
}
