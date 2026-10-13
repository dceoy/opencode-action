#!/usr/bin/env bats
# shellcheck disable=SC2016
# Verify that the upstream reviewer CLI adapter uses the authenticated identity.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  wrapper="${repo_root}/.opencode/scripts/pr-review-gh.sh"
  temp_repo="${BATS_TEST_TMPDIR}/repo"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  git init -q "${temp_repo}"
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/gh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf x >> "${GH_CALL_LOG}"
if [[ "$*" == *"--method POST"* ]]; then
  cat > /dev/null
  if [[ "${GH_TOKEN:-}" == ghs_verified ]]; then
    printf '%s' '{"id":101,"user":{"login":"opencode-agent[bot]"}}'
  else
    printf '%s' '{"id":101,"user":{"login":"github-actions[bot]"}}'
  fi
elif [[ "$*" == *"--method DELETE"* ]]; then
  exit 0
else
  printf 'GITHUB_IDENTITY_TOKEN=%s\n' "${GH_TOKEN:-}"
  printf 'ARGUMENTS=%s\n' "$*"
fi
STUB
  chmod +x "${fake_bin}/gh"
}

set_git_candidate() {
  git -C "${temp_repo}" config --local http.https://github.com/.extraheader \
    "AUTHORIZATION: basic $(printf '%s' "x-access-token:$1" | base64 | tr -d '\n')"
}

run_wrapper() {
  run env -u GH_TOKEN -u GITHUB_TOKEN \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" PATH="${fake_bin}:${PATH}" PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    bash -c 'cd "$1"; shift; "$@"' _ "${temp_repo}" bash "${wrapper}" "$@"
}

@test "publishes using verified OpenCode GitHub App token" {
  set_git_candidate ghs_verified
  run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GITHUB_IDENTITY_TOKEN=ghs_verified"* ]]
  [[ "${output}" == *"ARGUMENTS=api repos/dceoy/opencode-action/pulls/127/reviews"* ]]
}

@test "rejects an unverified candidate with default policy" {
  set_git_candidate ghs_wrong
  run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unable to resolve and verify an OpenCode GitHub App token"* ]]
  [[ "${output}" != *"GITHUB_IDENTITY_TOKEN="* ]]
}

@test "explicit workflow-token fallback is permitted" {
  set_git_candidate ghs_wrong
  run env GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" PATH="${fake_bin}:${PATH}" \
    GH_TOKEN=workflow_tok GITHUB_TOKEN=workflow_tok USE_GITHUB_TOKEN=true \
    PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    bash -c 'cd "$1"; shift; "$@"' _ "${temp_repo}" bash "${wrapper}" api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GITHUB_IDENTITY_TOKEN=workflow_tok"* ]]
}

@test "rejects invalid event PR URL before accessing credentials" {
  run env PR_REVIEW_URL=https://github.com/not-valid \
    bash "${wrapper}" api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid PR_REVIEW_URL"* ]]
}

@test "only allows review-oriented gh commands" {
  for subcommand in merge status; do
    run_wrapper pr "${subcommand}" "https://github.com/dceoy/opencode-action/pull/127"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Unsupported gh pr subcommand"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "rejects arbitrary methods endpoints hosts and field mutations before credentials" {
  for args in 'api repos/dceoy/opencode-action/pulls/127 --method DELETE' \
    'api repos/other/repo/pulls/127' 'api graphql' \
    'api repos/dceoy/opencode-action/pulls/127/reviews -f event=APPROVE' \
    'api repos/dceoy/opencode-action/pulls/127 --hostname attacker.example' \
    'api repos/dceoy/opencode-action/pulls/127 --method=POST'; do
    # Intentional whitespace splitting supplies hostile CLI arguments.
    # shellcheck disable=SC2086
    run_wrapper ${args}
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "accepts commit-bound COMMENT JSON and rejects approval wrong SHA and duplicate keys" {
  set_git_candidate ghs_verified
  payload="${BATS_TEST_TMPDIR}/review.json"
  sha=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  export PR_REVIEW_HEAD_SHA="${sha}" PYTHONOPTIMIZE=1
  printf '{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}' "${sha}" > "${payload}"
  run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews --method POST --input "${payload}"
  [ "${status}" -eq 0 ]
  for json in '{"event":"APPROVE","body":"x"}' \
    '{"event":"COMMENT","body":"x","commit_id":"wrong"}' \
    '{"event":"APPROVE","event":"COMMENT","body":"x"}'; do
    printf '%s' "${json}" > "${payload}"
    run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews --method POST --input "${payload}"
    [ "${status}" -ne 0 ]
  done
}
