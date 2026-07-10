#!/usr/bin/env bats

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
}

snapshot() {
  (cd "${repo}" && "${guard}" snapshot)
}

@test "a clean unchanged worktree passes the review guard" {
  local state
  state="$(snapshot)"

  run bash -c "cd '${repo}' && '${guard}' verify '${state}'"

  [ "${status}" -eq 0 ]
}

@test "a generated untracked file fails the review guard" {
  local state
  state="$(snapshot)"
  mkdir -p "${repo}/github_conf"
  printf '{}\n' >"${repo}/github_conf/branch_protection_rules.json"

  run bash -c "cd '${repo}' && '${guard}' verify '${state}'"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *'::error::/review-pr detected a repository worktree mutation'* ]]
  [[ "${output}" == *'github_conf/branch_protection_rules.json'* ]]
}

@test "a tracked-file modification fails the review guard without cleanup commands" {
  local state source
  state="$(snapshot)"
  printf 'changed\n' >"${repo}/tracked.txt"

  run bash -c "cd '${repo}' && '${guard}' verify '${state}'"

  [ "${status}" -ne 0 ]
  grep -qx 'changed' "${repo}/tracked.txt"
  source="$(<"${guard}")"
  if grep -qE 'git (reset|clean|restore|commit|push)' <<<"${source}"; then
    echo "guard must not attempt cleanup or Git history mutation"
    return 1
  fi
}
