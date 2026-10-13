#!/usr/bin/env bash
# Install only pr-loop's pr-review skill and its relative reference files.
pr_review_copy_skill() {
  local source_dir="${1}" target_dir="${2}" parent
  parent="$(dirname "${target_dir}")"
  for rel in SKILL.md references/review-lenses.md references/finding-validation.md references/github-posting.md; do
    if [[ ! -f "${source_dir}/${rel}" ]]; then
      echo "::error::Missing pr-review skill file: ${rel}" >&2
      return 1
    fi
  done
  if find "${source_dir}" -type l -print -quit | grep -q .; then
    echo "::error::pr-review source contains symbolic links." >&2
    return 1
  fi
  if [[ -L "${parent}" || -e "${target_dir}" || -L "${target_dir}" ]]; then
    echo "::error::Refusing to overwrite or follow an existing pr-review skill destination." >&2
    return 1
  fi
  mkdir -p "${parent}"
  cp -R "${source_dir}" "${target_dir}"
}
install_pr_review() {
  local ref="${PR_REVIEW_REF:?PR_REVIEW_REF is required}" checkout
  if [[ "${USE_BUNDLED_TOOLKIT:-false}" != "true" ]]; then
    echo "::error::review-only requires use-bundled-toolkit: true." >&2
    return 1
  fi
  if [[ ! "${ref}" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "::error::pr-review-ref must be a full immutable 40-character commit SHA." >&2
    return 1
  fi
  checkout="$(mktemp -d)"
  trap 'rm -rf "${checkout}"' RETURN
  git -C "${checkout}" init -q
  git -C "${checkout}" -c protocol.version=2 fetch -q --no-tags --depth=1 https://github.com/dceoy/pr-loop.git "${ref}"
  git -C "${checkout}" checkout -q --detach FETCH_HEAD
  if [[ "$(git -C "${checkout}" rev-parse HEAD)" != "${ref,,}" ]]; then
    echo "::error::Downloaded pr-loop commit does not match the pinned SHA." >&2
    return 1
  fi
  pr_review_copy_skill "${checkout}/skills/pr-review" "${HOME}/.config/opencode/skills/pr-review"
  echo "Installed pr-loop/pr-review at ${ref}"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  install_pr_review
fi
