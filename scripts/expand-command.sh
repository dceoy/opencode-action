#!/usr/bin/env bash
# shellcheck disable=SC2034
# Resolve Markdown slash commands and the effective primary agent for
# `opencode github run`. Intended to be sourced by action.yml.
#
# Supported:
# - Markdown command files named <command>.md
# - command frontmatter `agent:` when it selects a primary agent
# - literal `$ARGUMENTS` expansion
#
# Deliberately unsupported:
# - positional $1..$N placeholders
# - !`shell` command blocks
# - command frontmatter `model:` or `subtask:`
# - commands defined in opencode.json/opencode.jsonc

_opencode_strip_scalar_quotes() {
  local value="${1}"
  if (( ${#value} >= 2 )) && {
    [[ "${value}" == \"*\" ]] || [[ "${value}" == \'*\' ]]
  }; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

_opencode_frontmatter_scalar() {
  local file="${1}" key="${2}" value
  value="$(awk -v key="${key}" '
    NR == 1 { if ($0 != "---") exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && sub("^" key ":[[:space:]]*", "") {
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "${file}")"
  _opencode_strip_scalar_quotes "${value}"
}

_opencode_frontmatter_has_key() {
  local file="${1}" key="${2}"
  awk -v key="${key}" '
    NR == 1 { if ($0 != "---") exit 1; next }
    $0 == "---" { exit 1 }
    $0 ~ ("^" key ":[[:space:]]*") { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "${file}"
}

opencode_command_agent() {
  _opencode_frontmatter_scalar "${1}" "agent"
}

opencode_command_template() {
  awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter {
      if ($0 == "---") in_frontmatter = 0
      next
    }
    { print }
  ' "${1}"
}

_opencode_assert_supported_command() {
  local file="${1}" key command_agent agent_file agent_mode template

  for key in model subtask; do
    if _opencode_frontmatter_has_key "${file}" "${key}"; then
      echo "::error::Cannot expand ${file}: command frontmatter '${key}' is not supported by opencode github run dispatch." >&2
      return 1
    fi
  done

  template="$(opencode_command_template "${file}")"
  if printf '%s\n' "${template}" | grep -Eq '\$[1-9][0-9]*'; then
    echo "::error::Cannot expand ${file}: positional placeholders are not supported by opencode github run dispatch." >&2
    return 1
  fi
  if printf '%s\n' "${template}" | grep -Eq '!`[^`]*`'; then
    echo "::error::Cannot expand ${file}: shell template blocks are not supported by opencode github run dispatch." >&2
    return 1
  fi

  command_agent="$(opencode_command_agent "${file}")"
  [[ -n "${command_agent}" ]] || return 0
  case "${command_agent}" in
    build | plan)
      return 0
      ;;
  esac

  agent_file="$(dirname "$(dirname "${file}")")/agents/${command_agent}.md"
  if [[ ! -f "${agent_file}" ]]; then
    echo "::error::Cannot expand ${file}: agent '${command_agent}' cannot be verified as a primary agent." >&2
    return 1
  fi
  agent_mode="$(_opencode_frontmatter_scalar "${agent_file}" "mode")"
  case "${agent_mode}" in
    "" | all | primary)
      return 0
      ;;
    *)
      echo "::error::Cannot expand ${file}: agent '${command_agent}' has non-primary mode '${agent_mode}'." >&2
      return 1
      ;;
  esac
}

# Use an explicit action prompt when present. Otherwise, for supported GitHub
# comment events, extract the text after the earliest configured mention so a
# comment such as `/oc /review-pr security` reaches slash-command expansion.
opencode_effective_prompt() {
  local prompt="${1:-}" mentions="${2:-}" event_path="${3:-}"
  local body lower_body raw_mention mention lower_mention before
  local index best_index=-1 best_length=0
  local -a mention_values

  OPENCODE_EFFECTIVE_PROMPT="${prompt}"
  [[ -z "${prompt}" && -n "${event_path}" && -f "${event_path}" ]] || return 0

  body="$(jq -r '.comment.body // empty' "${event_path}")"
  [[ -n "${body}" ]] || return 0
  lower_body="$(printf '%s' "${body}" | tr '[:upper:]' '[:lower:]')"

  IFS=',' read -r -a mention_values <<< "${mentions}"
  for raw_mention in "${mention_values[@]}"; do
    mention="${raw_mention#"${raw_mention%%[![:space:]]*}"}"
    mention="${mention%"${mention##*[![:space:]]}"}"
    [[ -n "${mention}" ]] || continue
    lower_mention="$(printf '%s' "${mention}" | tr '[:upper:]' '[:lower:]')"
    [[ "${lower_body}" == *"${lower_mention}"* ]] || continue
    before="${lower_body%%"${lower_mention}"*}"
    index=${#before}
    if (( best_index < 0 || index < best_index )); then
      best_index=${index}
      best_length=${#mention}
    fi
  done

  (( best_index >= 0 )) || return 0
  OPENCODE_EFFECTIVE_PROMPT="${body:best_index+best_length}"
  OPENCODE_EFFECTIVE_PROMPT="${OPENCODE_EFFECTIVE_PROMPT#"${OPENCODE_EFFECTIVE_PROMPT%%[![:space:]]*}"}"
}

# Convert JSONC from stdin to strict JSON while preserving comment-like text
# inside strings. This lets the action merge default_agent without rejecting
# valid OPENCODE_CONFIG_CONTENT comments or trailing commas.
opencode_jsonc_to_json() {
  local input out="" pending="" char next state="normal" index length
  input="$(cat)"
  length=${#input}
  index=0

  while (( index < length )); do
    char="${input:index:1}"
    next="${input:index+1:1}"
    case "${state}" in
      normal)
        case "${char}" in
          '"')
            out+="${pending}${char}"
            pending=""
            state="string"
            ;;
          '/')
            if [[ "${next}" == '/' ]]; then
              state="line_comment"
              index=$((index + 1))
            elif [[ "${next}" == '*' ]]; then
              state="block_comment"
              index=$((index + 1))
            else
              out+="${pending}${char}"
              pending=""
            fi
            ;;
          ',')
            pending+="${char}"
            ;;
          '}' | ']')
            pending="${pending//,/}"
            out+="${pending}${char}"
            pending=""
            ;;
          ' ' | $'\t' | $'\n' | $'\r')
            pending+="${char}"
            ;;
          *)
            out+="${pending}${char}"
            pending=""
            ;;
        esac
        ;;
      string)
        out+="${char}"
        if [[ "${char}" == "\\" ]]; then
          out+="${next}"
          index=$((index + 1))
        elif [[ "${char}" == '"' ]]; then
          state="normal"
        fi
        ;;
      line_comment)
        if [[ "${char}" == $'\n' ]]; then
          pending+="${char}"
          state="normal"
        fi
        ;;
      block_comment)
        if [[ "${char}" == '*' && "${next}" == '/' ]]; then
          state="normal"
          index=$((index + 1))
        fi
        ;;
    esac
    index=$((index + 1))
  done

  printf '%s' "${out}${pending}"
}

# $1: prompt input
# $2: agent input
# $3..$N: command directories in decreasing precedence order
#
# Sets:
# - OPENCODE_RESOLVED_PROMPT
# - OPENCODE_RESOLVED_AGENT
# - OPENCODE_RESOLVED_COMMAND_FILE
opencode_resolve_prompt_and_agent() {
  local prompt="${1:-}" agent_input="${2:-}"
  local name file args template command_agent command_dir candidate expanded rest

  OPENCODE_RESOLVED_PROMPT="${prompt}"
  OPENCODE_RESOLVED_AGENT="${agent_input}"
  OPENCODE_RESOLVED_COMMAND_FILE=""

  [[ "${prompt}" =~ ^/([A-Za-z0-9][A-Za-z0-9_:-]*)($|[[:space:]]) ]] || return 0
  name="${BASH_REMATCH[1]}"

  file=""
  for command_dir in "${@:3}"; do
    candidate="${command_dir}/${name}.md"
    if [[ -f "${candidate}" ]]; then
      file="${candidate}"
      break
    fi
  done
  [[ -n "${file}" ]] || return 0
  _opencode_assert_supported_command "${file}" || return 1

  args="${prompt#/"${name}"}"
  args="${args#"${args%%[![:space:]]*}"}"
  template="$(opencode_command_template "${file}")"

  # shellcheck disable=SC2016  # intentional literal placeholder
  if [[ "${template}" == *'$ARGUMENTS'* ]]; then
    expanded=""
    rest="${template}"
    while [[ "${rest}" == *'$ARGUMENTS'* ]]; do
      expanded+="${rest%%\$ARGUMENTS*}${args}"
      rest="${rest#*\$ARGUMENTS}"
    done
    template="${expanded}${rest}"
  elif [[ -n "${args}" ]]; then
    template+=$'\n\n'"${args}"
  fi

  command_agent="$(opencode_command_agent "${file}")"
  OPENCODE_RESOLVED_PROMPT="${template}"
  OPENCODE_RESOLVED_COMMAND_FILE="${file}"
  if [[ -n "${command_agent}" ]]; then
    OPENCODE_RESOLVED_AGENT="${command_agent}"
  fi

  echo "Expanded prompt via OpenCode command '/${name}' (agent: ${OPENCODE_RESOLVED_AGENT:-default})"
}
