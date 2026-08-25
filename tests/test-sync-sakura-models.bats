#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  sync_script="${repo_root}/scripts/sync-sakura-models.sh"
  config_path="${BATS_TEST_TMPDIR}/opencode.jsonc"
  mock_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${mock_bin}"

  cat > "${config_path}" <<'JSONC'
{
  "provider": {
    "sakura": {
      "models": {
        "old-model": {
          "name": "old-model",
          "variants": {},
        },
      },
    },
  },
  "permission": {
    "external_directory": {
      "*": "deny",
    },
  },
}
JSONC

  cat > "${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"
if [[ "${url}" == */models ]]; then
  if [[ "${MOCK_CURL_MODE:-normal}" == empty ]]; then
    printf '%s\n' '{"data":[]}'
  else
    printf '%s\n' '{"data":[{"id":"chat-b"},{"id":"embedding-x"},{"id":"chat-a"}]}'
  fi
  exit 0
fi

output=''
payload=''
while (( $# > 0 )); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --data)
      payload="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

model="$(jq -r '.model' <<< "${payload}")"
if [[ "${model}" == embedding-x ]]; then
  status=400
  body='{"error":"unsupported"}'
else
  status=200
  body='{"choices":[]}'
fi
printf '%s' "${body}" > "${output}"
printf '%s' "${status}"
MOCK
  chmod +x "${mock_bin}/curl"
}

@test "syncs sorted chat models and preserves the rest of the config" {
  run env \
    PATH="${mock_bin}:${PATH}" \
    SAKURA_AI_ENGINE_API_KEY=test \
    bash "${sync_script}" "${config_path}"

  [ "${status}" -eq 0 ]
  grep -q '"chat-a"' "${config_path}"
  grep -q '"chat-b"' "${config_path}"
  ! grep -q '"embedding-x"' "${config_path}"
  ! grep -q '"old-model"' "${config_path}"
  grep -q '"external_directory"' "${config_path}"
  [ "$(grep -n '"chat-[ab]"' "${config_path}" | head -1 | sed 's/.*chat-\([ab]\).*/\1/')" = a ]
}

@test "leaves the config unchanged when the models response is empty" {
  before="$(cat "${config_path}")"

  run env \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE=empty \
    SAKURA_AI_ENGINE_API_KEY=test \
    bash "${sync_script}" "${config_path}"

  [ "${status}" -ne 0 ]
  [ "$(cat "${config_path}")" = "${before}" ]
}
