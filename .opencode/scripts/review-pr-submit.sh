#!/usr/bin/env bash
# The only /review-pr helper permitted to write to GitHub. It derives every
# write target (repository, PR number, commit) from the trusted GitHub Actions
# context — never from a model/agent-supplied argument — re-verifies the
# worktree invariant and the per-run state binding authoritatively BEFORE it
# acquires any write-capable credential, and never touches the checkout.
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

# Trusted context and authoritative worktree/binding verification live in the
# worktree guard; source it (from its action-installed $HOME path only, never a
# repository-relative one) so this write helper re-runs the exact same checks
# rather than trusting the orchestrator's earlier result.
guard_lib="${HOME}/.config/opencode/scripts/review-pr-worktree-guard.sh"
[[ -f "${guard_lib}" ]] || fail "OpenCode review worktree guard is unavailable."
# shellcheck source=/dev/null
source "${guard_lib}"

load_token_resolver() {
  [[ -f "${HOME}/.config/opencode/scripts/resolve-app-token.sh" ]] || fail "OpenCode App token resolver script is unavailable."
  # shellcheck source=/dev/null
  source "${HOME}/.config/opencode/scripts/resolve-app-token.sh"
}

valid_payload() { jq -e "$1" "$2" >/dev/null 2>&1; }

# Resolve and validate the trusted write target once. Aborts the whole helper
# if any trusted identifier is unavailable or malformed.
resolve_trusted_target() {
  repo="$(opencode_review_context_repo)" || fail "Could not resolve the repository from the trusted GITHUB_REPOSITORY context."
  pr_number="$(opencode_review_context_pr_number)" || fail "Could not resolve the pull request number from the trusted event payload."
  head_sha="$(opencode_review_context_head_sha)" || fail "Could not resolve the head commit SHA from the trusted event payload."
  state_dir="$(opencode_review_state_dir)" || fail "Could not resolve the per-run state directory (missing GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT)."
}

# Re-verify, authoritatively and independently, immediately before any write.
verify_state_or_fail() {
  opencode_review_verify_state || fail "Refusing to submit: the worktree changed since the review began, or the per-run state binding does not match this run/PR/commit."
}

operation="${1:-}"

case "${operation}" in
  build-initial)
    # commit_id is derived from the trusted head SHA, not passed in, so the
    # model cannot retarget the review at an arbitrary commit.
    [[ "$#" -eq 3 ]] || fail "Invalid initial review payload arguments."
    body="$2"
    comments="$3"
    [[ -n "${body}" ]] || fail "Initial review body must not be empty."
    head_sha="$(opencode_review_context_head_sha)" || fail "Could not resolve the head commit SHA from the trusted event payload."
    payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    chmod 600 "${payload}"
    jq -n --arg commit_id "${head_sha}" --arg body "${body}" --argjson comments "${comments}" \
      '{commit_id: $commit_id, event: "COMMENT", body: $body, comments: $comments}' >"${payload}"
    valid_payload '(.commit_id | type == "string" and length > 0) and .event == "COMMENT" and (.body | type == "string" and length > 0) and (.comments | type == "array" and length > 0)' "${payload}" || {
      rm -f "${payload}"
      fail "Invalid initial review payload."
    }
    printf '%s\n' "${payload}"
    ;;
  build-update)
    [[ "$#" -eq 2 ]] || fail "Invalid review update payload arguments."
    body="$2"
    [[ -n "${body}" ]] || fail "Review update body must not be empty."
    payload="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review-update.XXXXXX.json")"
    chmod 600 "${payload}"
    jq -n --arg body "${body}" '{body: $body}' >"${payload}"
    valid_payload 'keys == ["body"] and (.body | type == "string" and length > 0)' "${payload}" || {
      rm -f "${payload}"
      fail "Invalid review update payload."
    }
    printf '%s\n' "${payload}"
    ;;
  submit-initial)
    # Only the payload is caller-supplied; repo/PR/commit are trusted context.
    [[ "$#" -eq 2 ]] || fail "Invalid initial review submission arguments."
    payload="$2"
    [[ "${payload}" == "${TMPDIR:-/tmp}"/* && -f "${payload}" ]] || fail "Review payload must be a temporary file."
    valid_payload '(.commit_id | type == "string" and length > 0) and .event == "COMMENT" and (.body | type == "string" and length > 0) and (.comments | type == "array" and length > 0)' "${payload}" || fail "Invalid initial review payload."
    resolve_trusted_target
    # The payload's commit_id must equal the trusted head SHA; refuse a payload
    # built (or tampered) to target a different commit.
    payload_commit="$(jq -r '.commit_id' "${payload}")"
    [[ "${payload_commit}" == "${head_sha}" ]] || fail "Review payload commit_id does not match the trusted head SHA; refusing to submit against a different commit."
    verify_state_or_fail
    load_token_resolver
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || exit 1
    response="$(gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "${payload}")"
    printf '%s\n' "${response}"
    # Record the review ID this run created so a later `update` can only target
    # the review this run actually submitted — not one the model chooses.
    review_id="$(jq -r '.id // empty' <<<"${response}")"
    if [[ "${review_id}" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "${review_id}" >"${state_dir}/review_id"
      chmod 600 "${state_dir}/review_id"
    fi
    ;;
  update)
    # Only the payload is caller-supplied; repo/PR are trusted context and the
    # review ID is read from the state this run recorded after submit-initial.
    [[ "$#" -eq 2 ]] || fail "Invalid review update arguments."
    payload="$2"
    [[ "${payload}" == "${TMPDIR:-/tmp}"/* && -f "${payload}" ]] || fail "Review payload must be a temporary file."
    valid_payload 'keys == ["body"] and (.body | type == "string" and length > 0)' "${payload}" || fail "Invalid review update payload."
    resolve_trusted_target
    [[ -f "${state_dir}/review_id" ]] || fail "No review ID was recorded by this run; submit the initial review before updating."
    review_id="$(cat "${state_dir}/review_id")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Recorded review ID is malformed; refusing to update."
    verify_state_or_fail
    load_token_resolver
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || exit 1
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "${payload}"
    ;;
  *) fail "Unsupported PR review submission operation." ;;
esac
