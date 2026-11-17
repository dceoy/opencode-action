#!/usr/bin/env bash
set -euo pipefail
binary="${OPENCODE_INSTALL_HOME}/.opencode/bin/opencode"
if [[ ! -x "${binary}" && -x "${binary}.exe" ]]; then binary="${binary}.exe"; fi
if [[ ! -f "${binary}" || ! -x "${binary}" ]]; then
  echo "::error::OpenCode executable missing at ${binary}." >&2; exit 1
fi
reported="$("${binary}" --version)" || { echo '::error::OpenCode --version failed.' >&2; exit 1; }
case "${OPENCODE_RUNTIME}:${reported}" in
  "v1:${OPENCODE_VERSION}" | "v1:v${OPENCODE_VERSION}" | "v2:opencode v${OPENCODE_VERSION}") ;;
  *) echo "::error::OpenCode binary version mismatch or unexpected output: '${reported}' (expected ${OPENCODE_RUNTIME} ${OPENCODE_VERSION})." >&2; exit 1 ;;
esac
echo "::notice::Verified OpenCode ${OPENCODE_RUNTIME}, installed version ${OPENCODE_VERSION}."
printf 'opencode-version=%s\nruntime=%s\n' "${OPENCODE_VERSION}" "${OPENCODE_RUNTIME}" >> "${GITHUB_OUTPUT}"
