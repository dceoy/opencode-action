#!/usr/bin/env bash
# Resolve and verify the OpenCode GitHub App installation token from git
# credential configuration so direct `gh api` PR review submissions are
# authored by opencode-agent[bot] instead of falling back to
# github-actions[bot] or a PAT-backed identity.
#
# Intended to be sourced (not executed) from the bundled /review-pr command.
# Never echoes tokens, decoded basic-auth headers, or other credential
# material; only exports resolved tokens into GH_TOKEN/GITHUB_TOKEN.

# The GitHub bot login every OpenCode-authored structured PR review write
# must match once use-github-token is false.
OPENCODE_REVIEW_BOT_LOGIN="opencode-agent[bot]"

# Decode a single "Authorization: Basic <base64>" HTTP extraheader value into
# the bare token, assuming the standard "x-access-token:<token>" basic-auth
# username convention used by GitHub App installation tokens.
#
# This only decodes the wire format; it says nothing about which App or
# installation issued the token. A checkout-persisted GITHUB_TOKEN or a
# PAT can be encoded exactly the same way, which is why
# opencode_verify_app_token_identity below performs an API-level identity
# check before any token this function helps resolve is trusted for a
# structured PR review write.
opencode_decode_extraheader_token() {
  local header="${1:-}" encoded decoded
  [[ -z "${header}" ]] && return 1
  if [[ "${header}" =~ ^[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*[Bb][Aa][Ss][Ii][Cc][[:space:]]+([A-Za-z0-9+/=]+)[[:space:]]*$ ]]; then
    encoded="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  decoded="$(printf '%s' "${encoded}" | base64 --decode 2>/dev/null)" || decoded="$(printf '%s' "${encoded}" | base64 -D 2>/dev/null)" || return 1
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

# Extract the host[:port] segment from a `http.<url>.extraheader` config
# key, stripping the leading "http." / trailing ".extraheader" literal, any
# scheme, any userinfo, and any path. Prints the lowercased host and
# returns 1 if the key does not have the expected shape.
opencode_extraheader_key_host() {
  local key="${1:-}" url host
  [[ -n "${key}" ]] || return 1
  case "${key}" in
    http.*.extraheader) ;;
    *) return 1 ;;
  esac
  url="${key#http.}"
  url="${url%.extraheader}"
  [[ -n "${url}" ]] || return 1
  [[ "${url}" == *://* ]] && url="${url#*://}"
  url="${url##*@}"
  host="${url%%/*}"
  host="${host%%:*}"
  [[ -n "${host}" ]] || return 1
  printf '%s' "${host}" | tr '[:upper:]' '[:lower:]'
}

# Exact, case-insensitive host match against github.com. Deliberately not a
# substring match: "notgithub.com" and "github.com.example.com" must not
# match this.
opencode_is_github_host() {
  [[ "${1:-}" == "github.com" ]]
}

# Resolve *every* candidate App token, one per line, by checking, in order:
# the exact local-config key used by actions/checkout's default
# persist-credentials layout, a URL-matched lookup across all config scopes,
# and every http.*.extraheader key across merged config (including
# includeIf/global-style credential files), first via `--get-regexp` and
# then via `--show-origin --get-regexp` as a fallback for git versions/
# layouts where the former misses an include. Duplicate token values are
# printed only once, at their first (highest-priority) occurrence.
#
# Every line is a *candidate* only. The exact local key actions/checkout
# uses to persist its own GITHUB_TOKEN-derived credential is
# indistinguishable, by format alone, from an OpenCode App token written to
# the same key: both are "x-access-token:<opaque ghs_-prefixed token>"
# basic-auth headers. A workflow can also legitimately have both a
# checkout-persisted credential at the exact key *and* a real OpenCode App
# token from a different (e.g. includeIf/global) source, so callers must not
# stop at the first candidate: verify every candidate via
# opencode_verify_app_token_identity until one verifies. Use
# opencode_require_app_token_for_review, which does this for you.
opencode_resolve_app_token_candidates() {
  local value line key val rest token host

  {
    value="$(git config --local --get http.https://github.com/.extraheader 2>/dev/null || true)"
    if token="$(opencode_decode_extraheader_token "${value}")"; then
      printf '%s\n' "${token}"
    fi

    value="$(git config --get-urlmatch http.extraheader https://github.com/ 2>/dev/null || true)"
    if token="$(opencode_decode_extraheader_token "${value}")"; then
      printf '%s\n' "${token}"
    fi

    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      key="${line%% *}"
      host="$(opencode_extraheader_key_host "${key}")" || continue
      opencode_is_github_host "${host}" || continue
      val="${line#* }"
      if token="$(opencode_decode_extraheader_token "${val}")"; then
        printf '%s\n' "${token}"
      fi
    done < <(git config --get-regexp 'http\..*\.extraheader' 2>/dev/null || true)

    while IFS=$'\t' read -r _ rest; do
      [[ -z "${rest}" ]] && continue
      key="${rest%% *}"
      host="$(opencode_extraheader_key_host "${key}")" || continue
      opencode_is_github_host "${host}" || continue
      val="${rest#* }"
      if token="$(opencode_decode_extraheader_token "${val}")"; then
        printf '%s\n' "${token}"
      fi
    done < <(git config --show-origin --get-regexp 'http\..*\.extraheader' 2>/dev/null || true)
  } | awk '!seen[$0]++'
}

# Resolve a single *candidate* App token: the first result from
# opencode_resolve_app_token_candidates. Kept for callers that only want one
# best-effort candidate without verifying it (reads via
# opencode_prepare_gh_token). opencode_require_app_token_for_review checks
# every candidate via opencode_resolve_app_token_candidates, not just this
# first one, since the first candidate found is not necessarily the one
# that verifies.
opencode_resolve_app_token() {
  local token
  token="$(opencode_resolve_app_token_candidates | head -n1)"
  [[ -n "${token}" ]] || return 1
  printf '%s' "${token}"
}

# Best-effort resolution: exports GH_TOKEN/GITHUB_TOKEN when a *candidate*
# App token is found, without verifying its identity. Only safe for reads
# (gh pr view, gh pr diff); never use this to gate a structured PR review
# write.
#
# $1: the workflow's use-github-token input value ("true"/"false"/empty).
#     When "true", the caller has explicitly opted into using its own
#     GH_TOKEN/GITHUB_TOKEN and this is a no-op: it never overwrites that
#     token with an unverified git-config candidate (for example a
#     checkout-persisted credential at the same extraheader key an App
#     token would use), so the explicit fallback that
#     opencode_require_app_token_for_review relies on later is never
#     silently replaced before the write gate runs.
#
# Returns 1 without touching either variable when use-github-token is
# "true", or when no candidate is found.
opencode_prepare_gh_token() {
  local use_github_token="${1:-false}" token
  [[ "${use_github_token}" == "true" ]] && return 1
  token="$(opencode_resolve_app_token)" || return 1
  [[ -n "${token}" ]] || return 1
  export GH_TOKEN="${token}"
  export GITHUB_TOKEN="${token}"
  return 0
}

# Verify that a candidate token will author GitHub API writes as
# opencode-agent[bot]. Creates a throwaway PENDING pull request review (no
# comments, no body, no `event`) with the candidate token, reads
# `.user.login` off the response, and immediately deletes the pending
# review regardless of the outcome.
#
# LIMITATION: GitHub does not expose a read-only "whoami" endpoint for
# GitHub App installation tokens. `GET /user` requires user-to-server auth
# and returns 403 for every installation token alike, so it cannot tell an
# OpenCode App token apart from the workflow's own GITHUB_TOKEN or a
# PAT-backed credential. A pending PR review is the safest available
# alternative: it is not visible to anyone but its own author until
# submitted, so a failed or mismatched check never publishes anything to
# the pull request. It is still a real API write (create + delete), not a
# true read-only check.
#
# $1: "<owner>/<repo>"
# $2: pull request number
# $3: token to verify
opencode_verify_app_token_identity() {
  local repo="${1:-}" pr_number="${2:-}" token="${3:-}"
  local probe_response probe_id probe_login probe_stderr probe_rc

  [[ -n "${repo}" && -n "${pr_number}" && -n "${token}" ]] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  probe_stderr="$(mktemp)"
  probe_response="$(
    printf '{}' | GH_TOKEN="${token}" GITHUB_TOKEN="${token}" gh api \
      --method POST \
      "repos/${repo}/pulls/${pr_number}/reviews" \
      --input - 2>"${probe_stderr}"
  )"
  probe_rc=$?
  if [[ "${probe_rc}" -ne 0 ]]; then
    if [[ -s "${probe_stderr}" ]]; then
      echo "::warning::Identity-verification probe request failed for a candidate token (this is a transient/API error, not necessarily an identity mismatch): $(tr '\n' ' ' <"${probe_stderr}")" >&2
    fi
    rm -f "${probe_stderr}"
    return 1
  fi
  rm -f "${probe_stderr}"

  probe_id="$(jq -r '.id // empty' <<<"${probe_response}" 2>/dev/null)"
  probe_login="$(jq -r '.user.login // empty' <<<"${probe_response}" 2>/dev/null)"

  if [[ -n "${probe_id}" ]]; then
    GH_TOKEN="${token}" GITHUB_TOKEN="${token}" gh api \
      --method DELETE \
      "repos/${repo}/pulls/${pr_number}/reviews/${probe_id}" \
      >/dev/null 2>&1 \
      || echo "::warning::Failed to delete the throwaway identity-verification pending review (id ${probe_id}); it is never submitted and is only visible to the token's own author, so it is safe to ignore or delete manually." >&2
  fi

  [[ -n "${probe_login}" && "${probe_login}" == "${OPENCODE_REVIEW_BOT_LOGIN}" ]]
}

# Policy gate for structured PR review submission (create/update/retry).
# $1: the workflow's use-github-token input value ("true"/"false"/empty).
# $2: "<owner>/<repo>", required to verify a candidate token.
# $3: pull request number, required to verify a candidate token.
#
# - use-github-token=true: succeed without inspecting candidates, preserving
#   the caller's GH_TOKEN/GITHUB_TOKEN as the exclusive credential boundary.
# - use-github-token!=true: every candidate App token
#   (opencode_resolve_app_token_candidates) is tried in order until one
#   verifies as opencode-agent[bot], then exported. A workflow can have both a
#   checkout-persisted credential at the highest-priority key and a real
#   OpenCode App token from a lower-priority source, so an unverified
#   earlier candidate must not stop the search.
# - No candidate verifies (none found, every one mismatched, or $2/$3
#   missing so verification cannot run): never export an unverified
#   candidate.
# - No verified App token, use-github-token=true: succeed without
#   exporting, so the caller's existing GH_TOKEN/GITHUB_TOKEN (workflow
#   token) is used as an explicitly opted-in fallback.
# - No verified App token, use-github-token!=true: fail fast. Never
#   silently submit a structured review under the workflow's
#   GH_TOKEN/GITHUB_TOKEN or an unverified candidate, since either could
#   make the review appear as github-actions[bot] or another identity
#   instead of opencode-agent[bot].
opencode_require_app_token_for_review() {
  local use_github_token="${1:-false}" repo="${2:-}" pr_number="${3:-}"
  local token tried=0

  [[ "${use_github_token}" == "true" ]] && return 0

  while IFS= read -r token; do
    [[ -n "${token}" ]] || continue
    tried=$((tried + 1))
    if opencode_verify_app_token_identity "${repo}" "${pr_number}" "${token}"; then
      export GH_TOKEN="${token}"
      export GITHUB_TOKEN="${token}"
      return 0
    fi
  done < <(opencode_resolve_app_token_candidates)

  if [[ "${tried}" -gt 0 ]]; then
    echo "::warning::Found ${tried} candidate OpenCode App token(s) in git credential configuration, but none verified as ${OPENCODE_REVIEW_BOT_LOGIN}; ignoring them instead of risking a review authored by the wrong identity." >&2
  else
    echo "::warning::No OpenCode App token candidates found in git credential configuration (checked local, urlmatch, and includeIf/global extraheader sources)." >&2
  fi

  echo "::error::Unable to resolve and verify an OpenCode GitHub App token that authors GitHub API writes as ${OPENCODE_REVIEW_BOT_LOGIN} (checked local, urlmatch, and includeIf/global extraheader sources, then verified with a pending-review identity probe). Refusing to submit the PR review with a fallback GH_TOKEN/GITHUB_TOKEN because that would make the review appear under the wrong identity instead of ${OPENCODE_REVIEW_BOT_LOGIN}. Set use-github-token: true to explicitly allow that fallback." >&2
  return 1
}
