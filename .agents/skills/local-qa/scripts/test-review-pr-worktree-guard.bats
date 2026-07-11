#!/usr/bin/env bats
# Exercises the /review-pr worktree guard: the fail-closed pristine-checkout
# precheck, and the per-run state directory (init/verify) that binds the
# snapshot to the trusted GitHub Actions run context.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  guard="${repo_root}/.opencode/scripts/review-pr-worktree-guard.sh"

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

  event_path="${BATS_TEST_TMPDIR}/event.json"
  write_event "octo/repo-name" 42 "${head_sha}"

  export GITHUB_REPOSITORY="octo/repo-name"
  export GITHUB_EVENT_PATH="${event_path}"
  export GITHUB_RUN_ID="1000"
  export GITHUB_RUN_ATTEMPT="1"
  export RUNNER_TEMP="${runner_temp}"
}

write_event() {
  jq -n --arg n "$2" --arg sha "$3" \
    '{pull_request: {number: ($n | tonumber), head: {sha: $sha}}}' >"${event_path}"
}

guard() {
  (cd "${repo}" && "${guard}" "$@")
}

# --- precheck --------------------------------------------------------------

@test "precheck passes on a pristine checkout" {
  run guard precheck
  [ "${status}" -eq 0 ]
}

@test "precheck rejects a pre-existing untracked file" {
  printf 'junk\n' >"${repo}/leftover.txt"
  run guard precheck
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'requires a pristine checkout'* ]]
  [ -f "${repo}/leftover.txt" ]
}

@test "precheck rejects a pre-existing tracked modification" {
  printf 'changed\n' >"${repo}/tracked.txt"
  run guard precheck
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'requires a pristine checkout'* ]]
  grep -qx 'changed' "${repo}/tracked.txt"
}

@test "precheck rejects a pre-existing staged change" {
  printf 'staged\n' >"${repo}/new-staged.txt"
  git -C "${repo}" add new-staged.txt
  run guard precheck
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'requires a pristine checkout'* ]]
}

@test "precheck never runs cleanup or history-mutating git commands" {
  local source
  source="$(<"${guard}")"
  if grep -qE 'git (reset|clean|restore|stash|commit|push|checkout|switch)' <<<"${source}"; then
    echo "guard must not attempt cleanup or Git history mutation"
    return 1
  fi
}

# --- init / verify ---------------------------------------------------------

@test "init then verify passes on an unchanged worktree" {
  run guard init
  [ "${status}" -eq 0 ]
  [ -d "${output}" ]

  run guard verify
  [ "${status}" -eq 0 ]
}

@test "init creates the state directory with 0700 permissions" {
  local state_dir mode
  state_dir="$(guard init)"
  mode="$(stat -c '%a' "${state_dir}" 2>/dev/null || stat -f '%Lp' "${state_dir}")"
  [ "${mode}" = "700" ]
}

@test "init refuses to re-initialize within the same run attempt" {
  guard init
  run guard init
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'already exists'* ]]
}

@test "verify fails when the worktree is mutated after init" {
  guard init
  printf 'mutated\n' >"${repo}/tracked.txt"
  run guard verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'detected a repository worktree mutation'* ]]
}

@test "verify fails when a new untracked file appears after init" {
  guard init
  printf '{}\n' >"${repo}/generated.json"
  run guard verify
  [ "${status}" -ne 0 ]
}

@test "verify fails when the state was created for another repository" {
  guard init
  export GITHUB_REPOSITORY="evil/other-repo"
  run guard verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'does not match the current run'* ]]
}

@test "verify fails when the state was created for another PR" {
  guard init
  write_event "octo/repo-name" 99 "${head_sha}"
  run guard verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'does not match the current event'* ]]
}

@test "verify fails when the head SHA moved since init" {
  guard init
  write_event "octo/repo-name" 42 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  run guard verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'stale'* ]]
}

@test "verify fails when the state is from another run" {
  guard init
  export GITHUB_RUN_ID="2000"
  run guard verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'state directory is missing'* ]]
}

@test "verify fails when no state directory exists" {
  run guard verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'state directory is missing'* ]]
}
