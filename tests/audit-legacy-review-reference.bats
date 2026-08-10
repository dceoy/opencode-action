#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
}

@test "legacy stale-head helper has no callers before removal" {
  local symbol refs
  symbol='opencode_assert_pr_head_''unchanged'
  mapfile -t refs < <(git -C "${repo_root}" grep -n -F "${symbol}" -- ':!tests/audit-legacy-review-reference.bats')

  [ "${#refs[@]}" -eq 1 ] || {
    printf 'expected only the legacy definition, found:\n%s\n' "${refs[*]}"
    return 1
  }
  [[ "${refs[0]}" == .opencode/scripts/resolve-app-token.sh:* ]]
}
