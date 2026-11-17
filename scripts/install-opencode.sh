#!/usr/bin/env bash
set -euo pipefail
case "${OPENCODE_RUNTIME}" in
  v1) installer=https://opencode.ai/install ;;
  v2) installer=https://opencode.ai/v2/install ;;
  *) echo '::error::Unsupported OpenCode installer runtime.' >&2; exit 1 ;;
esac
# Each runtime has its own installer HOME, including during concurrent installs.
mkdir -p "${OPENCODE_INSTALL_HOME}"
shim="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/opencode-installer.XXXXXXXX")"
trap 'rm -r -- "${shim}"' EXIT
printf '#!/usr/bin/env bash\nprintf "0.0.0\\n"\n' > "${shim}/opencode"
chmod 700 "${shim}/opencode"
curl -fsSL "${installer}" | TMPDIR="${shim}" PATH="${shim}:${PATH}" HOME="${OPENCODE_INSTALL_HOME}" GITHUB_PATH=/dev/null bash -s -- --version "${OPENCODE_VERSION}" --no-modify-path
