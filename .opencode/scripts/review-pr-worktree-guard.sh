#!/usr/bin/env bash
# Capture and verify the repository worktree state for /review-pr. Snapshots
# live outside the checkout so the guard itself cannot dirty the reviewed tree.
set -euo pipefail

guard_error() {
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

snapshot_state() {
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

case "${1:-}" in
  snapshot)
    [[ "$#" -eq 1 ]] || exit 2
    snapshot_directory="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-worktree.XXXXXX")"
    snapshot_state "${snapshot_directory}"
    printf '%s\n' "${snapshot_directory}"
    ;;
  verify)
    [[ "$#" -eq 2 ]] || exit 2
    snapshot_directory="$2"
    case "${snapshot_directory}" in
      "${TMPDIR:-/tmp}"/opencode-review-worktree.*) ;;
      *) exit 2 ;;
    esac
    [[ -d "${snapshot_directory}" ]] || exit 2
    current_directory="$(mktemp -d "${TMPDIR:-/tmp}/opencode-review-worktree-current.XXXXXX")"
    trap 'rm -rf "${current_directory}"' EXIT
    snapshot_state "${current_directory}"
    if ! cmp -s "${snapshot_directory}/status" "${current_directory}/status" ||
      ! cmp -s "${snapshot_directory}/unstaged.diff" "${current_directory}/unstaged.diff" ||
      ! cmp -s "${snapshot_directory}/staged.diff" "${current_directory}/staged.diff" ||
      ! cmp -s "${snapshot_directory}/untracked.sha256" "${current_directory}/untracked.sha256"; then
      guard_error
      exit 1
    fi
    ;;
  *)
    exit 2
    ;;
esac
