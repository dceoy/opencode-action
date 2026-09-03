#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-pr-gh.sh"
  submit="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  orchestrator="${repo_root}/.opencode/agents/review-pr-orchestrator.md"
  fake_home="$(mktemp -d "${BATS_TEST_TMPDIR}/home.XXXXXX")"
  fake_bin="${fake_home}/bin"
  event_path="${fake_home}/event.json"
  base_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "${fake_bin}"
}

write_resolver() {
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat > "${fake_home}/.config/opencode/scripts/resolve-app-token.sh" << 'EOF'
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { return 0; }
EOF
}

prepare_state() {
  run env HOME="${fake_home}" bash "${submit}" prepare
  [ "${status}" -eq 0 ]
}

write_snapshot_gh() {
  local live_head="${1:-${head_sha}}" live_title="${2:-Review}" live_base="${3:-${base_sha}}"
  gh_calls="${fake_home}/gh-calls"
  request_log="${fake_home}/request-log"
  commit_calls="${fake_home}/commit-calls"
  live_head_file="${fake_home}/live-head"
  printf '%s\n' "${live_head}" > "${live_head_file}"
  cat > "${fake_bin}/gh" << EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${gh_calls}"
if [[ "\$*" == pr\\ view\\ * ]]; then
  current_live_head="\$(cat "${live_head_file}")"
  printf '%s\n' '{"headRefOid":"'"\${current_live_head}"'"}'
elif [[ "\$*" == "api repos/octo/repo/pulls/42" ]]; then
  case "\${COMPARE_CASE:-valid}" in
    bad-pr-metadata)
      printf '%s\n' '{"number":42,"title":null,"body":"Body","base":{"ref":"main","sha":"${live_base}"},"head":{"ref":"topic","sha":"${live_head}"},"html_url":"https://github.com/octo/repo/pull/42"}'
      ;;
    mismatched-number)
      printf '%s\n' '{"number":99,"title":"${live_title}","body":"Body","base":{"ref":"main","sha":"${live_base}"},"head":{"ref":"topic","sha":"${live_head}"},"html_url":"https://github.com/octo/repo/pull/42"}'
      ;;
    invalid-body)
      printf '%s\n' '{"number":42,"title":"${live_title}","body":7,"base":{"ref":"main","sha":"${live_base}"},"head":{"ref":"topic","sha":"${live_head}"},"html_url":"https://github.com/octo/repo/pull/42"}'
      ;;
    missing-base-branch)
      printf '%s\n' '{"number":42,"title":"${live_title}","body":"Body","base":{"ref":null,"sha":"${live_base}"},"head":{"ref":"topic","sha":"${live_head}"},"html_url":"https://github.com/octo/repo/pull/42"}'
      ;;
    missing-head-branch)
      printf '%s\n' '{"number":42,"title":"${live_title}","body":"Body","base":{"ref":"main","sha":"${live_base}"},"head":{"ref":null,"sha":"${live_head}"},"html_url":"https://github.com/octo/repo/pull/42"}'
      ;;
    missing-url)
      printf '%s\n' '{"number":42,"title":"${live_title}","body":"Body","base":{"ref":"main","sha":"${live_base}"},"head":{"ref":"topic","sha":"${live_head}"},"html_url":null}'
      ;;
    *)
      printf '%s\n' '{"number":42,"title":"${live_title}","body":"Body","base":{"ref":"main","sha":"${live_base}"},"head":{"ref":"topic","sha":"${live_head}"},"html_url":"https://github.com/octo/repo/pull/42"}'
      ;;
  esac
elif [[ "\$*" == "api repos/octo/repo/commits/${head_sha} --jq .sha" ]]; then
  commit_count=0
  if [[ -f "${commit_calls}" ]]; then
    commit_count="\$(wc -l < "${commit_calls}")"
  fi
  commit_count=\$((commit_count + 1))
  printf '%s\n' "\$commit_count" >> "${commit_calls}"
  if [[ "\${COMPARE_CASE:-valid}" == unreadable-head ]]; then
    exit 1
  fi
  if [[ "\${ASSERT_TOKEN_BEFORE_COMMIT:-false}" == true && "\$commit_count" -ge 3 && ! -e "${fake_home}/token-verified" ]]; then
    : > "${fake_home}/commit-before-token"
  fi
  if [[ "\${FAIL_COMMIT_CALL:-0}" == "\$commit_count" ]]; then
    exit 1
  fi
  if [[ "\${ADVANCE_AFTER_COMMIT:-false}" == true && "\$commit_count" -ge 3 ]]; then
    printf '%s\n' dddddddddddddddddddddddddddddddddddddddd > "${live_head_file}"
  fi
  printf '%s\n' '${head_sha}'
elif [[ "\$*" == "api repos/octo/repo/compare/${base_sha}...${head_sha}" ]]; then
  case "\${COMPARE_CASE:-valid}" in
    compare-error)
      exit 1
      ;;
    missing-files)
      printf '%s\n' '{}'
      ;;
    malformed-file)
      printf '%s\n' '{"files":[{"filename":"file.txt","additions":"1","deletions":0}]}'
      ;;
    negative-additions)
      printf '%s\n' '{"files":[{"filename":"file.txt","additions":-1,"deletions":0}]}'
      ;;
    fractional-additions)
      printf '%s\n' '{"files":[{"filename":"file.txt","additions":1.5,"deletions":0}]}'
      ;;
    large)
      jq -cn '{files: [range(0; 300) | {filename: ("file-" + tostring), additions: 1, deletions: 0}]}'
      ;;
    *)
      printf '%s\n' '{"files":[{"filename":"file.txt","additions":1,"deletions":0}]}'
      ;;
  esac
elif [[ "\$*" == "api -H Accept: application/vnd.github.diff repos/octo/repo/compare/${base_sha}...${head_sha}" ]]; then
  printf '%s\n' 'diff for pinned snapshot'
elif [[ "\$*" == api\\ --method\\ POST\\ repos/octo/repo/pulls/42/reviews\\ --input\\ * ]]; then
  if [[ "\${FAIL_REVIEW_POST:-false}" == true ]]; then
    printf '%s\n' '{"message":"Validation Failed"}' >&2
    exit 1
  fi
  request_file=""
  for arg in "\$@"; do
    request_file="\$arg"
  done
  if [[ "\${ASSERT_LIVE_HEAD_AT_WRITE:-false}" == true && "\$(cat "${live_head_file}")" != dddddddddddddddddddddddddddddddddddddddd ]]; then
    exit 1
  fi
  if [[ "\${VALIDATE_REVIEW_REQUEST:-false}" == true ]]; then
    jq -e --arg pinned_head '${head_sha}' '
      type == "object"
      and .event == "COMMENT"
      and .commit_id == \$pinned_head
      and (.body | type == "string" and length > 0)
      and (.comments | type == "array" and length > 0)
      and all(.comments[];
        type == "object"
        and (.body | type == "string" and length > 0)
        and (.path | type == "string" and length > 0)
        and (.line | type == "number" and floor == . and . > 0)
        and (.side == "LEFT" or .side == "RIGHT")
      )
    ' "\${request_file}" > /dev/null || exit 1
  fi
  jq -c '.commit_id' "\${request_file}" >> "${request_log}"
  printf '%s\n' '{"id":555}'
elif [[ "\$*" == api\\ --method\\ PUT\\ repos/octo/repo/pulls/42/reviews/555\\ --input\\ * ]]; then
  if [[ "\${FAIL_REVIEW_PUT:-false}" == true ]]; then
    printf '%s\n' '{"message":"Validation Failed"}' >&2
    exit 1
  fi
  request_file=""
  for arg in "\$@"; do
    request_file="\$arg"
  done
  if [[ "\${ASSERT_LIVE_HEAD_AT_WRITE:-false}" == true && "\$(cat "${live_head_file}")" != dddddddddddddddddddddddddddddddddddddddd ]]; then
    exit 1
  fi
  if [[ "\${VALIDATE_REVIEW_REQUEST:-false}" == true ]]; then
    jq -e 'keys == ["body"] and (.body | type == "string" and length > 0)' "\${request_file}" > /dev/null || exit 1
  fi
  printf '%s\n' '{}'
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"
}

write_issue_comment_event() {
  printf '%s\n' '{"issue":{"number":42}}' > "${event_path}"
}

write_pull_request_event() {
  printf '%s\n' "{\"pull_request\":{\"number\":42,\"title\":\"Event snapshot\",\"body\":\"Event body\",\"html_url\":\"https://github.com/octo/repo/pull/42?event=snapshot\",\"base\":{\"ref\":\"event-main\",\"sha\":\"${base_sha}\"},\"head\":{\"ref\":\"event-topic\",\"sha\":\"${head_sha}\"}}}" > "${event_path}"
}

@test "issue_comment context resolves and pins both PR SHAs" {
  write_issue_comment_event
  write_snapshot_gh
  prepare_state

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.pr_number' <<< "${output}")" = "42" ]
  [ "$(jq -r '.base_sha' <<< "${output}")" = "${base_sha}" ]
  [ "$(jq -r '.head_sha' <<< "${output}")" = "${head_sha}" ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" metadata

  [ "${status}" -eq 0 ]
  jq -e '
    .title == "Review"
    and .body == "Body"
    and .baseRefName == "main"
    and .headRefName == "topic"
    and .url == "https://github.com/octo/repo/pull/42"
  ' <<< "${output}" > /dev/null
}

@test "context fails closed for invalid snapshot responses" {
  local compare_case
  write_issue_comment_event
  write_snapshot_gh
  prepare_state

  for compare_case in bad-pr-metadata mismatched-number invalid-body missing-base-branch missing-head-branch missing-url unreadable-head compare-error missing-files malformed-file negative-additions fractional-additions large; do
    run env COMPARE_CASE="${compare_case}" HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context

    [ "${status}" -ne 0 ]
    [ ! -s "${fake_home}/.config/opencode/review-state/context.json" ]
    [ ! -e "${fake_home}/.config/opencode/review-state/metadata.json" ]
  done
}

@test "pull_request context uses the event base and head SHAs" {
  write_pull_request_event
  write_snapshot_gh "dddddddddddddddddddddddddddddddddddddd" "Live metadata" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  prepare_state

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.base_sha' <<< "${output}")" = "${base_sha}" ]
  [ "$(jq -r '.head_sha' <<< "${output}")" = "${head_sha}" ]
  grep -Fq "api repos/octo/repo/compare/${base_sha}...${head_sha}" "${gh_calls}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" metadata

  [ "${status}" -eq 0 ]
  jq -e '
    .title == "Event snapshot"
    and .body == "Event body"
    and .baseRefName == "event-main"
    and .headRefName == "event-topic"
    and .url == "https://github.com/octo/repo/pull/42?event=snapshot"
  ' <<< "${output}" > /dev/null
}

@test "issue_comment submission uses the pinned head commit" {
  write_resolver
  write_issue_comment_event
  write_snapshot_gh
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -eq 0 ]
  [ "$(jq -r '.id' <<< "${output}")" = "555" ]
  [ "$(cat "${request_log}")" = "\"${head_sha}\"" ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must pass validate-initial"* ]]
}

@test "submission succeeds when the live PR head advances after context" {
  write_issue_comment_event
  write_snapshot_gh
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  : > "${gh_calls}"
  write_snapshot_gh "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat > "${fake_home}/.config/opencode/scripts/resolve-app-token.sh" << EOF
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "${live_head_file}"; }
EOF
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env ADVANCE_AFTER_COMMIT=true ASSERT_LIVE_HEAD_AT_WRITE=true VALIDATE_REVIEW_REQUEST=true HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -eq 0 ]
  run grep -q 'pr view' "${gh_calls}"
  [ "${status}" -ne 0 ]
  [ "$(cat "${live_head_file}")" = dddddddddddddddddddddddddddddddddddddddd ]
  [ "$(cat "${request_log}")" = "\"${head_sha}\"" ]
}

@test "submission rechecks the pinned commit after token verification" {
  write_issue_comment_event
  write_snapshot_gh
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat > "${fake_home}/.config/opencode/scripts/resolve-app-token.sh" << EOF
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { : > "${fake_home}/token-verified"; }
EOF
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -eq 0 ]
  [ -e "${fake_home}/token-verified" ]
  [ "$(cat "${request_log}")" = "\"${head_sha}\"" ]
}

@test "submission fails closed when the pinned commit becomes unreadable after token verification" {
  write_issue_comment_event
  write_snapshot_gh
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat > "${fake_home}/.config/opencode/scripts/resolve-app-token.sh" << EOF
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { : > "${fake_home}/token-verified"; }
EOF
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env ASSERT_TOKEN_BEFORE_COMMIT=true ADVANCE_AFTER_COMMIT=true ASSERT_LIVE_HEAD_AT_WRITE=true VALIDATE_REVIEW_REQUEST=true FAIL_COMMIT_CALL=3 HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"after token verification"* ]]
  [ -e "${fake_home}/token-verified" ]
  [ ! -e "${fake_home}/commit-before-token" ]
  [ ! -e "${request_log}" ]
  run grep -Fq 'api --method POST repos/octo/repo/pulls/42/reviews --input' "${gh_calls}"
  [ "${status}" -ne 0 ]
}

@test "submission stops when GitHub rejects the pinned review anchor" {
  write_resolver
  write_issue_comment_event
  write_snapshot_gh
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]

  run env FAIL_REVIEW_POST=true VALIDATE_REVIEW_REQUEST=true HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"::error::Failed to submit the review."* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/review_id" ]
  [ "$(grep -Fc 'api --method POST repos/octo/repo/pulls/42/reviews --input' "${gh_calls}")" -eq 1 ]
  run grep -q 'pr view' "${gh_calls}"
  [ "${status}" -ne 0 ]
}

@test "metadata and diff remain pinned after the live head advances" {
  write_issue_comment_event
  write_snapshot_gh
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]

  write_snapshot_gh "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "Changed live metadata" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  : > "${gh_calls}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" metadata
  [ "${status}" -eq 0 ]
  jq -e --arg base_sha "${base_sha}" --arg head_sha "${head_sha}" \
    '.title == "Review" and .body == "Body" and .baseRefName == "main" and .headRefName == "topic" and .baseRefOid == $base_sha and .headRefOid == $head_sha and .files == [{path:"file.txt", additions:1, deletions:0}]' \
    <<< "${output}" > /dev/null

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" diff
  [ "${status}" -eq 0 ]
  [ "${output}" = "diff for pinned snapshot" ]
  run grep -q 'pr view' "${gh_calls}"
  [ "${status}" -ne 0 ]
  grep -Fq "api -H Accept: application/vnd.github.diff repos/octo/repo/compare/${base_sha}...${head_sha}" "${gh_calls}"
}

@test "update accepts an advanced live head and keeps the recorded review ID" {
  write_resolver
  write_issue_comment_event
  write_snapshot_gh
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s' 555 > "${fake_home}/.config/opencode/review-state/review_id"
  printf '%s\n' '{"body":"Updated review"}' > "${fake_home}/.config/opencode/review-state/update.json"

  write_snapshot_gh "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  cat > "${fake_home}/.config/opencode/scripts/resolve-app-token.sh" << EOF
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "${live_head_file}"; }
EOF
  : > "${gh_calls}"
  run env ADVANCE_AFTER_COMMIT=true ASSERT_LIVE_HEAD_AT_WRITE=true VALIDATE_REVIEW_REQUEST=true HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" update

  [ "${status}" -eq 0 ]
  [ "$(cat "${live_head_file}")" = dddddddddddddddddddddddddddddddddddddddd ]
  run grep -q 'pr view' "${gh_calls}"
  [ "${status}" -ne 0 ]
  grep -Fq 'api --method PUT repos/octo/repo/pulls/42/reviews/555 --input' "${gh_calls}"
}

@test "update stops when GitHub rejects the pinned review anchor" {
  write_resolver
  write_issue_comment_event
  write_snapshot_gh
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s' 555 > "${fake_home}/.config/opencode/review-state/review_id"
  printf '%s\n' '{"body":"Updated review"}' > "${fake_home}/.config/opencode/review-state/update.json"

  run env FAIL_REVIEW_PUT=true HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" update

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Failed to submit the review update"* ]]
  [ "$(grep -Fc 'api --method PUT repos/octo/repo/pulls/42/reviews/555 --input' "${gh_calls}")" -eq 1 ]
  run grep -q 'pr view' "${gh_calls}"
  [ "${status}" -ne 0 ]
}

@test "update fails closed when the pinned commit becomes unreadable after token verification" {
  write_issue_comment_event
  write_snapshot_gh
  mkdir -p "${fake_home}/.config/opencode/scripts"
  cat > "${fake_home}/.config/opencode/scripts/resolve-app-token.sh" << EOF
opencode_prepare_gh_token() { return 0; }
opencode_require_app_token_for_review() { : > "${fake_home}/token-verified"; }
EOF
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s' 555 > "${fake_home}/.config/opencode/review-state/review_id"
  printf '%s\n' '{"body":"Updated review"}' > "${fake_home}/.config/opencode/review-state/update.json"

  run env ASSERT_TOKEN_BEFORE_COMMIT=true FAIL_COMMIT_CALL=3 HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" update

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"after token verification"* ]]
  [ -e "${fake_home}/token-verified" ]
  [ ! -e "${fake_home}/commit-before-token" ]
  run grep -Fq 'api --method PUT repos/octo/repo/pulls/42/reviews/555 --input' "${gh_calls}"
  [ "${status}" -ne 0 ]
}

@test "validation rejects malformed JSON" {
  prepare_state
  printf '%s\n' '{"body": "Review", "comments": [' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected valid JSON"* ]]
}

@test "validation rejects a top level with disallowed extra keys" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}],"extra":"y"}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must contain exactly body and comments"* ]]
}

@test "validation rejects an empty body" {
  prepare_state
  printf '%s\n' '{"body":"","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"body must be a nonempty string"* ]]
}

@test "validation rejects an empty comments array" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comments must be a nonempty array"* ]]
}

@test "validation rejects a comment that is not an object" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":["not an object"]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 must be an object"* ]]
}

@test "validation rejects a comment with a missing path" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 path must be a nonempty string"* ]]
}

@test "validation rejects a non-positive comment line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":0,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 line must be a positive integer"* ]]
}

@test "validation rejects a non-integer comment line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1.5,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 line must be a positive integer"* ]]
}

@test "validation accepts a valid multiline comment range" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":2,"start_side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -eq 0 ]
}

@test "validation rejects a multiline comment missing start_side" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":2,"body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must include both start_line and start_side or neither"* ]]
}

@test "validation rejects a multiline comment whose start_line is after line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":9,"start_side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"range must use positive ordered lines on the same side"* ]]
}

@test "validation rejects a multiline comment whose start_side differs from side" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":5,"side":"RIGHT","start_line":2,"start_side":"LEFT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"range must use positive ordered lines on the same side"* ]]
}

@test "validation identifies a missing comment side without submitting" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"comment 0 side must be LEFT or RIGHT"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "submission rejects a payload changed after validation" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\na different finding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed after validation"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "validation rejects a diagnostic comment body without submitting" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"test comment"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "validation rejects a severity prefix with no blank line before content" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
}

@test "validation rejects a severity prefix with no content after the blank line" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\n"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
}

@test "validation rejects an unrecognized severity name" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**foo · bar**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" bash "${submit}" validate-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
}

@test "submission re-validates the payload even if the sealed file is tampered to match" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  run env HOME="${fake_home}" bash "${submit}" validate-initial
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"test comment"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"
  jq -cS . "${fake_home}/.config/opencode/review-state/initial.json" > "${fake_home}/.config/opencode/review-state/validated-initial.json"

  run env HOME="${fake_home}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"must begin with a severity and reviewer source"* ]]
  [ ! -e "${fake_home}/.config/opencode/review-state/submission-attempted" ]
}

@test "validate-initial does not leave a temporary validated payload file behind" {
  prepare_state
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"side":"RIGHT","body":"**important · code-reviewer**\n\nfinding"}]}' > "${fake_home}/.config/opencode/review-state/initial.json"

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
