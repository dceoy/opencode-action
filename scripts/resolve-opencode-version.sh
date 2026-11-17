#!/usr/bin/env bash
set -euo pipefail
runtime="${INPUT_RUNTIME}"
version="${INPUT_VERSION}"
case "${runtime}" in
  v1 | v2) ;;
  *) echo "::error::Invalid runtime '${runtime}'; choose v1 or v2." >&2; exit 1 ;;
esac
if [[ "${version}" == latest || "${version}" == v1 || "${version}" == v2 ]]; then
  echo "::error::Floating version '${version}' cannot be verified for ${runtime}; pin an exact ${runtime} release (for example v1.19.3 or v2.3.0)." >&2
  exit 1
fi
version="${version#v}"
if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || [[ "v${BASH_REMATCH[1]}" != "${runtime}" ]]; then
  echo "::error::Version '${INPUT_VERSION}' must be an exact stable ${runtime} semver release." >&2
  exit 1
fi
if [[ "${runtime}" == v1 && "${REVIEW_ONLY}" == true ]]; then
  minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  if (( 10#${minor} < 2 || (10#${minor} == 2 && 10#${patch} < 14) )); then
    echo '::error::Review-only requires OpenCode v1.2.14 or newer within v1.' >&2
    exit 1
  fi
fi
printf 'opencode-version=%s\nruntime=%s\n' "${version}" "${runtime}" | tee -a "${GITHUB_OUTPUT}"
echo "::notice::Selected OpenCode ${runtime}, resolved version ${version}."
