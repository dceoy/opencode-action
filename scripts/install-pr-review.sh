#!/usr/bin/env bash
# Install a SHA-pinned upstream Skill directly into isolated OpenCode user config.
pr_review_finalize_skill() {
  local target_dir="${1}" rel
  for rel in SKILL.md references/review-lenses.md references/finding-validation.md references/github-posting.md; do
    if [[ ! -f "${target_dir}/${rel}" ]]; then
      echo "::error::Missing pr-review skill file: ${rel}" >&2
      return 1
    fi
  done
  if find "${target_dir}" -type l -print -quit | grep -q .; then
    echo "::error::pr-review skill contains symbolic links." >&2
    return 1
  fi
  # OpenCode requires explicit slash metadata; gh adds source metadata separately.
  python3 - "${target_dir}/SKILL.md" << 'PYCODE'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
parts = text.split("---", 2)
if len(parts) != 3 or parts[0].strip():
    raise SystemExit("pr-review skill must contain YAML frontmatter")
frontmatter = parts[1]
if re.search(r"^metadata:\s*$", frontmatter, re.MULTILINE):
    if re.search(r"^  opencode/slash:.*$", frontmatter, re.MULTILINE):
        frontmatter = re.sub(r"^  opencode/slash:.*$", '  opencode/slash: "true"', frontmatter, flags=re.MULTILINE)
    else:
        frontmatter = re.sub(r"^metadata:\s*$", 'metadata:\n  opencode/slash: "true"', frontmatter, count=1, flags=re.MULTILINE)
else:
    frontmatter += 'metadata:\n  opencode/slash: "true"\n'
path.write_text("---" + frontmatter + "---" + parts[2])
PYCODE
}

opencode_validate_review_version() {
  local original_version="${1:-}" version major minor patch prerelease
  version="${original_version#v}"

  if [[ ! "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z]+([.-][0-9A-Za-z]+)*))?(\+([0-9A-Za-z]+([.-][0-9A-Za-z]+)*))?$ ]]; then
    echo "::error::Review-only mode requires a semantic OpenCode version at or above 1.2.14 (got '${original_version}')." >&2
    return 1
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  prerelease="${BASH_REMATCH[5]:-}"
  if ((10#${major} < 1 || (\
    10#${major} == 1 && 10#${minor} < 2) || (\
    10#${major} == 1 && 10#${minor} == 2 && 10#${patch} < 14))) \
      || [[ "${major}.${minor}.${patch}" == "1.2.14" && -n "${prerelease}" ]]; then
    echo "::error::Review-only mode requires OpenCode 1.2.14 or newer (got '${original_version}')." >&2
    return 1
  fi
}

install_pr_review() {
  local ref="${PR_REVIEW_REF:?PR_REVIEW_REF is required}" target_dir
  if [[ "${USE_BUNDLED_TOOLKIT:-false}" != "true" ]]; then
    echo "::error::review-only requires use-bundled-toolkit: true." >&2
    return 1
  fi
  if [[ ! "${ref}" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "::error::pr-review-ref must be a full immutable 40-character commit SHA." >&2
    return 1
  fi
  opencode_validate_review_version "${OPENCODE_VERSION:-}" || return 1
  ref="$(printf '%s' "${ref}" | tr '[:upper:]' '[:lower:]')"
  target_dir="${HOME}/.config/opencode/skills/pr-review"
  if [[ -L "${HOME}/.config" || -L "${HOME}/.config/opencode" ||
        -L "${HOME}/.config/opencode/skills" || -e "${target_dir}" || -L "${target_dir}" ]]; then
    echo "::error::Refusing unsafe or existing pr-review destination." >&2
    return 1
  fi
  if ! gh skill install --help > /dev/null 2>&1; then
    echo "::error::gh skill requires GitHub CLI v2.90.0 or newer." >&2
    return 1
  fi
  # gh handles commit pinning and copies the exact Skill without npm lifecycle scripts.
  if ! gh skill install dceoy/pr-loop skills/pr-review --pin "${ref}" --agent opencode --scope user; then
    rm -rf "${target_dir}"
    echo "::error::Failed to install the pinned pr-review Skill." >&2
    return 1
  fi
  if ! pr_review_finalize_skill "${target_dir}"; then
    rm -rf "${target_dir}"
    return 1
  fi
  echo "Installed pr-loop/pr-review at ${ref}"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  install_pr_review
fi
