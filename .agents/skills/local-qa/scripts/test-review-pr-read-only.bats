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
[[ "$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]] || exit 1
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
if [[ "$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]]; then
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
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

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
if [[ "\$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]]; then
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
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"PR head changed"* ]]
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
  run ! grep -q "contains(github.event.comment.body, '/review-pr')" "${action_yml}"
  # shellcheck disable=SC2016
  grep -q 'rm -rf "${HOME}/.config/opencode"' "${action_yml}"
  # shellcheck disable=SC2016
  grep -q 'cp -r "${ACTION_PATH}/.opencode/."' "${action_yml}"
  grep -q 'writeFileSync("pwned-by-project-plugin"' "${malicious_plugin}"
}

@test "initial submission revalidates the PR head immediately before the POST" {
  write_resolver
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  count_file="${BATS_TEST_TMPDIR}/gh-count"
  post_marker="${BATS_TEST_TMPDIR}/gh-post"
  printf '0' >"${count_file}"
  cat >"${fake_bin}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]]; then
  count="\$(cat "${count_file}")"
  printf '%s' "\$((count + 1))" >"${count_file}"
  if [[ "\$count" -lt 2 ]]; then
    printf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  else
    printf '%s\\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fi
elif [[ "\$1" == "api" ]]; then
  : >"${post_marker}"
  jq -n '{id: 555}'
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Review","comments":[{"path":"x","line":1,"body":"finding"}]}' >"${fake_home}/.config/opencode/review-state/initial.json"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" submit-initial

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"PR head changed immediately before review submission"* ]]
  [ ! -e "${post_marker}" ]
}

@test "review update revalidates the PR head immediately before the PUT" {
  write_resolver
  printf '%s\n' '{"issue":{"number":42}}' >"${event_path}"
  count_file="${BATS_TEST_TMPDIR}/gh-count"
  put_marker="${BATS_TEST_TMPDIR}/gh-put"
  printf '0' >"${count_file}"
  cat >"${fake_bin}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "pr view 42 --json headRefOid --jq .headRefOid" ]]; then
  count="\$(cat "${count_file}")"
  printf '%s' "\$((count + 1))" >"${count_file}"
  if [[ "\$count" -lt 2 ]]; then
    printf '%s\\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  else
    printf '%s\\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fi
elif [[ "\$1" == "api" ]]; then
  : >"${put_marker}"
  jq -n '{id: 555}'
else
  exit 1
fi
EOF
  chmod +x "${fake_bin}/gh"
  prepare_state
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${helper}" context
  [ "${status}" -eq 0 ]
  printf '%s\n' '{"body":"Updated review"}' >"${fake_home}/.config/opencode/review-state/update.json"
  printf '555' >"${fake_home}/.config/opencode/review-state/review_id"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" bash "${submit}" update

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"PR head changed immediately before review submission"* ]]
  [ ! -e "${put_marker}" ]
}

@test "review mode guard strips caller-controlled OpenCode config env vars" {
  guard="${repo_root}/.opencode/scripts/review-mode-guard.sh"

  run bash -euo pipefail -c '
    source "$1"
    export OPENCODE_CONFIG=/tmp/evil.json
    export OPENCODE_CONFIG_DIR=/tmp/evil-dir
    export OPENCODE_CONFIG_CONTENT="{\"plugin\":[\"evil\"]}"
    opencode_review_strip_config_env
    [[ -z "${OPENCODE_CONFIG+x}" ]]
    [[ -z "${OPENCODE_CONFIG_DIR+x}" ]]
    [[ -z "${OPENCODE_CONFIG_CONTENT+x}" ]]
  ' _ "${guard}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Ignoring caller-provided OPENCODE_CONFIG in review-only mode"* ]]
  [[ "${output}" == *"Ignoring caller-provided OPENCODE_CONFIG_DIR in review-only mode"* ]]
  [[ "${output}" == *"Ignoring caller-provided OPENCODE_CONFIG_CONTENT in review-only mode"* ]]
}

@test "review mode guard enforces the OpenCode version floor and fails closed" {
  guard="${repo_root}/.opencode/scripts/review-mode-guard.sh"

  for version in 1.1.29 1.1.30 1.2.0 2.0.0 10.0.0; do
    run bash -euo pipefail -c 'source "$1"; opencode_review_enforce_version_floor "$2"' _ "${guard}" "${version}"
    [ "${status}" -eq 0 ]
  done

  for version in 1.1.28 1.0.99 0.9.9 "" latest 1.1 1.1.29-rc.1 v1.1.29 main; do
    run bash -euo pipefail -c 'source "$1"; opencode_review_enforce_version_floor "$2"' _ "${guard}" "${version}"
    [ "${status}" -ne 0 ]
  done
}

@test "action.yml applies the review mode guard before running OpenCode" {
  grep -q 'Enforce review-only OpenCode version floor' "${action_yml}"
  grep -q 'review-mode-guard.sh' "${action_yml}"
  grep -q 'opencode_review_enforce_version_floor' "${action_yml}"
  grep -q 'opencode_review_strip_config_env' "${action_yml}"
  # shellcheck disable=SC2016
  grep -q 'REVIEW_ONLY: ${{ steps.review_mode.outputs.enabled }}' "${action_yml}"
}
