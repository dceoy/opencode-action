#!/usr/bin/env bats
# Exercises review-pr-submit.sh: it derives the write target from the trusted
# GitHub Actions context (never caller arguments), re-verifies the worktree and
# per-run state binding before touching a credential, pins updates to the
# review ID it recorded, and never mutates the checkout. A stubbed `gh` records
# every API call so the write target and credential boundary can be asserted.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"

  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_home}/.config/opencode"
  while IFS= read -r -d '' rel; do
    dest="${fake_home}/.config/opencode/${rel#.opencode/}"
    mkdir -p "$(dirname "${dest}")"
    cp -p "${repo_root}/${rel}" "${dest}"
  done < <(git -C "${repo_root}" ls-files -z -- .opencode)
  submit="${fake_home}/.config/opencode/scripts/review-pr-submit.sh"
  guard="${fake_home}/.config/opencode/scripts/review-pr-worktree-guard.sh"

  repo="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${repo}"
  git -C "${repo}" init -q
  git -C "${repo}" config user.name test
  git -C "${repo}" config user.email test@example.invalid
  printf 'original\n' >"${repo}/tracked.txt"
  git -C "${repo}" add tracked.txt
  git -C "${repo}" commit -qm initial
  head_sha="$(git -C "${repo}" rev-parse HEAD)"

  runner_temp="${BATS_TEST_TMPDIR}/runner-temp"
  mkdir -p "${runner_temp}"
  tmpdir="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${tmpdir}"

  event_path="${BATS_TEST_TMPDIR}/event.json"
  write_event "octo/repo-name" 42 "${head_sha}"

  gh_log="${BATS_TEST_TMPDIR}/gh.log"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${gh_log}"
echo '{"id": 555, "user": {"login": "opencode-agent[bot]"}}'
EOF
  chmod +x "${fake_bin}/gh"

  export HOME="${fake_home}"
  export PATH="${fake_bin}:${PATH}"
  export GITHUB_REPOSITORY="octo/repo-name"
  export GITHUB_EVENT_PATH="${event_path}"
  export GITHUB_RUN_ID="1000"
  export GITHUB_RUN_ATTEMPT="1"
  export RUNNER_TEMP="${runner_temp}"
  export TMPDIR="${tmpdir}"
  # Bypass App-token identity probing so no `gh` probe write is needed; the
  # write-target and mutation assertions are independent of the token flow.
  export USE_GITHUB_TOKEN="true"
}

write_event() {
  jq -n --arg n "$2" --arg sha "$3" \
    '{pull_request: {number: ($n | tonumber), head: {sha: $sha}}}' >"${event_path}"
}

in_repo() {
  (cd "${repo}" && "$@")
}

build_initial_payload() {
  in_repo bash "${submit}" build-initial "Review body" '[{"path":"tracked.txt","line":1,"body":"x"}]'
}

@test "submit-initial fails when no per-run state exists" {
  local payload
  payload="$(build_initial_payload)"
  run in_repo bash "${submit}" submit-initial "${payload}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'state directory is missing'* ]]
  [ ! -f "${gh_log}" ]
}

@test "submit-initial succeeds on a clean, correctly bound worktree and records the review ID" {
  local payload state_dir
  in_repo bash "${guard}" init
  # The state directory path is deterministic from the trusted run identifiers.
  state_dir="${runner_temp}/opencode-review-state.1000.1"
  payload="$(build_initial_payload)"
  run in_repo bash "${submit}" submit-initial "${payload}"
  [ "${status}" -eq 0 ]
  grep -q 'api --method POST repos/octo/repo-name/pulls/42/reviews' "${gh_log}"
  [ "$(cat "${state_dir}/review_id")" = "555" ]
}

@test "submit-initial fails if the worktree is mutated after init" {
  local payload
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  printf 'mutated\n' >"${repo}/tracked.txt"
  run in_repo bash "${submit}" submit-initial "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -f "${gh_log}" ]
}

@test "submit-initial fails when the state is bound to another repository" {
  local payload
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  export GITHUB_REPOSITORY="evil/other-repo"
  run in_repo bash "${submit}" submit-initial "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -f "${gh_log}" ]
}

@test "submit-initial fails when the head SHA moved since init" {
  local payload
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  # Payload commit_id was pinned to the original head at build time; moving the
  # event head SHA is rejected before any write.
  write_event "octo/repo-name" 42 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  run in_repo bash "${submit}" submit-initial "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -f "${gh_log}" ]
}

@test "submit-initial fails when the run identifiers differ from init" {
  local payload
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  export GITHUB_RUN_ID="2000"
  run in_repo bash "${submit}" submit-initial "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -f "${gh_log}" ]
}

@test "build-initial pins commit_id to the trusted head SHA, not a caller value" {
  local payload
  payload="$(build_initial_payload)"
  [ "$(jq -r '.commit_id' "${payload}")" = "${head_sha}" ]
}

@test "update fails when submit-initial has not recorded a review ID this run" {
  local payload
  in_repo bash "${guard}" init
  payload="$(in_repo bash "${submit}" build-update "Updated body")"
  run in_repo bash "${submit}" update "${payload}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'No review ID was recorded'* ]]
}

@test "update targets only the recorded review ID and rejects a caller-supplied one" {
  local payload update_payload
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  in_repo bash "${submit}" submit-initial "${payload}" >/dev/null
  update_payload="$(in_repo bash "${submit}" build-update "Updated body")"

  # The recorded review ID (555) is used; a caller cannot pass a different one
  # (the interface takes only the payload, so an extra argument is rejected).
  run in_repo bash "${submit}" update "${update_payload}" 999
  [ "${status}" -ne 0 ]

  : >"${gh_log}"
  run in_repo bash "${submit}" update "${update_payload}"
  [ "${status}" -eq 0 ]
  grep -q 'api --method PUT repos/octo/repo-name/pulls/42/reviews/555' "${gh_log}"
}

@test "submit-initial rejects a payload whose commit_id does not match the trusted head" {
  local payload tampered
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  tampered="${tmpdir}/tampered.json"
  jq '.commit_id = "cafebabecafebabecafebabecafebabecafebabe"' "${payload}" >"${tampered}"
  run in_repo bash "${submit}" submit-initial "${tampered}"
  [ "${status}" -ne 0 ]
  [ ! -f "${gh_log}" ]
}

@test "submit-initial and update reject caller-supplied repo/PR arguments (old interface)" {
  local payload
  in_repo bash "${guard}" init
  payload="$(build_initial_payload)"
  # The pre-hardening interface passed repo and PR number positionally; those
  # forms must now be rejected so the model cannot redirect the write target.
  run in_repo bash "${submit}" submit-initial "octo/repo-name" 42 "${payload}"
  [ "${status}" -ne 0 ]
  [ ! -f "${gh_log}" ]
}

@test "the submission helper never invokes mutating git or gh commands" {
  local source
  source="$(<"${submit}")"
  if grep -qE 'git (add|commit|push|reset|restore|checkout|switch|clean|stash|merge|rebase|cherry-pick|apply|am)' <<<"${source}"; then
    echo "submit helper references a mutating git command"
    return 1
  fi
  if grep -qE 'gh (pr (comment|merge|close|edit|review)|api --method (DELETE|PATCH))' <<<"${source}"; then
    echo "submit helper references an unexpected gh write"
    return 1
  fi
}

@test "a full clean review submits without any git mutation of the checkout" {
  local payload before after
  in_repo bash "${guard}" init
  before="$(in_repo git status --porcelain=v2 --untracked-files=all)"
  payload="$(build_initial_payload)"
  in_repo bash "${submit}" submit-initial "${payload}" >/dev/null
  after="$(in_repo git status --porcelain=v2 --untracked-files=all)"
  [ "${before}" = "${after}" ]
  [ -z "${after}" ]
}
