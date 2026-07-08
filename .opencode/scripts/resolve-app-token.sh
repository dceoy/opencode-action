#!/usr/bin/env bash
# Resolve the OpenCode GitHub App installation token from git credential
# configuration so direct `gh api` PR review submissions are authored by
# opencode-agent[bot] instead of falling back to github-actions[bot].
#
# Intended to be sourced (not executed) from the bundled /review-pr command.
# Never echoes tokens, decoded basic-auth headers, or other credential
# material; only exports resolved tokens into GH_TOKEN/GITHUB_TOKEN.

# Decode a single "Authorization: Basic <base64>" HTTP extraheader value into
# the bare token, assuming the standard "x-access-token:<token>" basic-auth
# username convention used by GitHub App installation tokens.
opencode_decode_extraheader_token() {
  local header="${1:-}" encoded decoded
  [[ -z "${header}" ]] && return 1
  if [[ "${header}" =~ ^[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*[Bb][Aa][Ss][Ii][Cc][[:space:]]+([A-Za-z0-9+/=]+)[[:space:]]*$ ]]; then
    encoded="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  decoded="$(printf '%s' "${encoded}" | base64 --decode 2>/dev/null)" || return 1
  case "${decoded}" in
    x-access-token:?*)
      printf '%s' "${decoded#x-access-token:}"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve the App token by checking, in order: the exact local-config key
# used by actions/checkout's default persist-credentials layout, a
# URL-matched lookup across all config scopes, and every http.*.extraheader
# key across merged config (including includeIf/global-style credential
# files), first via `--get-regexp` and then via `--show-origin --get-regexp`
# as a fallback for git versions/layouts where the former misses an include.
opencode_resolve_app_token() {
  local value line key val rest token

  value="$(git config --local --get http.https://github.com/.extraheader 2>/dev/null || true)"
  if token="$(opencode_decode_extraheader_token "${value}")"; then
    printf '%s' "${token}"
    return 0
  fi

  value="$(git config --get-urlmatch http.extraheader https://github.com/ 2>/dev/null || true)"
  if token="$(opencode_decode_extraheader_token "${value}")"; then
    printf '%s' "${token}"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    key="${line%% *}"
    [[ "${key}" == *github.com* ]] || continue
    val="${line#* }"
    if token="$(opencode_decode_extraheader_token "${val}")"; then
      printf '%s' "${token}"
      return 0
    fi
  done < <(git config --get-regexp 'http\..*\.extraheader' 2>/dev/null || true)

  while IFS=$'\t' read -r _ rest; do
    [[ -z "${rest}" ]] && continue
    key="${rest%% *}"
    [[ "${key}" == *github.com* ]] || continue
    val="${rest#* }"
    if token="$(opencode_decode_extraheader_token "${val}")"; then
      printf '%s' "${token}"
      return 0
    fi
  done < <(git config --show-origin --get-regexp 'http\..*\.extraheader' 2>/dev/null || true)

  return 1
}

# Best-effort resolution: exports GH_TOKEN/GITHUB_TOKEN when an App token is
# found. Returns 1 without touching either variable when none is found.
opencode_prepare_gh_token() {
  local token
  token="$(opencode_resolve_app_token)" || return 1
  [[ -n "${token}" ]] || return 1
  export GH_TOKEN="${token}"
  export GITHUB_TOKEN="${token}"
  return 0
}

# Policy gate for structured PR review submission (create/update/retry).
# $1: the workflow's use-github-token input value ("true"/"false"/empty).
#
# - App token found: export it and succeed, regardless of use-github-token.
# - No App token, use-github-token=true: succeed without exporting, so the
#   caller's existing GH_TOKEN/GITHUB_TOKEN (workflow token) is used as an
#   explicitly opted-in fallback.
# - No App token, use-github-token!=true: fail fast. Never silently submit a
#   structured review under the workflow's GH_TOKEN/GITHUB_TOKEN, since that
#   would make the review appear as github-actions[bot].
opencode_require_app_token_for_review() {
  local use_github_token="${1:-false}"

  if opencode_prepare_gh_token; then
    return 0
  fi

  if [[ "${use_github_token}" == "true" ]]; then
    return 0
  fi

  echo "::error::Unable to resolve the OpenCode GitHub App token from git credential configuration (checked local, urlmatch, and includeIf/global extraheader sources). Refusing to submit the PR review with a fallback GH_TOKEN/GITHUB_TOKEN because that would make the review appear as github-actions[bot] instead of opencode-agent[bot]. Set use-github-token: true to explicitly allow that fallback." >&2
  return 1
}
