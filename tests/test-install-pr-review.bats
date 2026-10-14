#!/usr/bin/env bats
setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  install_step="${BATS_TEST_TMPDIR}/install.sh"
  run_step="${BATS_TEST_TMPDIR}/run-opencode.sh"
  version_step="${BATS_TEST_TMPDIR}/version.sh"
  awk -v name="Get OpenCode version" '
    $0 == "    - name: " name { step=1; next }
    step && /^    - name: / { exit }
    step && /^      run: \|$/ { script=1; next }
    script { sub(/^        /, ""); print }
  ' "${repo_root}/action.yml" > "${version_step}"
  [ -s "${version_step}" ]
  awk '
    $0 == "    - name: Run OpenCode" { step=1; next }
    step && /^      run: \|$/ { script=1; next }
    script && index($0, "if [[ \"${USE_BUNDLED_TOOLKIT}\" != \"true\"") { install=1 }
    install && /^          curl -fsSL https:\/\/opencode\.ai\/install/ { exit }
    install { sub(/^        /, ""); print }
  ' "${repo_root}/action.yml" > "${install_step}"
  [ -s "${install_step}" ]
  awk '
    $0 == "    - name: Run OpenCode" { step=1; next }
    step && /^      run: \|$/ { script=1; next }
    script { sub(/^        /, ""); print }
  ' "${repo_root}/action.yml" > "${run_step}"
  [ -s "${run_step}" ]
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

@test "installer uses its token without replacing caller auth" {
  mock_bin="${BATS_TEST_TMPDIR}/bin"
  token_capture="${BATS_TEST_TMPDIR}/installer-token"
  caller_capture="${BATS_TEST_TMPDIR}/caller-token"
  mkdir -p "${mock_bin}"
  cat > "${mock_bin}/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${GH_TOKEN}" > "${GH_TOKEN_CAPTURE}"
skill_dir="${HOME}/.config/opencode/skills/pr-review"
mkdir -p "${skill_dir}/references"
for file in SKILL.md references/review-lenses.md references/finding-validation.md references/github-posting.md; do
  touch "${skill_dir}/${file}"
done
EOF
  chmod +x "${mock_bin}/gh"

  # Keep variable expansion inside the child shell.
  # shellcheck disable=SC2016
  run env HOME="${install_home}" PATH="${mock_bin}:${PATH}" PR_REVIEW_REF="${pin}" \
    USE_BUNDLED_TOOLKIT=true PR_REVIEW_INSTALL_TOKEN=installer-token GH_TOKEN=caller-token \
    GH_TOKEN_CAPTURE="${token_capture}" bash -euo pipefail -c \
    'review_home="${HOME}"; source "$1"; printf "%s:%s" "${GH_TOKEN}" "${PR_REVIEW_INSTALL_TOKEN:-}" > "$2"' \
    _ "${install_step}" "${caller_capture}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${token_capture}")" = installer-token ]
  [ "$(cat "${caller_capture}")" = caller-token: ]
}

@test "review-only preserves shared installer tools and runs a fresh binary" {
  for example in 'matching|1.2.14' 'different|1.2.13'; do
    IFS='|' read -r case_name inherited_version <<< "${example}"
    case_root="${BATS_TEST_TMPDIR}/${case_name}"
    original_home="${case_root}/original-home"
    runner_temp="${case_root}/runner-temp"
    mock_bin="${case_root}/bin"
    mock_action="${case_root}/action"
    path_file="${case_root}/github-path"
    run_capture="${case_root}/run-capture"
    home_capture="${case_root}/home-capture"
    installer_path_capture="${case_root}/installer-path"
    required_tools_capture="${case_root}/required-tools"
    which_capture="${case_root}/which-capture"
    tar_capture="${case_root}/tar-capture"
    old_binary_capture="${case_root}/old-binary-used"
    installer_fixture="${case_root}/installer.sh"
    mkdir -p "${original_home}/.opencode/bin" "${runner_temp}" "${mock_bin}" "${mock_action}/scripts"
    echo 'preserve this home' > "${original_home}/sentinel"
    echo '/existing/github/path' > "${path_file}"
    cat > "${original_home}/.opencode/bin/opencode" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo used >> "${OLD_BINARY_CAPTURE}"
echo "${INHERITED_VERSION}"
EOF
    cp "${original_home}/.opencode/bin/opencode" "${mock_bin}/opencode"
    cat > "${mock_bin}/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
skill_dir="${HOME}/.config/opencode/skills/pr-review"
mkdir -p "${skill_dir}/references"
for file in SKILL.md references/review-lenses.md references/finding-validation.md references/github-posting.md; do
  touch "${skill_dir}/${file}"
done
EOF
    cat > "${mock_bin}/curl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "${INSTALLER_FIXTURE}"
EOF
    cat > "${mock_bin}/tar" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${TAR_CAPTURE}"
EOF
    for tool in bash mktemp rm tr find grep mkdir cat chmod touch; do
      ln -s "$(command -v "${tool}")" "${mock_bin}/${tool}"
    done
    cat > "${mock_action}/scripts/prepare-opencode-config.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
    cat > "${mock_action}/scripts/run-opencode.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "${HOME}"
  command -v opencode
  opencode --version
} > "${RUN_CAPTURE}"
EOF
    cat > "${installer_fixture}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
specific_version=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)
      specific_version="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ "${GITHUB_PATH}" == /dev/null ]]
echo "${HOME}" > "${HOME_CAPTURE}"
echo "${PATH}" > "${INSTALLER_PATH_CAPTURE}"
for required_tool in bash tar curl; do
  command -v "${required_tool}" >> "${REQUIRED_TOOLS_CAPTURE}"
done
tar --version > /dev/null
which opencode > "${WHICH_CAPTURE}"
if command -v opencode >/dev/null 2>&1; then
  installed_version="$(opencode --version 2>/dev/null || echo '')"
  if [[ "${installed_version}" == "${specific_version}" ]]; then
    exit 0
  fi
fi
mkdir -p "${HOME}/.opencode/bin"
cat > "${HOME}/.opencode/bin/opencode" << BINARY
#!/usr/bin/env bash
echo "${specific_version}"
BINARY
chmod +x "${HOME}/.opencode/bin/opencode"
EOF
    chmod +x "${original_home}/.opencode/bin/opencode" "${mock_bin}/opencode" "${mock_bin}/gh" \
      "${mock_bin}/curl" "${mock_bin}/tar" \
      "${mock_action}/scripts/prepare-opencode-config.sh" "${mock_action}/scripts/run-opencode.sh"

    run env HOME="${original_home}" RUNNER_TEMP="${runner_temp}" REVIEW_ONLY=true \
      USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF="${pin}" PR_REVIEW_INSTALL_TOKEN="" \
      OPENCODE_VERSION=1.2.14 ACTION_PATH="${mock_action}" GITHUB_PATH="${path_file}" \
      PATH="${original_home}/.opencode/bin:${mock_bin}" INSTALLER_FIXTURE="${installer_fixture}" \
      HOME_CAPTURE="${home_capture}" INSTALLER_PATH_CAPTURE="${installer_path_capture}" \
      REQUIRED_TOOLS_CAPTURE="${required_tools_capture}" WHICH_CAPTURE="${which_capture}" \
      TAR_CAPTURE="${tar_capture}" \
      OLD_BINARY_CAPTURE="${old_binary_capture}" INHERITED_VERSION="${inherited_version}" \
      RUN_CAPTURE="${run_capture}" bash "${run_step}"
    [ "${status}" -eq 0 ]
    [ ! -e "${old_binary_capture}" ]
    review_home="$(cat "${home_capture}")"
    [ "$(cat "${installer_path_capture}")" = "${review_home}/.installer-bin:${original_home}/.opencode/bin:${mock_bin}" ]
    [ "$(cat "${required_tools_capture}")" = "${mock_bin}/bash
${mock_bin}/tar
${mock_bin}/curl" ]
    [ "$(cat "${which_capture}")" = "${review_home}/.installer-bin/opencode" ]
    [ "$(cat "${tar_capture}")" = '--version' ]
    [ "$(cat "${path_file}")" = '/existing/github/path' ]
    [ "$(sed -n '3p' "${run_capture}")" = '1.2.14' ]
    [ "$(sed -n '1p' "${run_capture}")" = "${review_home}" ]
    [ "$(sed -n '2p' "${run_capture}")" = "${review_home}/.opencode/bin/opencode" ]
    [ ! -e "${review_home}" ]
    [ -f "${original_home}/.opencode/bin/opencode" ]
    [ "$(cat "${original_home}/sentinel")" = 'preserve this home' ]
  done
}

@test "review-only fails if the installer does not create a binary in its fresh home" {
  case_root="${BATS_TEST_TMPDIR}/missing-binary"
  original_home="${case_root}/original-home"
  runner_temp="${case_root}/runner-temp"
  mock_bin="${case_root}/bin"
  mock_action="${case_root}/action"
  path_file="${case_root}/github-path"
  home_capture="${case_root}/home-capture"
  run_capture="${case_root}/run-capture"
  mkdir -p "${original_home}" "${runner_temp}" "${mock_bin}" "${mock_action}/scripts"
  echo '/existing/github/path' > "${path_file}"
  cat > "${mock_bin}/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
skill_dir="${HOME}/.config/opencode/skills/pr-review"
mkdir -p "${skill_dir}/references"
for file in SKILL.md references/review-lenses.md references/finding-validation.md references/github-posting.md; do
  touch "${skill_dir}/${file}"
done
EOF
  cat > "${mock_bin}/curl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "${INSTALLER_FIXTURE}"
EOF
  cat > "${case_root}/installer.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_PATH}" == /dev/null ]]
echo "${HOME}" > "${HOME_CAPTURE}"
EOF
  cat > "${mock_action}/scripts/prepare-opencode-config.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
  cat > "${mock_action}/scripts/run-opencode.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo started > "${RUN_CAPTURE}"
EOF
  chmod +x "${mock_bin}/gh" "${mock_bin}/curl" "${case_root}/installer.sh" \
    "${mock_action}/scripts/prepare-opencode-config.sh" "${mock_action}/scripts/run-opencode.sh"

  run env HOME="${original_home}" RUNNER_TEMP="${runner_temp}" REVIEW_ONLY=true \
    USE_BUNDLED_TOOLKIT=true PR_REVIEW_REF="${pin}" PR_REVIEW_INSTALL_TOKEN="" \
    OPENCODE_VERSION=1.2.14 ACTION_PATH="${mock_action}" GITHUB_PATH="${path_file}" \
    PATH="${mock_bin}:${PATH}" INSTALLER_FIXTURE="${case_root}/installer.sh" \
    HOME_CAPTURE="${home_capture}" RUN_CAPTURE="${run_capture}" bash "${run_step}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"did not install a binary in the isolated HOME"* ]]
  [ ! -e "${run_capture}" ]
  [ "$(cat "${path_file}")" = '/existing/github/path' ]
  [ ! -e "$(cat "${home_capture}")" ]
}

@test "normal runs keep using the caller OpenCode binary without the review installer" {
  case_root="${BATS_TEST_TMPDIR}/normal-run"
  original_home="${case_root}/home"
  mock_bin="${case_root}/bin"
  mock_action="${case_root}/action"
  path_file="${case_root}/github-path"
  run_capture="${case_root}/run-capture"
  curl_capture="${case_root}/curl-capture"
  mkdir -p "${original_home}/.opencode/bin" "${mock_bin}" "${mock_action}/scripts"
  echo '/existing/github/path' > "${path_file}"
  cat > "${original_home}/.opencode/bin/opencode" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'opencode 1.2.14'
EOF
  cat > "${mock_bin}/curl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo invoked > "${CURL_CAPTURE}"
exit 1
EOF
  cat > "${mock_action}/scripts/run-opencode.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "${HOME}"
  command -v opencode
  opencode --version
} > "${RUN_CAPTURE}"
EOF
  chmod +x "${original_home}/.opencode/bin/opencode" "${mock_bin}/curl" "${mock_action}/scripts/run-opencode.sh"

  run env HOME="${original_home}" REVIEW_ONLY=false ACTION_PATH="${mock_action}" \
    GITHUB_PATH="${path_file}" PATH="${original_home}/.opencode/bin:${mock_bin}:${PATH}" \
    RUN_CAPTURE="${run_capture}" CURL_CAPTURE="${curl_capture}" bash "${run_step}"
  [ "${status}" -eq 0 ]
  [ ! -e "${curl_capture}" ]
  [ "$(sed -n '1p' "${run_capture}")" = "${original_home}" ]
  [ "$(sed -n '2p' "${run_capture}")" = "${original_home}/.opencode/bin/opencode" ]
  [ "$(sed -n '3p' "${run_capture}")" = 'opencode 1.2.14' ]
  [ "$(cat "${path_file}")" = '/existing/github/path' ]
}

@test "real gh skill installs only the SHA-pinned review skill" {
  if [[ "${GH_SKILL_SMOKE:-false}" != true ]]; then
    skip "real gh skill install runs in CI"
  fi
  pin="$(sed -n -E 's/^  PR_LOOP_REF: ([a-f0-9]{40}).*/\1/p' "${repo_root}/.github/workflows/opencode-review.yml")"
  [[ "${pin}" =~ ^[a-f0-9]{40}$ ]]
  run env HOME="${install_home}" PR_REVIEW_REF="${pin}" USE_BUNDLED_TOOLKIT=true \
    PR_REVIEW_INSTALL_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" bash "${install_step}"
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
