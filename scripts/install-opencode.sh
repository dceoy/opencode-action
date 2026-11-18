#!/usr/bin/env bash
set -euo pipefail
case "${OPENCODE_RUNTIME}" in
  v1) installer=https://opencode.ai/install; digest=a2dd59522b9a091b6cdb2e4870c0f2135f7da09807cd5a7e04222d4316925b72 ;;
  v2) installer=https://opencode.ai/v2/install; digest=bbc4584fd6a888bcd14623b8a63afa0f1b4075a2e84a2c3518cd509b446b3135 ;;
  *) echo '::error::Unsupported OpenCode installer runtime.' >&2; exit 1 ;;
esac
# Each runtime has its own installer HOME, including during concurrent installs.
mkdir -p "${OPENCODE_INSTALL_HOME}"
shim="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/opencode-installer.XXXXXXXX")"
trap 'rm -r -- "${shim}"' EXIT
printf '#!/usr/bin/env bash\nprintf "0.0.0\\n"\n' > "${shim}/opencode"
chmod 700 "${shim}/opencode"
curl -fsSL "${installer}" -o "${shim}/installer.sh"
actual="$(shasum -a 256 "${shim}/installer.sh")"
if [[ "${actual%% *}" != "${digest}" ]]; then
  echo '::error::OpenCode installer changed; update and verify the pinned installer digest.' >&2
  exit 1
fi
TMPDIR="${shim}" PATH="${shim}:${PATH}" HOME="${OPENCODE_INSTALL_HOME}" GITHUB_PATH=/dev/null bash "${shim}/installer.sh" --version "${OPENCODE_VERSION}" --no-modify-path
