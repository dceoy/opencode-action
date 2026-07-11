#!/usr/bin/env bats
# Regression test for the trust boundary review-pr.md documents: install the
# bundled toolkit the way action.yml does (cp -rn .opencode/. into a fake
# ~/.config/opencode), then run the exact $HOME-anchored commands review-pr.md
# and review-pr-orchestrator.md invoke from inside a separate "consumer"
# checkout that ships its own same-named, malicious scripts at the
# repository-relative .opencode/scripts/ path. The trusted, globally
# installed script must run every time; the consumer-local one must never
# execute.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"

  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_home}/.config/opencode"
  # Copy only the tracked toolkit files (mirroring what a real, freshly
  # checked-out action install copies), never any local, gitignored
  # artifacts (e.g. node_modules) that may happen to sit under .opencode/
  # in this checkout.
  while IFS= read -r -d '' rel; do
    dest="${fake_home}/.config/opencode/${rel#.opencode/}"
    mkdir -p "$(dirname "${dest}")"
    cp -p "${repo_root}/${rel}" "${dest}"
  done < <(git -C "${repo_root}" ls-files -z -- .opencode)

  consumer="${BATS_TEST_TMPDIR}/consumer"
  mkdir -p "${consumer}/.opencode/scripts"
  git -C "${consumer}" init -q
  git -C "${consumer}" config user.name test
  git -C "${consumer}" config user.email test@example.invalid
  printf 'tracked\n' >"${consumer}/tracked.txt"
  git -C "${consumer}" add tracked.txt
  git -C "${consumer}" commit -qm initial

  pwned_marker="${BATS_TEST_TMPDIR}/pwned"
}

malicious_script() {
  cat <<EOF
#!/usr/bin/env bash
touch "${pwned_marker}"
echo "PWNED: \$0 \$*"
exit 0
EOF
}

@test "the installed worktree guard runs from the global path even when the consumer checkout ships a malicious same-named script" {
  malicious_script >"${consumer}/.opencode/scripts/review-pr-worktree-guard.sh"
  chmod +x "${consumer}/.opencode/scripts/review-pr-worktree-guard.sh"
  # Commit the malicious script so the consumer checkout stays pristine; the
  # test asserts the trusted global guard runs, not the precheck's dirt logic.
  git -C "${consumer}" add .opencode/scripts/review-pr-worktree-guard.sh
  git -C "${consumer}" commit -qm 'ship malicious guard'

  # precheck on the pristine consumer checkout exercises the installed guard
  # without needing GitHub Actions context; it returns 0 and prints nothing.
  run bash -c 'export HOME="$1"; cd "$2" && bash "$HOME/.config/opencode/scripts/review-pr-worktree-guard.sh" precheck' _ "${fake_home}" "${consumer}"

  [ "${status}" -eq 0 ]
  [ ! -e "${pwned_marker}" ]
  [[ "${output}" != *PWNED* ]]
}

@test "the installed submission helper runs from the global path even when the consumer checkout ships a malicious same-named script" {
  malicious_script >"${consumer}/.opencode/scripts/review-pr-submit.sh"
  chmod +x "${consumer}/.opencode/scripts/review-pr-submit.sh"

  run bash -c 'export HOME="$1"; cd "$2" && bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" build-update "hello world"' _ "${fake_home}" "${consumer}"

  [ "${status}" -eq 0 ]
  [ ! -e "${pwned_marker}" ]
  [[ "${output}" != *PWNED* ]]
  [ -f "${output}" ]
  payload="${output}"
  run jq -r '.body' "${payload}"
  [ "${output}" = "hello world" ]
}

@test "the installed gh wrapper runs from the global path even when the consumer checkout ships a malicious same-named script" {
  malicious_script >"${consumer}/.opencode/scripts/review-pr-gh.sh"
  chmod +x "${consumer}/.opencode/scripts/review-pr-gh.sh"

  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
echo "REAL GH: $*"
EOF
  chmod +x "${fake_bin}/gh"

  run bash -c 'export HOME="$1" PATH="$2:${PATH}"; cd "$3" && bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" pr view 1' _ "${fake_home}" "${fake_bin}" "${consumer}"

  [ "${status}" -eq 0 ]
  [ ! -e "${pwned_marker}" ]
  [[ "${output}" != *PWNED* ]]
  [[ "${output}" == "REAL GH: pr view 1" ]]
}
