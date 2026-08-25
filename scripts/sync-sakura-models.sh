#!/usr/bin/env bash
set -euo pipefail

config_path="${1:-.opencode/opencode.jsonc}"
api_base="${SAKURA_AI_ENGINE_API_BASE_URL:-https://api.ai.sakura.ad.jp/v1}"
api_key="${SAKURA_AI_ENGINE_API_KEY:?SAKURA_AI_ENGINE_API_KEY is required}"
default_model='preview/Kimi-K2.7-Code'

is_known_non_chat_model() {
  case "$1" in
    multilingual-e5-large | preview/Qwen3-Embedding-4B-FP16 | whisper-large-v3-turbo)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

models_response="${tmp_dir}/models.json"
if ! curl --fail-with-body --silent --show-error --retry 3 --retry-all-errors \
  -H "Authorization: Bearer ${api_key}" \
  -H 'Accept: application/json' \
  "${api_base%/}/models" > "${models_response}"; then
  echo 'Failed to fetch Sakura models.' >&2
  exit 1
fi

if ! jq -e '
  (.data | type == "array")
  and (.data | length > 0)
  and all(.data[]; (.id | type == "string") and (.id | length > 0))
' "${models_response}" > /dev/null; then
  echo 'Sakura returned an invalid or empty model listing.' >&2
  exit 1
fi

model_ids="${tmp_dir}/model-ids"
if ! jq -r '.data[].id' "${models_response}" | LC_ALL=C sort -u > "${model_ids}"; then
  echo 'Failed to extract Sakura model IDs.' >&2
  exit 1
fi
mapfile -t models < "${model_ids}"
chat_models=()
for model in "${models[@]}"; do
  if is_known_non_chat_model "${model}"; then
    echo "Skipping known non-chat Sakura model ${model}." >&2
    continue
  fi

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

  if ((curl_status != 0)); then
    echo "Failed to probe Sakura model ${model}." >&2
    exit "${curl_status}"
  fi

  case "${status}" in
    2??)
      chat_models+=("${model}")
      ;;
    401 | 403 | 429 | 5??)
      echo "Failed to probe Sakura model ${model} (HTTP ${status})." >&2
      cat "${probe_response}" >&2
      exit 1
      ;;
    *)
      echo "Failed to probe Sakura model ${model} (HTTP ${status}); refusing to classify it as non-chat." >&2
      cat "${probe_response}" >&2
      exit 1
      ;;
  esac
done

if ((${#chat_models[@]} == 0)); then
  echo 'Sakura returned no usable chat models; refusing to update the config.' >&2
  exit 1
fi

default_model_found=false
for model in "${chat_models[@]}"; do
  if [[ "${model}" == "${default_model}" ]]; then
    default_model_found=true
    break
  fi
done
if [[ "${default_model_found}" != true ]]; then
  echo "Required Sakura model ${default_model} is unavailable; refusing to update the config." >&2
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
  function trimmed(line) {
    sub(/^[[:space:]]*/, "", line)
    return line
  }
  function object_start(line, name) {
    return trimmed(line) ~ ("^\"" name "\"[[:space:]]*:[[:space:]]*\\{[[:space:]]*$")
  }
  function scan_line(text,    i, character, next_character) {
    brace_delta = 0
    for (i = 1; i <= length(text); i++) {
      character = substr(text, i, 1)
      next_character = substr(text, i + 1, 1)
      if (block_comment) {
        if (character == "*" && next_character == "/") {
          block_comment = 0
          i++
        }
        continue
      }
      if (in_string) {
        if (escaped) {
          escaped = 0
        } else if (character == "\\") {
          escaped = 1
        } else if (character == "\"") {
          in_string = 0
        }
        continue
      }
      if (character == "/" && next_character == "*") {
        block_comment = 1
        i++
      } else if (character == "/" && next_character == "/") {
        break
      } else if (character == "\"") {
        in_string = 1
      } else if (character == "{") {
        brace_delta++
      } else if (character == "}") {
        brace_delta--
      }
    }
  }
  BEGIN {
    while ((getline line < replacement) > 0) {
      block = block line ORS
    }
    close(replacement)
  }
  replacing {
    scan_line($0)
    depth += brace_delta
    if (depth == models_base_depth) {
      replacing = 0
    }
    next
  }
  !provider_open && depth == 1 && object_start($0, "provider") {
    provider_open = 1
    provider_depth = depth
  }
  provider_open && !sakura_open && depth == provider_depth + 1 && object_start($0, "sakura") {
    sakura_open = 1
    sakura_found = 1
    sakura_depth = depth
  }
  sakura_open && !replacing && depth == sakura_depth + 1 && object_start($0, "models") {
    found++
    if (found > 1) {
      print "Found multiple provider.sakura.models objects in the OpenCode config." > "/dev/stderr"
      exit 1
    }
    printf "%s", block
    replacing = 1
    models_base_depth = depth
    depth++
    next
  }
  {
    scan_line($0)
    depth += brace_delta
    if (sakura_open && depth <= sakura_depth) {
      sakura_open = 0
    }
    if (provider_open && depth <= provider_depth) {
      provider_open = 0
    }
    print
  }
  END {
    if (!found || replacing || !sakura_found || block_comment || in_string) {
      print "Failed to locate provider.sakura.models in the OpenCode config." > "/dev/stderr"
      exit 1
    }
  }
' "${config_path}" > "${updated_config}"

cat "${updated_config}" > "${config_path}"
