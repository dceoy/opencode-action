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
  local ref="${PR_REVIEW_REF:?PR_REVIEW_REF is required}" checkout checkout_dir
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
  # Install only a pinned Git dependency in a temporary workspace, never in
  # the untrusted caller checkout or inherited OpenCode config.
  checkout_dir="$(mktemp -d)"
  checkout="$(cd "${checkout_dir}" && pwd -P)"
  trap 'rm -rf "${checkout}"' RETURN
  # Keep install policy static, injecting only the immutable dependency ref.
  local manifest_dir
  manifest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/pr-review-pnpm" && pwd -P)"
  cp "${manifest_dir}/package.json" "${manifest_dir}/pnpm-workspace.yaml" "${checkout}/"

  # The dependency is installed outside the potentially untrusted PR checkout.
  (cd "${checkout}" && corepack pnpm add --save-dev --ignore-scripts --no-frozen-lockfile \
    "pr-loop@git+https://github.com/dceoy/pr-loop.git#${ref}")

  if ! python3 - "${checkout}/pnpm-lock.yaml" "${ref}" <<'PYCODE'
import re
import sys
from pathlib import Path

lockfile = Path(sys.argv[1]).read_text()
ref = sys.argv[2]
git_source = f"git+https://github.com/dceoy/pr-loop.git#{ref}"
tarball_source = f"https://codeload.github.com/dceoy/pr-loop/tar.gz/{ref}"

# Verify the root importer's resolved version, not just its requested specifier.
match = re.search(r"^      pr-loop:\n(?P<body>(?:        .*\n)+)", lockfile, re.MULTILINE)
if not match:
    raise SystemExit(1)
body = match.group("body")
specifier = re.search(r"^        specifier: (.+)$", body, re.MULTILINE)
version = re.search(r"^        version: (.+)$", body, re.MULTILINE)
if not specifier or not version or specifier.group(1) != git_source:
    raise SystemExit(1)
resolved = version.group(1)
if resolved not in (git_source, tarball_source):
    raise SystemExit(1)

package = re.search(rf"^  pr-loop@{re.escape(resolved)}:\n(?P<body>(?:    .*\n)*)", lockfile, re.MULTILINE)
if not package:
    raise SystemExit(1)
if resolved == tarball_source and f"tarball: {tarball_source}" not in package.group("body"):
    raise SystemExit(1)
PYCODE
  then
    echo "::error::pnpm lockfile does not resolve pr-loop to the pinned commit." >&2
    return 1
  fi

  local linked_skill="${checkout}/.agents/skills/pnpm-pr-loop-pr-review" source_dir
  if [[ ! -L "${linked_skill}" ]]; then
    echo "::error::pnpm did not link the approved pr-loop/pr-review skill." >&2
    return 1
  fi
  source_dir="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "${linked_skill}")" || return 1
  case "${source_dir}" in
    "${checkout}/node_modules/"*) ;;
    *)
      echo "::error::pnpm skill link points outside isolated node_modules." >&2
      return 1
      ;;
  esac
  pr_review_copy_skill "${source_dir}" "${HOME}/.config/opencode/skills/pr-review" || return 1
  echo "Installed pr-loop/pr-review at ${ref}"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  install_pr_review
fi
