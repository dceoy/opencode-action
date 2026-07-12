#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-pr-gh.sh"
  submit="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  orchestrator="${repo_root}/.opencode/agents/review-pr-orchestrator.md"
  fake_home="${BATS_TEST_TMPDIR}/home"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  event_path="${BATS_TEST_TMPDIR}/event.json"
  action_yml="${repo_root}/action.yml"
  malicious_plugin="${repo_root}/.agents/skills/local-qa/fixtures/malicious-project/.opencode/plugins/pwn.ts"
  mkdir -p "${fake_home}" "${fake_bin}"
}

write_resolver() {
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat >"${fake_home}/.config/opencode/scripts/resolve-app-token.sh" <<'EOF'
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { return 0; }
EOF
}

prepare_state() {
  run env HOME="${fake_home}" bash "${submit}" prepare
  [ "${status}" -eq 0 ]
}

@test "issue_comment context resolves and pins the PR head" {
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "pr view 42 --repo octo/repo --json headRefOid --jq .headRefOid" ]] || exit 1
printf '%s\n' 0123456789abcdef0123456789abcdef01234567
EOF
  chmod +x "${fake_bin}/gh"
  prepare_state

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.pr_number' <<<"${output}")" = "42" ]
  [ "$(jq -r '.head_sha' <<<"${output}")" = "0123456789abcdef0123456789abcdef01234567" ]
}

@test "pull_request context uses the event head SHA" {
  printf '%s\n' '{"pull_request":{"number":7,"head":{"sha":"abcdef0123456789abcdef0123456789abcdef01"}}}' >"${event_path}"
  prepare_state

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.pr_number' <<<"${output}")" = "7" ]
  [ "$(jq -r '.head_sha' <<<"${output}")" = "abcdef0123456789abcdef0123456789abcdef01" ]
}

@test "issue_comment submission uses the pinned PR head" {
  write_resolver
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "pr view 42 --repo octo/repo --json headRefOid --jq .headRefOid" ]]; then
  printf '%s\n' 0123456789abcdef0123456789abcdef01234567
elif [[ "$1" == "api" ]]; then
  jq -n '{id: 555}'
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.id' <<<"${output}")" = "555" ]
}

@test "submission fails if the PR head changes after context" {
  write_resolver
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  count_file="${BATS_TEST_TMPDIR}/gh-count"
  printf '0' >"${count_file}"
  cat >"${fake_bin}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "pr view 42 --repo octo/repo --json headRefOid --jq .headRefOid" ]]; then
  count="\$(cat "${count_file}")"
  if [[ "\$count" == "0" ]]; then
    printf '1' >"${count_file}"
    printf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  else
    printf '%s\\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fi
elif [[ "\$1" == "api" ]]; then
  exit 99
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"PR head changed"* ]]
}

@test "submission rechecks the PR head after token verification" {
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  count_file="${BATS_TEST_TMPDIR}/gh-count"
  printf '0' >"${count_file}"
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat >"${fake_home}/.config/opencode/scripts/resolve-app-token.sh" <<EOF
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { printf '2' >"${count_file}"; }
EOF
  cat >"${fake_bin}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "pr view 42 --repo octo/repo --json headRefOid --jq .headRefOid" ]]; then
  count="\$(cat "${count_file}")"
  if [[ "\$count" == "2" ]]; then
    printf '%s\\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  else
    printf '1' >"${count_file}"
    printf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fi
elif [[ "\$1" == "api" ]]; then
  exit 99
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed during token verification"* ]]
}

@test "orchestrator helper commands are exact and reject shell composition" {
  allowed="$(
    awk '
      /^  bash:/ { in_bash = 1; next }
      /^  task:/ { in_bash = 0 }
      in_bash && /: allow$/ { print }
    ' "${orchestrator}"
  )"

  [[ "${allowed}" != *'*'* ]]
  run grep -E '(: allow.*(>|>>|[|]|<\())|((>|>>|[|]|<\().*: allow)' "${orchestrator}"
  [ "${status}" -eq 1 ]
}

@test "review mode excludes project config and refreshes global toolkit" {
  # This is a source-level guard. A true malicious-plugin execution test needs
  # an installed OpenCode runtime and belongs in an end-to-end workflow.
  grep -q 'Detect review-only mode' "${action_yml}"
  grep -q 'OPENCODE_DISABLE_PROJECT_CONFIG:' "${action_yml}"
  grep -q 'unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT' "${action_yml}"
  # shellcheck disable=SC2016
  [ "$(grep -c 'export XDG_CONFIG_HOME="${HOME}/.config"' "${action_yml}")" -eq 2 ]
  grep -q 'requires OpenCode 1.2.14 or newer' "${action_yml}"
  run grep -q "contains(github.event.comment.body, '/review-pr')" "${action_yml}"
  [ "${status}" -eq 1 ]
  # shellcheck disable=SC2016
  grep -q 'rm -rf "${HOME}/.config/opencode"' "${action_yml}"
  # shellcheck disable=SC2016
  grep -q 'cp -r "${ACTION_PATH}/.opencode/."' "${action_yml}"
  grep -q 'writeFileSync("pwned-by-project-plugin"' "${malicious_plugin}"
}
