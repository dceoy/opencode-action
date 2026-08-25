#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  sync_script="${repo_root}/scripts/sync-sakura-models.sh"
  config_path="${BATS_TEST_TMPDIR}/opencode.jsonc"
  mock_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${mock_bin}"

  cat > "${config_path}" << 'JSONC'
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
    "other": {
      "models": {
        "keep-model": {
          "name": "keep-model",
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

  cat > "${mock_bin}/curl" << 'MOCK'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"
if [[ "${url}" == */models ]]; then
  case "${MOCK_CURL_MODE:-normal}" in
  initial-error)
    printf '%s\n' '{"error":"unauthorized"}'
    printf '%s\n' 'initial models request failed' >&2
    exit 22
    ;;
  empty)
    printf '%s\n' '{"data":[]}'
    ;;
  missing-default)
    printf '%s\n' '{"data":[{"id":"chat-a"}]}'
    ;;
  all-non-chat)
    printf '%s\n' '{"data":[{"id":"embedding-x"}]}'
    ;;
  brace-model)
  printf '%s\n' '{"data":[{"id":"chat-{brace}"},{"id":"preview/Kimi-K2.7-Code"}]}'
  ;;
  *)
    printf '%s\n' '{"data":[{"id":"chat-b"},{"id":"chat-a"},{"id":"preview/Kimi-K2.7-Code"}]}'
    ;;
  esac
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
case "${MOCK_CURL_MODE:-normal}" in
probe-error)
  status=429
  body='{"error":"rate limited"}'
  ;;
probe-transport)
  printf '%s\n' 'probe transport failed' >&2
  exit 7
  ;;
*)
  if [[ "${model}" == embedding-x ]]; then
  status=400
  body='{"error":"unsupported"}'
  else
    status=200
    body='{"choices":[]}'
  fi
  ;;
esac
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
  run grep -q '"old-model"' "${config_path}"
  [ "${status}" -eq 1 ]
  grep -q '"keep-model"' "${config_path}"
  grep -q '"external_directory"' "${config_path}"
  [ "$(grep -n '"chat-[ab]"' "${config_path}" | head -1 | sed 's/.*chat-\([ab]\).*/\1/')" = a ]

  run env \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE=brace-model \
    SAKURA_AI_ENGINE_API_KEY=test \
    bash "${sync_script}" "${config_path}"

  [ "${status}" -eq 0 ]
  grep -q '"chat-{brace}"' "${config_path}"
  run grep -q '"chat-a"' "${config_path}"
  [ "${status}" -eq 1 ]
  grep -q '"keep-model"' "${config_path}"
}

@test "fails closed for invalid Sakura sync responses" {
  local -a cases=(
    'empty|Sakura returned an invalid or empty model listing.'
    'initial-error|Failed to fetch Sakura models.'
    'probe-error|Failed to probe Sakura model chat-a (HTTP 429).'
    'probe-transport|Failed to probe Sakura model chat-a.'
    'all-non-chat|Failed to probe Sakura model embedding-x (HTTP 400); refusing to classify it as non-chat.'
    'missing-default|Required Sakura model preview/Kimi-K2.7-Code is unavailable; refusing to update the config.'
  )

  for test_case in "${cases[@]}"; do
    IFS='|' read -r mode expected <<< "${test_case}"
    before="$(cat "${config_path}")"

    run env \
      PATH="${mock_bin}:${PATH}" \
      MOCK_CURL_MODE="${mode}" \
      SAKURA_AI_ENGINE_API_KEY=test \
      bash "${sync_script}" "${config_path}"

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"${expected}"* ]]
    [ "$(cat "${config_path}")" = "${before}" ]
  done
}
