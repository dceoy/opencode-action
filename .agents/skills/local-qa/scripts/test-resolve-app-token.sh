#!/usr/bin/env bash
# shellcheck disable=SC1090
# Regression tests for .opencode/scripts/resolve-app-token.sh: token
# extraction from local, urlmatch, and includeIf/global-style git extraheader
# configurations; fail-fast behavior with no token; and no fallback to
# GH_TOKEN/GITHUB_TOKEN for structured PR review submission.
set -uo pipefail
repo_root="$(git rev-parse --show-toplevel)"
lib="${repo_root}/.opencode/scripts/resolve-app-token.sh"

fail=0
tmpdirs=()

cleanup() {
  rm -f "${err_file:-}"
  for d in "${tmpdirs[@]}"; do
    rm -rf "${d}"
  done
}
trap cleanup EXIT

ok() { echo "ok - $1"; }
ng() {
  echo "not ok - $1" >&2
  fail=1
}

expect_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    ok "${desc}"
  else
    ng "${desc}: got '${actual}'"
  fi
}

mk_repo() {
  local d
  d="$(mktemp -d)"
  tmpdirs+=("${d}")
  git init -q "${d}"
  printf '%s' "${d}"
}

encode_header() { printf '%s' "AUTHORIZATION: basic $(printf '%s' "x-access-token:$1" | base64 -w0)"; }

# 1. Exact local-config key (actions/checkout's default layout).
repo_local="$(mk_repo)"
git -C "${repo_local}" config --local http.https://github.com/.extraheader "$(encode_header ghs_local_tok)"
token="$(cd "${repo_local}" && source "${lib}" && opencode_resolve_app_token)"
expect_eq "resolves token from local extraheader key" "ghs_local_tok" "${token}"

# 2. Header reachable only via --get-urlmatch (no trailing slash on the key).
repo_urlmatch="$(mk_repo)"
git -C "${repo_urlmatch}" config --local http.https://github.com.extraheader "$(encode_header ghs_urlmatch_tok)"
exact="$(git -C "${repo_urlmatch}" config --local --get http.https://github.com/.extraheader 2>/dev/null || true)"
if [[ -n "${exact}" ]]; then
  ng "test setup invariant broken: exact key unexpectedly present"
fi
token="$(cd "${repo_urlmatch}" && source "${lib}" && opencode_resolve_app_token)"
expect_eq "resolves token via --get-urlmatch when the exact key form misses" "ghs_urlmatch_tok" "${token}"

# 3. includeIf/global-style credential file, not present in the repo's own local config.
repo_include="$(mk_repo)"
creddir="$(mktemp -d)"
tmpdirs+=("${creddir}")
{
  echo '[http "https://github.com/"]'
  echo "	extraheader = $(encode_header ghs_include_tok)"
} > "${creddir}/extra.gitconfig"
git -C "${repo_include}" config --local include.path "${creddir}/extra.gitconfig"
local_value="$(git -C "${repo_include}" config --local --get http.https://github.com/.extraheader 2>/dev/null || true)"
if [[ -n "${local_value}" ]]; then
  ng "test setup invariant broken: include-based header visible via --local"
fi
token="$(cd "${repo_include}" && source "${lib}" && opencode_resolve_app_token)"
expect_eq "resolves token from includeIf/global-style extraheader config" "ghs_include_tok" "${token}"

# 4. No token configured anywhere; GH_TOKEN/GITHUB_TOKEN set in the environment
#    must never be treated as the App token.
repo_empty="$(mk_repo)"
if token="$(cd "${repo_empty}" && source "${lib}" && GH_TOKEN=dummy GITHUB_TOKEN=dummy opencode_resolve_app_token)"; then
  ng "opencode_resolve_app_token unexpectedly succeeded from env fallback: got '${token}'"
else
  ok "does not fall back to GH_TOKEN/GITHUB_TOKEN when no App token is configured"
fi

# 5. Fail-fast policy: use-github-token=false with no App token must fail and
#    explain the github-actions[bot] risk; use-github-token=true must allow
#    the fallback.
err_file="$(mktemp)"
if bash -c "cd '${repo_empty}' && source '${lib}' && unset GH_TOKEN GITHUB_TOKEN; opencode_require_app_token_for_review false" 2>"${err_file}"; then
  ng "opencode_require_app_token_for_review(false) unexpectedly succeeded with no App token"
elif grep -qi 'github-actions\[bot\]' "${err_file}"; then
  ok "fails fast with no App token and explains the github-actions[bot] risk"
else
  ng "fail-fast error message missing github-actions[bot] explanation"
fi

if bash -c "cd '${repo_empty}' && source '${lib}' && unset GH_TOKEN GITHUB_TOKEN; opencode_require_app_token_for_review true"; then
  ok "allows the explicit use-github-token=true fallback with no App token"
else
  ng "opencode_require_app_token_for_review(true) unexpectedly failed with no App token"
fi

# 6. When an App token is available, opencode_require_app_token_for_review
#    exports it as both GH_TOKEN and GITHUB_TOKEN regardless of the flag.
export_check="$(bash -c "
  cd '${repo_local}'
  source '${lib}'
  unset GH_TOKEN GITHUB_TOKEN
  if opencode_require_app_token_for_review false; then
    if [[ \"\${GH_TOKEN:-}\" == 'ghs_local_tok' && \"\${GITHUB_TOKEN:-}\" == 'ghs_local_tok' ]]; then
      echo match
    fi
  fi
")"
expect_eq "exports the resolved App token as GH_TOKEN and GITHUB_TOKEN" "match" "${export_check}"

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "OK: resolve-app-token.sh regression tests passed."
