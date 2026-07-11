#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-pr-gh.sh"
  orchestrator="${repo_root}/.opencode/agents/review-pr-orchestrator.md"
  fake_home="${BATS_TEST_TMPDIR}/home"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  event_path="${BATS_TEST_TMPDIR}/event.json"
  mkdir -p "${fake_home}" "${fake_bin}"
}

@test "issue_comment context resolves the PR head through GitHub" {
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]]; then
  printf '%s\n' 0123456789abcdef0123456789abcdef01234567
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  run env     HOME="${fake_home}"     PATH="${fake_bin}:${PATH}"     GITHUB_REPOSITORY="octo/repo"     GITHUB_EVENT_PATH="${event_path}"     bash "${helper}" context

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.repository' <<<"${output}")" = "octo/repo" ]
  [ "$(jq -r '.pr_number' <<<"${output}")" = "42" ]
  [ "$(jq -r '.head_sha' <<<"${output}")" = "0123456789abcdef0123456789abcdef01234567" ]
}

@test "pull_request context uses the head SHA from the event" {
  printf '%s\n' '{"pull_request":{"number":7,"head":{"sha":"abcdef0123456789abcdef0123456789abcdef01"}}}' >"${event_path}"

  run env     HOME="${fake_home}"     PATH="${fake_bin}:${PATH}"     GITHUB_REPOSITORY="octo/repo"     GITHUB_EVENT_PATH="${event_path}"     bash "${helper}" context

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.pr_number' <<<"${output}")" = "7" ]
  [ "$(jq -r '.head_sha' <<<"${output}")" = "abcdef0123456789abcdef0123456789abcdef01" ]
}

@test "issue_comment submission pins the fetched PR head" {
  submit="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  mkdir -p "${fake_home}/.config/opencode/scripts"
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  cat >"${fake_home}/.config/opencode/scripts/resolve-app-token.sh" <<'EOF'
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { return 0; }
EOF
  cat >"${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]]; then
  printf '%s\n' 0123456789abcdef0123456789abcdef01234567
elif [[ "$1" == "api" ]]; then
  jq -n '{id: 555}'
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" bash "${submit}" prepare
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env \
    HOME="${fake_home}" \
    PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" \
    GITHUB_EVENT_PATH="${event_path}" \
    bash "${submit}" submit-initial

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.id' <<<"${output}")" = "555" ]
}

@test "orchestrator allows no wildcard helper command" {
  allowed="$(
    awk '
      /^  bash:/ { in_bash = 1; next }
      /^  task:/ { in_bash = 0 }
      in_bash && /: allow$/ { print }
    ' "${orchestrator}"
  )"

  [[ "${allowed}" != *'*'* ]]
}

@test "orchestrator rejects shell composition syntax" {
  run grep -E '(: allow.*(>|>>|[|]|<\())|((>|>>|[|]|<\().*: allow)' "${orchestrator}"
  [ "${status}" -eq 1 ]
}
