#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  context_lib="${repo_root}/.opencode/scripts/review-pr-context.sh"
  gh_helper="${repo_root}/.opencode/scripts/review-pr-gh.sh"
  submit_helper="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  fake_home="$(mktemp -d "${BATS_TEST_TMPDIR}/home.XXXXXX")"
  fake_bin="${fake_home}/bin"
  event_path="${fake_home}/event.json"
  mkdir -p "${fake_bin}" "${fake_home}/.config/opencode/review-state"
}

write_event() {
  local number="${1:-42}"
  printf '{"pull_request":{"number":%s}}\n' "${number}" > "${event_path}"
}

write_context() {
  local repo="${1:-octo/repo}" number="${2:-42}"
  local base="${3:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  local head="${4:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  jq -n --arg repository "${repo}" --argjson pr_number "${number}" \
    --arg base_sha "${base}" --arg head_sha "${head}" \
    '{repository: $repository, pr_number: $pr_number, base_sha: $base_sha, head_sha: $head_sha}' \
    > "${fake_home}/.config/opencode/review-state/context.json"
}

write_gh_commit() {
  local head="${1:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  local resolved="${2:-${head}}"
  cat > "${fake_bin}/gh" << EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == "api repos/octo/repo/commits/${head} --jq .sha" ]]; then
  printf '%s\n' '${resolved}'
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"
}

run_trusted_context() {
  local repository="${1:-octo/repo}" path="${2:-${event_path}}"
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="${repository}" GITHUB_EVENT_PATH="${path}" \
    bash -c 'source "$1"; opencode_review_trusted_context' _ "${context_lib}"
}

assert_trusted_context_rejected() {
  run_trusted_context "$@"
  [ "${status}" -ne 0 ]
}

@test "trusted context accepts a matching event repository and pinned commit" {
  write_event
  write_context
  write_gh_commit

  run_trusted_context

  [ "${status}" -eq 0 ]
  [ "${output}" = $'octo/repo\t42\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]
}

@test "trusted context rejects a repository mismatch" {
  write_event
  write_context "other/repo"
  write_gh_commit

  assert_trusted_context_rejected
}

@test "trusted context rejects a pull request mismatch" {
  write_event 43
  write_context
  write_gh_commit

  assert_trusted_context_rejected
}

@test "trusted context accepts an advanced live head" {
  write_event
  write_context
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "api repos/octo/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --jq .sha" ]]; then
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  run_trusted_context

  [ "${status}" -eq 0 ]
}

@test "trusted context rejects an unreadable pinned commit" {
  write_event
  write_context
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  assert_trusted_context_rejected
}

@test "trusted context rejects a commit response with a different valid SHA" {
  write_event
  write_context
  write_gh_commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc

  assert_trusted_context_rejected
}

@test "trusted context rejects a resolved SHA that only prefixes the pinned SHA" {
  write_event
  write_context "octo/repo" 42 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "aaaaaaa"
  write_gh_commit aaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  assert_trusted_context_rejected
}

@test "trusted context rejects malformed or unavailable trust inputs" {
  local context_file="${fake_home}/.config/opencode/review-state/context.json"
  write_event
  write_gh_commit

  rm -f "${context_file}"
  assert_trusted_context_rejected

  : > "${context_file}"
  assert_trusted_context_rejected

  printf '{\n' > "${context_file}"
  assert_trusted_context_rejected

  jq -n --argjson pr_number 42 --arg head_sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    '{repository: 7, pr_number: $pr_number, head_sha: $head_sha}' > "${context_file}"
  assert_trusted_context_rejected

  write_context "octo/repo" 0
  assert_trusted_context_rejected

  write_context "octo/repo" 1.5
  assert_trusted_context_rejected

  write_context "octo/repo" 42 "not-a-sha"
  assert_trusted_context_rejected

  write_context "octo/repo" 42 "abcdef"
  assert_trusted_context_rejected

  write_context "octo/repo" 42 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  assert_trusted_context_rejected

  write_context
  assert_trusted_context_rejected "octo/repo" "${fake_home}/missing-event.json"

  printf '{\n' > "${event_path}"
  assert_trusted_context_rejected

  write_event
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_bin}/gh"
  assert_trusted_context_rejected
}

@test "metadata reads the captured snapshot without checking the live head" {
  local calls="${fake_home}/gh-calls"
  local base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_event
  write_context octo/repo 42 "${base}" "${head}"
  jq -n --arg base_sha "${base}" --arg head_sha "${head}" \
    '{
      number: 42,
      title: "Review",
      body: "Body",
      baseRefName: "main",
      baseRefOid: $base_sha,
      headRefName: "topic",
      headRefOid: $head_sha,
      files: [{path: "file.txt", additions: 1, deletions: 0}],
      url: "https://github.com/octo/repo/pull/42"
    }' > "${fake_home}/.config/opencode/review-state/metadata.json"
  cat > "${fake_bin}/gh" << EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>'${calls}'
if [[ "\$*" == "api repos/octo/repo/commits/${head} --jq .sha" ]]; then
  printf '%s\n' '${head}'
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${gh_helper}" metadata

  [ "${status}" -eq 0 ]
  [ "$(wc -l < "${calls}")" -eq 1 ]
  jq -e --arg head_sha "${head}" \
    '.headRefOid == $head_sha and .baseRefOid == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and .files[0].path == "file.txt"' \
    <<< "${output}" > /dev/null
}

@test "metadata rejects a pinned snapshot that no longer matches the trusted context" {
  local base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local mismatched_head=cccccccccccccccccccccccccccccccccccccccc
  write_event
  write_context octo/repo 42 "${base}" "${head}"
  jq -n --arg base_sha "${base}" --arg head_sha "${mismatched_head}" \
    '{
      number: 42,
      title: "Review",
      body: "Body",
      baseRefName: "main",
      baseRefOid: $base_sha,
      headRefName: "topic",
      headRefOid: $head_sha,
      files: [{path: "file.txt", additions: 1, deletions: 0}],
      url: "https://github.com/octo/repo/pull/42"
    }' > "${fake_home}/.config/opencode/review-state/metadata.json"
  write_gh_commit "${head}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${gh_helper}" metadata

  [ "${status}" -ne 0 ]
}

@test "both review helpers source the canonical trusted context implementation" {
  grep -Fq 'review-pr-context.sh' "${gh_helper}"
  grep -Fq 'review-pr-context.sh' "${submit_helper}"

  run grep -Eq '^(event_pr_number|read_context|trusted_context)\(\)' "${gh_helper}" "${submit_helper}"
  [ "${status}" -eq 1 ]
}

@test "installed read helper ignores repository-controlled trusted context files" {
  local installed_dir checkout marker
  installed_dir="${fake_home}/.config/opencode/scripts"
  checkout="${fake_home}/checkout"
  marker="${fake_home}/repository-helper-ran"
  mkdir -p "${installed_dir}" "${checkout}/.opencode/scripts"
  cp "${gh_helper}" "${installed_dir}/review-pr-gh.sh"
  cp "${context_lib}" "${installed_dir}/review-pr-context.sh"
  cat > "${installed_dir}/resolve-app-token.sh" << 'EOF'
opencode_prepare_gh_token() { return 0; }
EOF
  cat > "${checkout}/.opencode/scripts/review-pr-context.sh" << EOF
touch '${marker}'
opencode_review_trusted_context() { return 0; }
opencode_review_event_pr_number() { printf '42'; }
EOF
  write_event
  write_context
  write_gh_commit

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'cd "$1"; bash "$2" validate' _ "${checkout}" "${installed_dir}/review-pr-gh.sh"

  [ "${status}" -eq 0 ]
  [ ! -e "${marker}" ]
}

@test "installed submission helper ignores repository-controlled trusted context files" {
  local installed_dir checkout marker
  installed_dir="${fake_home}/.config/opencode/scripts"
  checkout="${fake_home}/checkout"
  marker="${fake_home}/repository-helper-ran"
  mkdir -p "${installed_dir}" "${checkout}/.opencode/scripts"
  cp "${submit_helper}" "${installed_dir}/review-pr-submit.sh"
  cp "${context_lib}" "${installed_dir}/review-pr-context.sh"
  cat > "${checkout}/.opencode/scripts/review-pr-context.sh" << EOF
touch '${marker}'
opencode_review_trusted_context() { return 0; }
opencode_review_event_pr_number() { printf '42'; }
EOF

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    bash -c 'cd "$1"; bash "$2" prepare' _ "${checkout}" "${installed_dir}/review-pr-submit.sh"

  [ "${status}" -eq 0 ]
  [ ! -e "${marker}" ]
}
