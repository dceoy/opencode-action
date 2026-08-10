#!/usr/bin/env bats
# shellcheck disable=SC2016
# Validate stable OpenCode agent, routing, permission, and runtime contracts.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  orchestrator="${agents_dir}/review-pr-orchestrator.md"
  review_pr_command="${repo_root}/.opencode/commands/review-pr.md"
  review_pr_skill="${repo_root}/.opencode/skills/pr-review/SKILL.md"
  opencode_jsonc="${repo_root}/.opencode/opencode.jsonc"
  action_yml="${repo_root}/action.yml"
  run_script="${repo_root}/scripts/run-opencode.sh"
  lib_script="${repo_root}/scripts/opencode-action-lib.sh"
  # shellcheck source=scripts/opencode-action-lib.sh
  source "${lib_script}"
  required_keys=(name description mode permission)
}

agent_files() {
  find "${agents_dir}" -maxdepth 1 -name '*.md' | sort
}

frontmatter() {
  awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$1"
}

frontmatter_has_key() {
  local file="${1}" key="${2}"
  frontmatter "${file}" | grep -qE "^${key}:"
}

frontmatter_value() {
  local file="${1}" key="${2}"
  frontmatter "${file}" | sed -n -E "s/^${key}:[[:space:]]*//p" | head -1
}

permission_allow_keys() {
  local file="${1}" section="${2}"
  frontmatter "${file}" | awk -v section="${section}" '
    $0 == "  " section ":" { active = 1; next }
    active && /^  [a-zA-Z_]+:/ { exit }
    active && /^    .*: allow$/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/: allow$/, "", line)
      first = substr(line, 1, 1)
      last = substr(line, length(line), 1)
      quote = sprintf("%c", 39)
      if ((first == "\"" && last == "\"") || (first == quote && last == quote)) {
        line = substr(line, 2, length(line) - 2)
      }
      print line
    }
  ' | sort
}

reviewer_refs() {
  grep -oE '`[a-z][a-z0-9-]*(reviewer|analyzer|hunter|simplifier)`' "${review_pr_skill}" \
    | tr -d '`' | sort -u
}

routing_line() {
  local aspect="${1}"
  grep -F -- "\`${aspect}\`" "${review_pr_skill}" | grep -E '^- ' | head -1
}

routing_reviewers() {
  local aspect="${1}"
  routing_line "${aspect}" \
    | grep -oE '`[a-z][a-z0-9-]*(reviewer|analyzer|hunter|simplifier)`' \
    | tr -d '`' | sort -u
}

opencode_jsonc_json() {
  opencode_jsonc_to_json < "${opencode_jsonc}"
}

@test "every agent file has valid identifying frontmatter" {
  local f key name base missing=()
  while IFS= read -r f; do
    for key in "${required_keys[@]}"; do
      frontmatter_has_key "${f}" "${key}" || missing+=("${f}: missing ${key}")
    done
    name="$(frontmatter_value "${f}" name)"
    base="$(basename "${f}" .md)"
    [ "${name}" = "${base}" ] || missing+=("${f}: name ${name} != ${base}")
  done < <(agent_files)

  [ "${#missing[@]}" -eq 0 ] || {
    printf '%s\n' "${missing[@]}"
    return 1
  }
}

@test "review-pr command routes to the orchestrator and pr-review skill" {
  [ "$(frontmatter_value "${review_pr_command}" agent)" = "review-pr-orchestrator" ]
  [ "$(frontmatter_value "${review_pr_skill}" name)" = "pr-review" ]

  body="$(awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { in_frontmatter = 0; next }
    !in_frontmatter { print }
  ' "${review_pr_command}")"
  [[ "${body}" == *'`pr-review`'* ]]
  [[ "${body}" == *'$ARGUMENTS'* ]]
}

@test "skill reviewer references exactly match the orchestrator task allow-list" {
  local refs allowed reviewer
  refs="$(reviewer_refs)"
  allowed="$(permission_allow_keys "${orchestrator}" task)"
  [ "${refs}" = "${allowed}" ] || {
    printf 'skill reviewers:\n%s\norchestrator task allow-list:\n%s\n' "${refs}" "${allowed}"
    return 1
  }

  while IFS= read -r reviewer; do
    [ -f "${agents_dir}/${reviewer}.md" ]
  done <<< "${refs}"
}

@test "explicit review aspects route to canonical reviewers" {
  local pair aspect expected actual
  for pair in \
    code:code-reviewer \
    quality:code-reviewer \
    performance:performance-reviewer \
    security:security-code-reviewer \
    tests:test-coverage-reviewer \
    coverage:test-coverage-reviewer \
    docs:documentation-accuracy-reviewer \
    documentation:documentation-accuracy-reviewer \
    comments:documentation-accuracy-reviewer \
    errors:silent-failure-hunter \
    types:type-design-analyzer \
    simplify:code-simplifier; do
    aspect="${pair%%:*}"
    expected="${pair#*:}"
    actual="$(routing_reviewers "${aspect}")"
    [ "${actual}" = "${expected}" ] || {
      echo "${aspect} routes to '${actual}', expected '${expected}'"
      return 1
    }
  done
}

@test "full review keeps exactly the five core reviewers" {
  local line actual expected
  line="$(routing_line all)"
  actual="$(grep -oE '`[a-z][a-z0-9-]*reviewer`' <<< "${line}" | tr -d '`' | sort -u)"
  expected="$(printf '%s\n' \
    code-reviewer \
    documentation-accuracy-reviewer \
    performance-reviewer \
    security-code-reviewer \
    test-coverage-reviewer | sort)"
  [ "${actual}" = "${expected}" ]
}

@test "orchestrator may load only pr-review and approved fixed bash commands" {
  local actual expected helper

  actual="$(permission_allow_keys "${orchestrator}" skill)"
  [ "${actual}" = "pr-review" ]

  actual="$(permission_allow_keys "${orchestrator}" bash)"
  expected="$(printf '%s\n' \
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" context' \
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" diff' \
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" metadata' \
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" validate' \
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" prepare' \
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial' \
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" update' \
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" validate-initial' \
    'git diff --name-only HEAD' \
    'git diff --no-ext-diff' \
    'git status --short' | sort)"
  [ "${actual}" = "${expected}" ] || {
    printf 'unexpected bash allow-list:\n%s\n' "${actual}"
    return 1
  }

  for helper in review-pr-gh.sh review-pr-submit.sh; do
    [ -f "${repo_root}/.opencode/scripts/${helper}" ]
  done
}

@test "external directory access exposes only trusted review helpers and state" {
  local actual expected default_action

  default_action="$(opencode_jsonc_json | jq -r '.permission.external_directory."*" // empty')"
  [ "${default_action}" = "deny" ]

  actual="$(opencode_jsonc_json | jq -r '.permission.external_directory | to_entries[] | select(.key != "*" and .value == "allow") | .key' | sort)"
  expected="$(printf '%s\n' \
    '$HOME/.config/opencode/review-state/*' \
    '$HOME/.config/opencode/scripts/review-pr-gh.sh' \
    '$HOME/.config/opencode/scripts/review-pr-submit.sh' | sort)"
  [ "${actual}" = "${expected}" ]

  actual="$(permission_allow_keys "${orchestrator}" external_directory)"
  [ "${actual}" = "${expected}" ]
}

@test "review-only runtime isolation keeps project config and external skills disabled" {
  grep -Fq 'export OPENCODE_DISABLE_PROJECT_CONFIG=1' "${run_script}"
  grep -Fq 'export OPENCODE_DISABLE_EXTERNAL_SKILLS=1' "${run_script}"
  grep -Fq 'unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT' "${run_script}"
  grep -Fq 'command_dirs=("${ACTION_PATH}/.opencode/commands")' "${run_script}"
}

@test "removed reviewers and legacy helpers have no references" {
  local symbol
  local -a removed=(
    'comment-''analyzer'
    'code-quality-''reviewer'
    'pr-test-''analyzer'
    'opencode_assert_pr_head_''unchanged'
  )

  for symbol in "${removed[@]}"; do
    run git -C "${repo_root}" grep -n -F "${symbol}"
    [ "${status}" -eq 1 ] || {
      echo "stale reference to ${symbol}: ${output}"
      return 1
    }
  done
}

@test "bundled opencode.jsonc parses as JSON" {
  opencode_jsonc_json | jq empty
}

@test "OpenCode version normalization strips only one optional leading lowercase v" {
  local pair input expected

  grep -Fq 'OPENCODE_VERSION="${OPENCODE_VERSION#v}"' "${action_yml}"
  run git -C "${repo_root}" grep -n -F 'tr -d v' -- action.yml scripts
  [ "${status}" -eq 1 ]

  for pair in \
    'v1.2.14=1.2.14' \
    '1.2.14=1.2.14' \
    'v1.2.15-preview.1=1.2.15-preview.1' \
    'v1.2.15-preview.v1=1.2.15-preview.v1'; do
    input="${pair%%=*}"
    expected="${pair#*=}"
    run bash -euo pipefail -c 'version="$1"; printf "%s" "${version#v}"' _ "${input}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
  done
}

@test "variant validation passes through unknown normal-run config surfaces" {
  local case_dir workspace home fixture
  fixture="${BATS_TEST_TMPDIR}/opencode.jsonc"
  cat > "${fixture}" << 'EOF'
{"provider":{"demo":{"models":{"model":{"variants":{}}}}}}
EOF

  for case_dir in config-json singular-plugin plural-plugins home-opencode; do
    workspace="${BATS_TEST_TMPDIR}/${case_dir}/workspace"
    home="${BATS_TEST_TMPDIR}/${case_dir}/home"
    mkdir -p "${workspace}" "${home}"
    case "${case_dir}" in
      config-json)
        printf '{}\n' > "${workspace}/config.json"
        ;;
      singular-plugin)
        mkdir -p "${workspace}/.opencode/plugin"
        printf 'export {}\n' > "${workspace}/.opencode/plugin/demo.js"
        ;;
      plural-plugins)
        mkdir -p "${workspace}/.opencode/plugins"
        printf 'export {}\n' > "${workspace}/.opencode/plugins/demo.js"
        ;;
      home-opencode)
        mkdir -p "${home}/.opencode"
        printf 'source state\n' > "${home}/.opencode/config.json"
        ;;
    esac

    run env \
      HOME="${home}" \
      GITHUB_WORKSPACE="${workspace}" \
      GITHUB_ACTIONS=true \
      RUNNER_ENVIRONMENT=github-hosted \
      USE_BUNDLED_TOOLKIT=true \
      REVIEW_ONLY=false \
      bash -euo pipefail -c '
        source "$1"
        source "$2"
        opencode_validate_variant demo/model thinking "$3"
      ' _ "${run_script}" "${lib_script}" "${fixture}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "::warning::"* ]]
  done
}

@test "isolated GitHub-hosted review rejects unsupported bundled variants" {
  local home workspace fixture
  home="${BATS_TEST_TMPDIR}/authoritative-home"
  workspace="${BATS_TEST_TMPDIR}/authoritative-workspace"
  fixture="${BATS_TEST_TMPDIR}/authoritative.jsonc"
  mkdir -p "${home}" "${workspace}"
  cat > "${fixture}" << 'EOF'
{"provider":{"demo":{"models":{"model":{"variants":{}}}}}}
EOF

  run env \
    HOME="${home}" \
    GITHUB_WORKSPACE="${workspace}" \
    GITHUB_ACTIONS=true \
    RUNNER_ENVIRONMENT=github-hosted \
    USE_BUNDLED_TOOLKIT=true \
    REVIEW_ONLY=true \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant demo/model thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${fixture}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "OpenCode permits only the orchestrator's installed runtime review payloads" {
  local config_home state_dir payload unauthorized_path
  local positive_status positive_output positive_exists
  local negative_status negative_output negative_exists
  local model_config

  command -v opencode > /dev/null || {
    echo "opencode is required for the runtime permission regression"
    return 1
  }

  config_home="$(mktemp -d)"
  state_dir="${config_home}/.config/opencode/review-state"
  payload="${state_dir}/initial.json"
  unauthorized_path="${config_home}/unauthorized.json"
  model_config='{"model":"opencode/big-pickle"}'
  mkdir -p "${config_home}/.config/opencode"
  cp -r "${repo_root}/.opencode/." "${config_home}/.config/opencode/"
  mkdir -p "${state_dir}"

  run env HOME="${config_home}" \
    XDG_CONFIG_HOME="${config_home}/.config" \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    OPENCODE_CONFIG_CONTENT="${model_config}" \
    opencode debug agent review-pr-orchestrator --tool write \
    --params "{filePath:'${payload}',content:'{\"body\":\"test\",\"comments\":[]}' }"
  positive_status="${status}"
  positive_output="${output}"
  positive_exists=false
  [ -f "${payload}" ] && positive_exists=true

  run env HOME="${config_home}" \
    XDG_CONFIG_HOME="${config_home}/.config" \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    OPENCODE_CONFIG_CONTENT="${model_config}" \
    opencode debug agent review-pr-orchestrator --tool write \
    --params "{filePath:'${unauthorized_path}',content:'denied'}"
  negative_status="${status}"
  negative_output="${output}"
  negative_exists=false
  [ -f "${unauthorized_path}" ] && negative_exists=true
  rm -rf "${config_home}"

  [ "${positive_status}" -eq 0 ] || {
    echo "OpenCode denied the orchestrator runtime payload write: ${positive_output}"
    return 1
  }
  [ "${positive_exists}" = true ] || {
    echo "OpenCode reported success without creating the runtime payload: ${positive_output}"
    return 1
  }
  [[ "${positive_output}" == *'Wrote file successfully.'* ]] || {
    echo "OpenCode did not report a successful runtime payload write: ${positive_output}"
    return 1
  }
  [ "${negative_status}" -ne 0 ] || {
    echo "OpenCode allowed an unrelated external write: ${negative_output}"
    return 1
  }
  [ "${negative_exists}" = false ] || {
    echo "OpenCode created an unrelated external file despite the deny boundary: ${negative_output}"
    return 1
  }
}
