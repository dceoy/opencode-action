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
  printf '{"pull_request":{"number":%s}}\n' "${number}" >"${event_path}"
}

write_context() {
  local repo="${1:-octo/repo}" number="${2:-42}" head="${3:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  jq -n --arg repository "${repo}" --argjson pr_number "${number}" --arg head_sha "${head}" \
    '{repository: $repository, pr_number: $pr_number, head_sha: $head_sha}' \
    >"${fake_home}/.config/opencode/review-state/context.json"
}

write_gh_head() {
  local head="${1:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  cat >"${fake_bin}/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == "pr view 42 --repo octo/repo --json headRefOid --jq .headRefOid" ]]; then
  printf '%s\n' '${head}'
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"
}

@test "trusted context accepts a matching event repository and live head" {
  write_event
  write_context
  write_gh_head

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'source "$1"; opencode_review_trusted_context' _ "${context_lib}"

  [ "${status}" -eq 0 ]
  [ "${output}" = $'octo/repo\t42\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]
}

@test "trusted context rejects a repository mismatch" {
  write_event
  write_context "other/repo"
  write_gh_head

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'source "$1"; opencode_review_trusted_context' _ "${context_lib}"

  [ "${status}" -ne 0 ]
}

@test "trusted context rejects a pull request mismatch" {
  write_event 43
  write_context
  write_gh_head

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'source "$1"; opencode_review_trusted_context' _ "${context_lib}"

  [ "${status}" -ne 0 ]
}

@test "trusted context rejects a stale live head" {
  write_event
  write_context
  write_gh_head "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'source "$1"; opencode_review_trusted_context' _ "${context_lib}"

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
  cat >"${installed_dir}/resolve-app-token.sh" <<'EOF'
opencode_prepare_gh_token() { return 0; }
EOF
  cat >"${checkout}/.opencode/scripts/review-pr-context.sh" <<EOF
touch '${marker}'
opencode_review_trusted_context() { return 0; }
opencode_review_event_pr_number() { printf '42'; }
EOF
  write_event
  write_context
  write_gh_head

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'cd "$1"; bash "$2" validate' _ "${checkout}" "${installed_dir}/review-pr-gh.sh"

  [ "${status}" -eq 0 ]
  [ ! -e "${marker}" ]
}
