#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  fake_home="${BATS_TEST_TMPDIR}/home"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  event_path="${BATS_TEST_TMPDIR}/event.json"
  payload="${BATS_TEST_TMPDIR}/payload.json"
  gh_log="${BATS_TEST_TMPDIR}/gh.log"
  mkdir -p "${fake_home}/.config/opencode/scripts/opencode-action" "${fake_bin}"
  printf '%s\n' '{"pull_request":{"number":42}}' >"${event_path}"
  cat >"${fake_home}/.config/opencode/scripts/opencode-action/resolve-app-token.sh" <<'EOF_INNER'
opencode_require_app_token_for_review() { return 0; }
opencode_assert_pr_head_unchanged() {
  [[ "$3" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
}
EOF_INNER
  cat >"${fake_bin}/gh" <<EOF_INNER
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${gh_log}"
if [[ "\$1" == "api" && "\$2" == "--method" && "\$3" == "POST" ]]; then
  input=""
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--input" ]]; then
      input="\$2"
      break
    fi
    shift
  done
  jq -e '.event == "COMMENT"
    and .commit_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and (.comments | length == 1)' "\${input}"
  jq -n '{id: 123}'
fi
EOF_INNER
  chmod +x "${fake_bin}/gh"
}

write_payload() {
  cat >"${payload}" <<'EOF_INNER'
{
  "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "body": "Review",
  "comments": [
    {
      "path": "x.py",
      "line": 1,
      "side": "RIGHT",
      "body": "Finding"
    }
  ]
}
EOF_INNER
}

@test "submits a validated review to the event repository and PR" {
  write_payload
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${helper}" "${payload}"

  [ "${status}" -eq 0 ]
  grep -q 'repos/octo/repo/pulls/42/reviews' "${gh_log}"
}

@test "rejects caller-controlled event or target fields" {
  write_payload
  jq '. + {event: "APPROVE", repository: "other/repo"}' "${payload}" >"${payload}.tmp"
  mv "${payload}.tmp" "${payload}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${helper}" "${payload}"

  [ "${status}" -ne 0 ]
  [ ! -e "${gh_log}" ]
}

@test "rejects file-level comments and unsupported keys" {
  write_payload
  jq '.comments[0] = {
    path: "x.py",
    subject_type: "file",
    body: "Finding"
  }' "${payload}" >"${payload}.tmp"
  mv "${payload}.tmp" "${payload}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${helper}" "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -e "${gh_log}" ]

  write_payload
  jq '.comments[0].unexpected = true' "${payload}" >"${payload}.tmp"
  mv "${payload}.tmp" "${payload}"
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${helper}" "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -e "${gh_log}" ]
}

@test "accepts a consistent multi-line anchor" {
  write_payload
  jq '.comments[0] += {start_line: 1, start_side: "RIGHT"}
    | .comments[0].line = 2' "${payload}" >"${payload}.tmp"
  mv "${payload}.tmp" "${payload}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${helper}" "${payload}"

  [ "${status}" -eq 0 ]
}

@test "rejects a stale or malformed commit before the POST" {
  write_payload
  jq '.commit_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "${payload}" >"${payload}.tmp"
  mv "${payload}.tmp" "${payload}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${helper}" "${payload}"

  [ "${status}" -ne 0 ]
  [ ! -e "${gh_log}" ]
}
