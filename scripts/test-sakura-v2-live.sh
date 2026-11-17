#!/usr/bin/env bash
# Run only from trusted default-branch code on an isolated runner with a real key.
set -euo pipefail
: "${SAKURA_AI_ENGINE_API_KEY:?A real Sakura API key is required}"
: "${SAKURA_MODEL:?Set SAKURA_MODEL to a catalog model ID without the sakura/ prefix}"
: "${OPENCODE_V2_BIN:?Set OPENCODE_V2_BIN to the pinned v2 executable}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/scripts/opencode-action-lib.sh"
opencode_jsonc_to_json < "${root}/.opencode/opencode.jsonc" | jq -e --arg model "${SAKURA_MODEL}" '.provider.sakura.models | has($model)' > /dev/null || {
  echo 'Malformed catalog or model absent from catalog.' >&2
  exit 1
}
test "$("${OPENCODE_V2_BIN}" --version)" = 'opencode v2.3.0'
tmpdir="$(mktemp -d)"
export HOME="${tmpdir}/home" XDG_CONFIG_HOME="${tmpdir}/home/.config" XDG_DATA_HOME="${tmpdir}/home/.local/share" XDG_CACHE_HOME="${tmpdir}/home/.cache"
export OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_EXTERNAL_SKILLS=1
mkdir -p "${XDG_CONFIG_HOME}/opencode" "${tmpdir}/work"
cp "${root}/.opencode/opencode.jsonc" "${XDG_CONFIG_HOME}/opencode/"
printf 'SAKURA_TOOL_CHECK_126\n' > "${tmpdir}/work/probe.txt"
cd "${tmpdir}/work"
# The model can read only the probe; shell, network, and other tools stay denied.
OPENCODE_CONFIG_CONTENT="$(jq -nc --arg probe "${tmpdir}/work/probe.txt" \
  '{permission: {"*": "deny", read: {"*": "deny", "probe.txt": "allow", ($probe): "allow"}}}')"
export OPENCODE_CONFIG_CONTENT
# Output may contain provider data; keep it off the workflow log, even on failure.
set +e
timeout 5m "${OPENCODE_V2_BIN}" run --standalone --format json --model "sakura/${SAKURA_MODEL}" --auto \
  'Use the read tool to read probe.txt, then report its contents.' > "${tmpdir}/output" 2> "${tmpdir}/error"
status=$?
set -e
if ((status != 0)); then
  if ((status == 124)); then
    echo 'OpenCode timed out (five-minute harness deadline).' >&2
  elif grep -Eiq '429|rate.limit' "${tmpdir}/output" "${tmpdir}/error"; then
    echo 'Provider rate limit reported.' >&2
  elif grep -Eiq '401|403|unauthori[sz]ed|authentication' "${tmpdir}/output" "${tmpdir}/error"; then
    echo 'Provider authentication or authorization failure reported.' >&2
  elif grep -Eiq 'timeout|timed out' "${tmpdir}/output" "${tmpdir}/error"; then
    echo 'Provider timeout reported.' >&2
  elif grep -Eiq 'config|parse|schema' "${tmpdir}/output" "${tmpdir}/error"; then
    echo 'Configuration or parse failure reported.' >&2
  else
    echo 'OpenCode or provider request failed; inspect securely on the runner.' >&2
  fi
  exit 1
fi
# Require both a successful native read tool event and its known response marker.
if ! jq -s -e '[.[] | select(.type == "tool_use" and .part.tool == "read" and .part.state.status == "completed")] | length > 0' "${tmpdir}/output" > /dev/null || ! grep -q SAKURA_TOOL_CHECK_126 "${tmpdir}/output"; then
  echo 'Request completed without verified read tool use and expected marker.' >&2
  exit 1
fi
echo 'Sakura v2 read tool call and response marker verified.'
