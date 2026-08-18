#!/usr/bin/env bats
# shellcheck disable=SC2016
# Validate stable OpenCode agent, routing, permission, and runtime contracts.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  orchestrator="${agents_dir}/review-pr-orchestrator.md"
  review_worker="${agents_dir}/review-worker.md"
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

routing_line() {
  local aspect="${1}"
  grep -F -- "\`${aspect}\`" "${review_pr_skill}" | grep -E '^- ' | head -1
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

@test "review-pr command routes to the orchestrator and internal pr-review skill" {
  [ "$(frontmatter_value "${review_pr_command}" agent)" = "review-pr-orchestrator" ]
  [ "$(frontmatter_value "${review_pr_skill}" name)" = "pr-review" ]
  grep -Fq 'opencode/slash: "false"' "${review_pr_skill}"
  grep -Fq 'opencode/autoinvoke: "false"' "${review_pr_skill}"

  body="$(awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { in_frontmatter = 0; next }
    !in_frontmatter { print }
  ' "${review_pr_command}")"
  [[ "${body}" == *'`pr-review`'* ]]
  [[ "${body}" == *'$ARGUMENTS'* ]]
}

@test "pr-review uses exactly one generic read-only subagent" {
  local actual legacy

  [ -f "${review_worker}" ]
  [ "$(frontmatter_value "${review_worker}" mode)" = "subagent" ]
  [ "$(frontmatter_value "${review_worker}" hidden)" = "true" ]
  grep -Fq 'TASK KIND: discovery | validation' "${review_worker}"
  grep -Fq 'fresh `review-worker` Task' "${review_pr_skill}"

  actual="$(permission_allow_keys "${orchestrator}" task)"
  [ "${actual}" = "review-worker" ] || {
    printf 'unexpected task allow-list:\n%s\n' "${actual}"
    return 1
  }

  for legacy in \
    code-reviewer \
    code-simplifier \
    documentation-accuracy-reviewer \
    finding-reviewer \
    performance-reviewer \
    security-code-reviewer \
    silent-failure-hunter \
    test-coverage-reviewer \
    type-design-analyzer; do
    [ ! -e "${agents_dir}/${legacy}.md" ] || {
      echo "legacy fixed subagent remains: ${legacy}"
      return 1
    }
  done
}

@test "review-worker denies bash, edit, and task and only allows read, glob, and grep" {
  local perm actual expected

  perm="$(frontmatter "${review_worker}")"

  actual="$(printf '%s\n' "${perm}" | grep -oE '^  ("[^"]+"|[a-zA-Z_]+):' | sed -E 's/^  //; s/:$//' | sort)"
  expected="$(printf '%s\n' '"*"' glob grep read | sort)"
  [ "${actual}" = "${expected}" ] || {
    printf 'unexpected top-level review-worker permission keys:\n%s\n' "${actual}"
    return 1
  }

  printf '%s\n' "${perm}" | grep -qE '^  "\*": deny$'
  printf '%s\n' "${perm}" | grep -qE '^  glob: allow$'
  printf '%s\n' "${perm}" | grep -qE '^  grep: allow$'
  printf '%s\n' "${perm}" | grep -qE '^    "\*": allow$'
  printf '%s\n' "${perm}" | grep -qE '^    "\*\.env": deny$'
  printf '%s\n' "${perm}" | grep -qE '^    "\*\.env\.\*": deny$'
  printf '%s\n' "${perm}" | grep -qE '^    "\*\.env\.example": allow$'
}

@test "explicit review aspects map to lenses instead of fixed agent identities" {
  local aspect line keyword

  for aspect in code quality performance security tests coverage docs documentation comments errors types simplify all; do
    line="$(routing_line "${aspect}")"
    [ -n "${line}" ] || {
      echo "missing lens mapping for ${aspect}"
      return 1
    }

    case "${aspect}" in
      code | quality) keyword="maintainability issues" ;;
      performance) keyword="algorithmic complexity" ;;
      security) keyword="fail-secure behavior" ;;
      tests | coverage) keyword="test quality" ;;
      docs | documentation) keyword="operational guidance" ;;
      comments) keyword="implementation claims" ;;
      errors) keyword="silent-failure risks" ;;
      types) keyword="serialization contracts" ;;
      simplify) keyword="KISS, DRY, and YAGNI" ;;
      all) keyword="risk-driven lenses" ;;
      *)
        echo "no keyword mapping for aspect ${aspect}"
        return 1
        ;;
    esac
    [[ "${line}" == *"${keyword}"* ]] || {
      echo "lens body for ${aspect} missing expected keyword '${keyword}': ${line}"
      return 1
    }
  done

  run grep -E 'code-reviewer|code-simplifier|documentation-accuracy-reviewer|finding-reviewer|performance-reviewer|security-code-reviewer|silent-failure-hunter|test-coverage-reviewer|type-design-analyzer' "${review_pr_skill}"
  [ "${status}" -eq 1 ]
}

@test "unscoped review uses baseline coverage and risk-driven dynamic roles" {
  grep -Fq 'baseline correctness, regression, tests, and documentation checks' "${review_pr_skill}"
  grep -Fq 'typically 2-6 discovery tasks' "${review_pr_skill}"
  grep -Fq 'dynamic role name describing the actual risk under review' "${review_pr_skill}"
  grep -Fq 'never reuse the discovery Task session for validation' "${review_pr_skill}"
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

@test "trusted review external-directory access is agent-scoped" {
  local global_allow actual expected default_action

  default_action="$(opencode_jsonc_json | jq -r '.permission.external_directory."*" // empty')"
  [ "${default_action}" = "deny" ]

  global_allow="$(opencode_jsonc_json | jq -r '.permission.external_directory | to_entries[] | select(.key != "*" and .value == "allow") | .key' | sort)"
  [ -z "${global_allow}" ] || {
    printf 'unexpected global external-directory allow entries:\n%s\n' "${global_allow}"
    return 1
  }

  expected="$(printf '%s\n' \
    '$HOME/.config/opencode/review-state/*' \
    '$HOME/.config/opencode/scripts/review-pr-gh.sh' \
    '$HOME/.config/opencode/scripts/review-pr-submit.sh' | sort)"
  actual="$(permission_allow_keys "${orchestrator}" external_directory)"
  [ "${actual}" = "${expected}" ]
}

@test "review-only runtime isolation keeps project config and external skills disabled" {
  grep -Fq 'export OPENCODE_DISABLE_PROJECT_CONFIG=1' "${run_script}"
  grep -Fq 'export OPENCODE_DISABLE_EXTERNAL_SKILLS=1' "${run_script}"
  grep -Fq 'unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT' "${run_script}"
  grep -Fq 'command_dirs=("${ACTION_PATH}/.opencode/commands")' "${run_script}"
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
