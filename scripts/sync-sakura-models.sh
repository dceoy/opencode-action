#!/usr/bin/env bash
set -euo pipefail

config_path="${1:-.opencode/opencode.jsonc}"
api_base="${SAKURA_AI_ENGINE_API_BASE_URL:-https://api.ai.sakura.ad.jp/v1}"
api_key="${SAKURA_AI_ENGINE_API_KEY:?SAKURA_AI_ENGINE_API_KEY is required}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

models_response="${tmp_dir}/models.json"
curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
  -H "Authorization: Bearer ${api_key}" \
  -H 'Accept: application/json' \
  "${api_base%/}/models" > "${models_response}"

jq -e '
  (.data | type == "array")
  and (.data | length > 0)
  and all(.data[]; (.id | type == "string") and (.id | length > 0))
' "${models_response}" > /dev/null

mapfile -t models < <(jq -r '.data[].id' "${models_response}" | LC_ALL=C sort -u)
chat_models=()
for model in "${models[@]}"; do
  payload="$(jq -cn --arg model "${model}" '{model: $model, messages: [{role: "user", content: "Reply with OK."}], max_tokens: 1}')"
  probe_response="${tmp_dir}/probe.json"

  set +e
  status="$(curl --silent --show-error --retry 3 --retry-all-errors \
    --output "${probe_response}" --write-out '%{http_code}' \
    -H "Authorization: Bearer ${api_key}" \
    -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${api_base%/}/chat/completions")"
  curl_status=$?
  set -e

  if (( curl_status != 0 )); then
    echo "Failed to probe Sakura model ${model}." >&2
    exit "${curl_status}"
  fi

  case "${status}" in
    2??)
      chat_models+=("${model}")
      ;;
    400|404|405|422)
      echo "Skipping non-chat model ${model} (HTTP ${status})." >&2
      ;;
    401|403|429|5??)
      echo "Failed to probe Sakura model ${model} (HTTP ${status})." >&2
      cat "${probe_response}" >&2
      exit 1
      ;;
    *)
      echo "Unexpected response probing Sakura model ${model} (HTTP ${status})." >&2
      cat "${probe_response}" >&2
      exit 1
      ;;
  esac
done

if (( ${#chat_models[@]} == 0 )); then
  echo 'Sakura returned no usable chat models; refusing to update the config.' >&2
  exit 1
fi

models_block="${tmp_dir}/models.block"
{
  echo '      "models": {'
  for model in "${chat_models[@]}"; do
    model_json="$(jq -Rn --arg model "${model}" '$model')"
    printf '        %s: {\n' "${model_json}"
    printf '          "name": %s,\n' "${model_json}"
    echo '          "variants": {},'
    echo '        },'
  done
  echo '      },'
} > "${models_block}"

updated_config="${tmp_dir}/opencode.jsonc"
awk -v replacement="${models_block}" '
  BEGIN {
    while ((getline line < replacement) > 0) {
      block = block line ORS
    }
    close(replacement)
  }
  !replacing && $0 ~ /^[[:space:]]*"models"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
    printf "%s", block
    replacing = 1
    found = 1
    line = $0
    depth = gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
    next
  }
  replacing {
    line = $0
    depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
    if (depth == 0) {
      replacing = 0
    }
    next
  }
  { print }
  END {
    if (!found || replacing) {
      print "Failed to locate a complete models object in the OpenCode config." > "/dev/stderr"
      exit 1
    }
  }
' "${config_path}" > "${updated_config}"

cat "${updated_config}" > "${config_path}"
