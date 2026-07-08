#!/usr/bin/env bats
# Regression tests for .opencode/scripts/resolve-app-token.sh: token
# extraction from local, urlmatch, and includeIf/global-style git extraheader
# configurations; fail-fast behavior with no token; and no fallback to
# GH_TOKEN/GITHUB_TOKEN for structured PR review submission.

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

@test "resolves token from local extraheader key" {
  local repo
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_local_tok)"

  run bash -c "cd '${repo}' && source '${lib}' && opencode_resolve_app_token"

  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_local_tok" ]
}

@test "resolves token via --get-urlmatch when the exact key form misses" {
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

@test "resolves token from includeIf/global-style extraheader config" {
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

@test "does not fall back to GH_TOKEN/GITHUB_TOKEN when no App token is configured" {
  local repo
  repo="$(mk_repo)"

  run bash -c "cd '${repo}' && source '${lib}' && GH_TOKEN=dummy GITHUB_TOKEN=dummy opencode_resolve_app_token"

  [ "${status}" -ne 0 ]
}

@test "fails fast with no App token and explains the github-actions[bot] risk" {
  local repo
  repo="$(mk_repo)"

  run bash -c "cd '${repo}' && source '${lib}' && unset GH_TOKEN GITHUB_TOKEN; opencode_require_app_token_for_review false"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *'github-actions[bot]'* ]]
}

@test "allows the explicit use-github-token=true fallback when no App token is configured" {
  local repo
  repo="$(mk_repo)"

  run bash -c "cd '${repo}' && source '${lib}' && unset GH_TOKEN GITHUB_TOKEN; opencode_require_app_token_for_review true"

  [ "${status}" -eq 0 ]
}

@test "exports the resolved App token as GH_TOKEN and GITHUB_TOKEN regardless of the use-github-token flag" {
  local repo
  repo="$(mk_repo)"
  git -C "${repo}" config --local http.https://github.com/.extraheader "$(encode_header ghs_local_tok)"

  run bash -c "
    cd '${repo}'
    source '${lib}'
    unset GH_TOKEN GITHUB_TOKEN
    opencode_require_app_token_for_review false
    printf '%s %s' \"\${GH_TOKEN:-}\" \"\${GITHUB_TOKEN:-}\"
  "

  [ "${status}" -eq 0 ]
  [ "${output}" = "ghs_local_tok ghs_local_tok" ]
}
