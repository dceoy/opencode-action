#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-pr-gh.sh"
  submit="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  orchestrator="${repo_root}/.opencode/agents/review-pr-orchestrator.md"
  fake_home="$(mktemp -d "${BATS_TEST_TMPDIR}/home.XXXXXX")"
  fake_bin="${fake_home}/bin"
  event_path="${fake_home}/event.json"
  mkdir -p "${fake_bin}"
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
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.id' <<<"${output}")" = "555" ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must pass validate-initial"* ]]
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
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

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
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed during token verification"* ]]
}

@test "validation rejects malformed JSON" {
  prepare_state
  printf '%s\n' '{"body": "Review", "comments": [' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected valid JSON"* ]]
}

@test "validation rejects a top level with disallowed extra keys" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}],"extra":"y"}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must contain exactly body and comments"* ]]
}

@test "validation rejects an empty body" {
  prepare_state
  printf '%s\n' '{"body":"","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"body must be a nonempty string"* ]]
}

@test "validation rejects an empty comments array" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comments must be a nonempty array"* ]]
}

@test "validation rejects a comment that is not an object" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":["not an object"]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 must be an object"* ]]
}

@test "validation rejects a comment with a missing path" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 path must be a nonempty string"* ]]
}

@test "validation rejects a non-positive comment line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":0,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 line must be a positive integer"* ]]
}

@test "validation rejects a non-integer comment line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1.5,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 line must be a positive integer"* ]]
}

@test "validation accepts a valid multiline comment range" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":2,"start_side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -eq 0 ]
}

@test "validation rejects a multiline comment missing start_side" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":2,"body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must include both start_line and start_side or neither"* ]]
}

@test "validation rejects a multiline comment whose start_line is after line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":9,"start_side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"range must use positive ordered lines on the same side"* ]]
}

@test "validation rejects a multiline comment whose start_side differs from side" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":2,"start_side":"LEFT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"range must use positive ordered lines on the same side"* ]]
}

@test "validation identifies a missing comment side without submitting" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 side must be LEFT or RIGHT"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "submission rejects a payload changed after validation" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\na different finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed after validation"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "validation rejects a diagnostic comment body without submitting" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"test comment"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "validation rejects a severity prefix with no blank line before content" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
}

@test "validation rejects a severity prefix with no content after the blank line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\n"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
}

@test "validation rejects an unrecognized severity name" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**foo · bar**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
}

@test "submission re-validates the payload even if the sealed file is tampered to match" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"test comment"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"
  jq -cS . "${fake_home}/.config/opencode/review-state/initial.json" >"${fake_home}/.config/opencode/review-state/validated-initial.json"

  run env HOME="${fake_home}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "validate-initial does not leave a temporary validated payload file behind" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -eq 0 ]
  [ -f "${fake_home}/.config/opencode/review-state/validated-initial.json" ]
  run bash -c "compgen -G '${fake_home}/.config/opencode/review-state/validated-initial.*.json'"
  [ "${status}" -ne 0 ]
}

@test "session guard is scoped per run so a persistent HOME does not block later runs" {
  run env HOME="${fake_home}" GITHUB_RUN_ID="100" GITHUB_RUN_ATTEMPT="1" bash "${submit}" prepare
  [ "${status}" -eq 0 ]

  run env HOME="${fake_home}" GITHUB_RUN_ID="100" GITHUB_RUN_ATTEMPT="1" bash "${submit}" prepare
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already prepared"* ]]

  run env HOME="${fake_home}" GITHUB_RUN_ID="101" GITHUB_RUN_ATTEMPT="1" bash "${submit}" prepare
  [ "${status}" -eq 0 ]

  run env HOME="${fake_home}" GITHUB_RUN_ID="101" GITHUB_RUN_ATTEMPT="2" bash "${submit}" prepare
  [ "${status}" -eq 0 ]
}

@test "review state can be prepared only once per run" {
  prepare_state

  run env HOME="${fake_home}" bash "${submit}" prepare

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already prepared"* ]]
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
