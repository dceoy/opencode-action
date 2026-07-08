#!/usr/bin/env bats
# Regression tests for .opencode/scripts/resolve-app-token.sh: token
# candidate extraction from local, urlmatch, and includeIf/global-style git
# extraheader configurations; exact github.com host matching; opencode-agent
# [bot] identity verification via a stubbed `gh`; fail-fast behavior with no
# verified token; and no fallback to GH_TOKEN/GITHUB_TOKEN for structured PR
# review submission.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  lib="${repo_root}/.opencode/scripts/resolve-app-token.sh"
}

mk_repo() {
  local d
  d="$(mktemp -d "${BATS_TEST_TMPDIR}/repo.XXXXXX")"
  git init -q "${d}"
  printf '%s' "${d}"
}

encode_header() { printf '%s' "AUTHORIZATION: basic $(printf '%s' "x-access-token:$1" | base64 -w0)"; }

# Writes a fake `gh` onto a fresh directory that answers the two `gh api`
# shapes opencode_verify_app_token_identity issues: a POST to create a
# pending review (answered with the given login) and a DELETE to remove it
# (answered with success). Never echoes its arguments or stdin.
mk_gh_stub() {
  local dir="$1" login="$2"
  mkdir -p "${dir}"
  cat > "${dir}/gh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
joined="\$*"
if [[ "\${joined}" == *"--method POST"* ]]; then
  cat >/dev/null
  printf '{"id": 4242, "user": {"login": "${login}"}}'
  exit 0
fi
if [[ "\${joined}" == *"--method DELETE"* ]]; then
  exit 0
fi
echo "gh stub: unexpected invocation" >&2
exit 1
STUB
  chmod +x "${dir}/gh"
}

@test "resolves a token candidate from local extraheader key" {
  local repo
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_local_tok)"

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_local_tok" ]
}

@test "resolves a token candidate via --get-urlmatch when the exact key form misses" {
  local repo exact
  repo="$(mk_repo)"
  # No trailing slash on the key, so the exact local-config lookup misses and
  # resolution must fall back to --get-urlmatch.
  git -C "${repo}" config --local http.https://github.com.extraheader "$(encode_header ghs_urlmatch_tok)"

  exact="$(git -C "${repo}" config --local --get http.https://github.com/.extraheader 2>/dev/null || true)"
  [ -z "${exact}" ]

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_urlmatch_tok" ]
}

@test "resolves a token candidate from includeIf/global-style extraheader config" {
  local repo creddir local_value
  repo="$(mk_repo)"
  creddir="$(mktemp -d "${BATS_TEST_TMPDIR}/cred.XXXXXX")"
  {
    echo '[http "https://github.com/"]'
    echo "	extraheader = $(encode_header ghs_include_tok)"
  } > "${creddir}/extra.gitconfig"
  git -C "${repo}" config --local include.path "${creddir}/extra.gitconfig"

  # The include-based header must not be visible via --local, so this
  # exercises the get-regexp/show-origin fallback rather than the earlier
  # exact-key or urlmatch lookups.
  local_value="$(git -C "${repo}" config --local --get http.https://github.com/.extraheader 2>/dev/null || true)"
  [ -z "${local_value}" ]

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_include_tok" ]
}

@test "does not treat a notgithub.com extraheader as a GitHub host" {
  local repo
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://notgithub.com/.extraheader "$(encode_header ghs_wrong_host_tok)"

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -ne 0 ]
}

@test "does not treat a github.com.example.com extraheader as a GitHub host" {
  local repo
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com.example.com/.extraheader "$(encode_header ghs_wrong_host_tok)"

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -ne 0 ]
}

@test "resolves the real github.com token even when a look-alike host extraheader is also present" {
  local repo
  repo="$(mk_repo)"
  git -C "${repo}" config --local --add http.https://notgithub.com/.extraheader "$(encode_header ghs_wrong_host_tok)"
  git -C "${repo}" config --local --add http.https://github.com.example.com/.extraheader "$(encode_header ghs_wrong_host_tok_2)"
  git -C "${repo}" config --local --add http.https://github.com/some/path.extraheader "$(encode_header ghs_real_tok)"

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_real_tok" ]
}

@test "does not fall back to GH_TOKEN/GITHUB_TOKEN when no App token candidate is configured" {
  local repo
  repo="$(mk_repo)"

  run bash -c "cd '${repo}' && source '${lib}' && GH_TOKEN=dummy GITHUB_TOKEN=dummy opencode_resolve_app_token"

  [ "${status}" -ne 0 ]
}

@test "fails fast with no App token candidate and explains the identity risk" {
  local repo
  repo="$(mk_repo)"

  run bash -c "cd '${repo}' && source '${lib}' && unset GH_TOKEN GITHUB_TOKEN; opencode_require_app_token_for_review false"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *'opencode-agent[bot]'* ]]
}

@test "allows the explicit use-github-token=true fallback when no App token candidate is configured" {
  local repo
  repo="$(mk_repo)"

  run bash -c "cd '${repo}' && source '${lib}' && unset GH_TOKEN GITHUB_TOKEN; opencode_require_app_token_for_review true"

  [ "${status}" -eq 0 ]
}

@test "verifies an OpenCode App token candidate and exports it as GH_TOKEN/GITHUB_TOKEN" {
  local repo stub
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_local_tok)"
  stub="${BATS_TEST_TMPDIR}/bin"
  mk_gh_stub "${stub}" 'opencode-agent[bot]'

  run env PATH="${stub}:${PATH}" bash -c "
    cd '${repo}'
    source '${lib}'
    unset GH_TOKEN GITHUB_TOKEN
    opencode_require_app_token_for_review false owner/repo 7
    rc=\$?
    printf 'rc=%s gh=%s gt=%s' \"\${rc}\" \"\${GH_TOKEN:-unset}\" \"\${GITHUB_TOKEN:-unset}\"
  "

  [ "${status}" -eq 0 ]
  [ "${output}" = "rc=0 gh=ghs_local_tok gt=ghs_local_tok" ]
}

@test "rejects a checkout-style extraheader token that verifies as github-actions[bot]" {
  local repo stub
  repo="$(mk_repo)"
  # actions/checkout persists its own GITHUB_TOKEN-derived credential at
  # exactly this key, in the exact same shape as a real OpenCode App token.
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_checkout_tok)"
  stub="${BATS_TEST_TMPDIR}/bin"
  mk_gh_stub "${stub}" 'github-actions[bot]'

  run env PATH="${stub}:${PATH}" bash -c "
    cd '${repo}'
    source '${lib}'
    unset GH_TOKEN GITHUB_TOKEN
    opencode_require_app_token_for_review false owner/repo 7
    rc=\$?
    printf 'rc=%s gh=%s gt=%s' \"\${rc}\" \"\${GH_TOKEN:-unset}\" \"\${GITHUB_TOKEN:-unset}\"
  "

  [ "${status}" -eq 0 ]
  [[ "${output}" == *'rc=1 gh=unset gt=unset'* ]]
  [[ "${output}" != *'ghs_checkout_tok'* ]]
}

@test "rejects a PAT-like token that verifies as a human account" {
  local repo stub
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghp_pat_tok)"
  stub="${BATS_TEST_TMPDIR}/bin"
  mk_gh_stub "${stub}" 'some-human-user'

  run env PATH="${stub}:${PATH}" bash -c "
    cd '${repo}'
    source '${lib}'
    unset GH_TOKEN GITHUB_TOKEN
    opencode_require_app_token_for_review false owner/repo 7
    rc=\$?
    printf 'rc=%s gh=%s gt=%s' \"\${rc}\" \"\${GH_TOKEN:-unset}\" \"\${GITHUB_TOKEN:-unset}\"
  "

  [ "${status}" -eq 0 ]
  [[ "${output}" == *'rc=1 gh=unset gt=unset'* ]]
  [[ "${output}" != *'ghp_pat_tok'* ]]
}

@test "does not fall back to GH_TOKEN/GITHUB_TOKEN when use-github-token is false and verification fails" {
  local repo stub
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_checkout_tok)"
  stub="${BATS_TEST_TMPDIR}/bin"
  mk_gh_stub "${stub}" 'github-actions[bot]'

  run env PATH="${stub}:${PATH}" bash -c "
    cd '${repo}'
    source '${lib}'
    GH_TOKEN=dummy GITHUB_TOKEN=dummy
    opencode_require_app_token_for_review false owner/repo 7
  "

  [ "${status}" -ne 0 ]
}

@test "allows the explicit use-github-token=true fallback when a candidate token fails verification" {
  local repo stub
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_checkout_tok)"
  stub="${BATS_TEST_TMPDIR}/bin"
  mk_gh_stub "${stub}" 'github-actions[bot]'

  run env PATH="${stub}:${PATH}" bash -c "
    cd '${repo}'
    source '${lib}'
    unset GH_TOKEN GITHUB_TOKEN
    opencode_require_app_token_for_review true owner/repo 7
  "

  [ "${status}" -eq 0 ]
}
