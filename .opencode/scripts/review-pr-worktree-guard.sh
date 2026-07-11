#!/usr/bin/env bash
# Capture and verify the repository worktree state for /review-pr, and bind it
# to the trusted GitHub Actions run context. The authoritative per-run state
# lives OUTSIDE the checkout (under RUNNER_TEMP) with 0700 permissions so the
# guard itself cannot dirty the reviewed tree and a malicious PR cannot reach
# or forge it.
#
# This file is both a CLI (subcommands below) and a sourceable library:
# review-pr-submit.sh sources it to re-run the exact same verification
# authoritatively, immediately before any write, rather than trusting the
# orchestrator's earlier result or any caller-supplied argument.
#
# Subcommands:
#   precheck  Fail closed (nonzero) if the checkout is not pristine. Inspects
#             only; never cleans/resets/restores/stashes/deletes anything.
#   init      Create the per-run state directory, snapshot the (pristine)
#             worktree, and record the trusted-context binding. Run once at the
#             start of a review, before any analysis.
#   verify    Re-verify the current worktree against the recorded snapshot and
#             re-validate the binding against the live trusted context.
set -euo pipefail

opencode_review_fail() {
  echo "::error::$*" >&2
  return 1
}

# Resolve the trusted repository "owner/name" from the GitHub Actions context.
opencode_review_context_repo() {
  local repo="${GITHUB_REPOSITORY:-}"
  [[ "${repo}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    return 1
  printf '%s' "${repo}"
}

# Resolve the trusted pull request number from the event payload, never from a
# caller-supplied argument. Prefers .pull_request.number, then .issue.number.
opencode_review_context_pr_number() {
  local event_path="${GITHUB_EVENT_PATH:-}" pr_number
  [[ -n "${event_path}" && -f "${event_path}" ]] || return 1
  pr_number="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}" 2>/dev/null)"
  [[ "${pr_number}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "${pr_number}"
}

# Resolve the trusted head commit SHA from the event payload. This is the
# commit the review is pinned to; it is not caller-supplied.
opencode_review_context_head_sha() {
  local event_path="${GITHUB_EVENT_PATH:-}" head_sha
  [[ -n "${event_path}" && -f "${event_path}" ]] || return 1
  head_sha="$(jq -r '.pull_request.head.sha // empty' "${event_path}" 2>/dev/null)"
  [[ "${head_sha}" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 1
  printf '%s' "${head_sha}"
}

# Deterministic, per-run state directory path, derived only from the trusted
# run identifiers so review-pr-submit.sh can recompute it independently without
# a caller-supplied path. Distinct from the ambient TMPDIR snapshot pattern.
opencode_review_state_dir() {
  local root="${RUNNER_TEMP:-}" run_id="${GITHUB_RUN_ID:-}" run_attempt="${GITHUB_RUN_ATTEMPT:-}"
  [[ -n "${root}" && -d "${root}" ]] || root="${TMPDIR:-/tmp}"
  [[ "${run_id}" =~ ^[0-9]+$ ]] || return 1
  [[ "${run_attempt}" =~ ^[0-9]+$ ]] || return 1
  printf '%s/opencode-review-state.%s.%s' "${root}" "${run_id}" "${run_attempt}"
}

# Snapshot the worktree state into $1. Same content the original guard used.
opencode_review_snapshot_worktree() {
  local directory="$1"
  git status --porcelain=v2 --untracked-files=all >"${directory}/status"
  git diff --no-ext-diff --binary >"${directory}/unstaged.diff"
  git diff --cached --no-ext-diff --binary >"${directory}/staged.diff"
  git ls-files --others --exclude-standard -z | while IFS= read -r -d '' path; do
    if [[ -f "${path}" ]]; then
      shasum -a 256 -- "${path}"
    else
      printf 'non-regular %s\n' "${path}"
    fi
  done | LC_ALL=C sort >"${directory}/untracked.sha256"
}

opencode_review_guard_error() {
  echo "::error::/review-pr detected a repository worktree mutation; refusing to submit or complete the review." >&2
  echo "::group::Sanitized worktree status" >&2
  git status --short >&2 || true
  git ls-files --others --exclude-standard >&2 || true
  echo "::endgroup::" >&2
  echo "::group::Sanitized unstaged diff summary" >&2
  git diff --no-ext-diff --stat >&2 || true
  echo "::endgroup::" >&2
  echo "::group::Sanitized staged diff summary" >&2
  git diff --cached --no-ext-diff --stat >&2 || true
  echo "::endgroup::" >&2
}

# Compare the current worktree against the snapshot stored in $1. Returns
# nonzero (and prints a sanitized diagnostic) on any difference.
opencode_review_verify_worktree() {
  local snapshot_directory="$1" current_directory
  [[ -d "${snapshot_directory}" ]] || return 1
  current_directory="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-worktree-current.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '${current_directory}'" RETURN
  opencode_review_snapshot_worktree "${current_directory}"
  if ! cmp -s "${snapshot_directory}/status" "${current_directory}/status" ||
    ! cmp -s "${snapshot_directory}/unstaged.diff" "${current_directory}/unstaged.diff" ||
    ! cmp -s "${snapshot_directory}/staged.diff" "${current_directory}/staged.diff" ||
    ! cmp -s "${snapshot_directory}/untracked.sha256" "${current_directory}/untracked.sha256"; then
    opencode_review_guard_error
    return 1
  fi
}

# Write the trusted-context binding into $1/binding (JSON).
opencode_review_write_binding() {
  local directory="$1" repo pr_number head_sha
  repo="$(opencode_review_context_repo)" || return 1
  pr_number="$(opencode_review_context_pr_number)" || return 1
  head_sha="$(opencode_review_context_head_sha)" || return 1
  jq -n \
    --arg repository "${repo}" \
    --arg pr_number "${pr_number}" \
    --arg head_sha "${head_sha}" \
    --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg created_epoch "$(date -u +%s)" \
    '{repository: $repository, pr_number: $pr_number, head_sha: $head_sha, run_id: $run_id, run_attempt: $run_attempt, created_epoch: $created_epoch}' \
    >"${directory}/binding"
  chmod 600 "${directory}/binding"
}

# Re-validate the recorded binding in $1/binding against the live trusted
# context. Refuses a binding from another repo, PR, run, attempt, or a stale
# head SHA (for example after a force-push mid-review).
opencode_review_verify_binding() {
  local directory="$1" bound repo pr_number head_sha
  [[ -f "${directory}/binding" ]] || {
    opencode_review_fail "/review-pr state binding is missing."
    return 1
  }
  jq -e 'type == "object"' "${directory}/binding" >/dev/null 2>&1 || {
    opencode_review_fail "/review-pr state binding is malformed."
    return 1
  }
  repo="$(opencode_review_context_repo)" || {
    opencode_review_fail "/review-pr could not resolve the trusted repository from GITHUB_REPOSITORY."
    return 1
  }
  pr_number="$(opencode_review_context_pr_number)" || {
    opencode_review_fail "/review-pr could not resolve the trusted PR number from the event payload."
    return 1
  }
  head_sha="$(opencode_review_context_head_sha)" || {
    opencode_review_fail "/review-pr could not resolve the trusted head SHA from the event payload."
    return 1
  }
  bound="$(jq -r '.repository' "${directory}/binding")"
  [[ "${bound}" == "${repo}" ]] || {
    opencode_review_fail "/review-pr state repository (${bound}) does not match the current run (${repo})."
    return 1
  }
  bound="$(jq -r '.pr_number' "${directory}/binding")"
  [[ "${bound}" == "${pr_number}" ]] || {
    opencode_review_fail "/review-pr state PR number (${bound}) does not match the current event (${pr_number})."
    return 1
  }
  bound="$(jq -r '.head_sha' "${directory}/binding")"
  [[ "${bound}" == "${head_sha}" ]] || {
    opencode_review_fail "/review-pr state head SHA is stale; the PR head moved since the review began. Refusing to submit against a changed commit."
    return 1
  }
  bound="$(jq -r '.run_id' "${directory}/binding")"
  [[ "${bound}" == "${GITHUB_RUN_ID:-}" ]] || {
    opencode_review_fail "/review-pr state was created by a different workflow run."
    return 1
  }
  bound="$(jq -r '.run_attempt' "${directory}/binding")"
  [[ "${bound}" == "${GITHUB_RUN_ATTEMPT:-}" ]] || {
    opencode_review_fail "/review-pr state was created by a different run attempt."
    return 1
  }
}

# Authoritative combined check used by both `verify` and review-pr-submit.sh:
# the state dir must exist, its binding must match the live trusted context,
# and the worktree must be unchanged since `init` snapshotted it.
opencode_review_verify_state() {
  local state_dir
  state_dir="$(opencode_review_state_dir)" || {
    opencode_review_fail "/review-pr could not resolve the per-run state directory (missing GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT)."
    return 1
  }
  [[ -d "${state_dir}" ]] || {
    opencode_review_fail "/review-pr per-run state directory is missing; run the worktree guard 'init' before submitting."
    return 1
  }
  opencode_review_verify_binding "${state_dir}" || return 1
  opencode_review_verify_worktree "${state_dir}" || return 1
}

# Fail closed if the checkout is not pristine. porcelain=v2 with
# --untracked-files=all reports staged, unstaged, untracked, deleted, renamed,
# and intent-to-add entries; submodule dirt is checked separately.
opencode_review_precheck() {
  local status_out submodule_out
  status_out="$(git status --porcelain=v2 --untracked-files=all 2>/dev/null)" || {
    opencode_review_fail "/review-pr precheck could not read the git worktree status."
    return 1
  }
  submodule_out="$(git submodule status --recursive 2>/dev/null || true)"
  if [[ -n "${status_out}" ]] || grep -qE '^[+U-]' <<<"${submodule_out}"; then
    echo "::error::/review-pr requires a pristine checkout before analysis begins; the worktree is dirty. Refusing to run. The guard only inspects — it never cleans, resets, restores, stashes, or deletes anything." >&2
    echo "::group::Sanitized worktree status" >&2
    git status --short >&2 || true
    git ls-files --others --exclude-standard >&2 || true
    echo "::endgroup::" >&2
    echo "::group::Sanitized diff summary" >&2
    git diff --no-ext-diff --stat >&2 || true
    git diff --cached --no-ext-diff --stat >&2 || true
    echo "::endgroup::" >&2
    if [[ -n "${submodule_out}" ]]; then
      echo "::group::Sanitized submodule status" >&2
      printf '%s\n' "${submodule_out}" >&2
      echo "::endgroup::" >&2
    fi
    return 1
  fi
}

opencode_review_guard_main() {
  local state_dir
  case "${1:-}" in
    precheck)
      [[ "$#" -eq 1 ]] || exit 2
      opencode_review_precheck || exit 1
      ;;
    init)
      [[ "$#" -eq 1 ]] || exit 2
      state_dir="$(opencode_review_state_dir)" || {
        echo "::error::/review-pr could not resolve the per-run state directory (missing GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT)." >&2
        exit 1
      }
      if [[ -e "${state_dir}" ]]; then
        echo "::error::/review-pr per-run state directory already exists (${state_dir}); refusing to re-initialize a review within the same run attempt." >&2
        exit 1
      fi
      (umask 077 && mkdir -p "${state_dir}")
      chmod 700 "${state_dir}"
      opencode_review_snapshot_worktree "${state_dir}"
      opencode_review_write_binding "${state_dir}" || {
        echo "::error::/review-pr could not record the trusted-context binding; the run is missing required GitHub Actions context." >&2
        exit 1
      }
      printf '%s\n' "${state_dir}"
      ;;
    verify)
      [[ "$#" -eq 1 ]] || exit 2
      opencode_review_verify_state || exit 1
      ;;
    *)
      exit 2
      ;;
  esac
}

# Only dispatch when executed directly; when sourced (by review-pr-submit.sh)
# expose the functions above without running anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  opencode_review_guard_main "$@"
fi
