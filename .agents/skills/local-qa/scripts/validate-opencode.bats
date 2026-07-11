#!/usr/bin/env bats
# Validate .opencode/ agent frontmatter, review-pr command/skill references,
# that opencode.jsonc parses, and that its external_directory permission
# allow-lists the resolver path review-pr.md actually sources.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  review_pr_doc="${repo_root}/.opencode/commands/review-pr.md"
  opencode_jsonc="${repo_root}/.opencode/opencode.jsonc"
  action_yml="${repo_root}/action.yml"
  required_keys=(name description mode permission)
  # Backtick-quoted identifiers in review-pr.md that are skills, toolkits, or
  # config inputs rather than agents.
  non_agents=(pr-feedback-triage pr-review-toolkit use-github-token)
  review_orchestrator="${agents_dir}/review-pr-orchestrator.md"
  review_agents=(
    code-reviewer code-quality-reviewer performance-reviewer security-code-reviewer
    test-coverage-reviewer pr-test-analyzer documentation-accuracy-reviewer
    comment-analyzer silent-failure-hunter type-design-analyzer
  )
}

agent_files() {
  find "${agents_dir}" -maxdepth 1 -name '*.md' | sort
}

frontmatter() {
  awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$1"
}

@test "every agent file has YAML frontmatter" {
  local f fm without_frontmatter=()
  while IFS= read -r f; do
    fm="$(frontmatter "${f}")"
    [ -n "${fm}" ] || without_frontmatter+=("${f}")
  done < <(agent_files)

  [ "${#without_frontmatter[@]}" -eq 0 ] || {
    printf 'no YAML frontmatter: %s\n' "${without_frontmatter[@]}"
    return 1
  }
}

@test "every agent frontmatter has the required keys" {
  local f fm key missing=()
  while IFS= read -r f; do
    fm="$(frontmatter "${f}")"
    for key in "${required_keys[@]}"; do
      grep -qE "^${key}:" <<<"${fm}" || missing+=("${f}: missing '${key}'")
    done
  done < <(agent_files)

  [ "${#missing[@]}" -eq 0 ] || {
    printf '%s\n' "${missing[@]}"
    return 1
  }
}

@test "every agent frontmatter name matches its filename" {
  local f fm name base mismatches=()
  while IFS= read -r f; do
    fm="$(frontmatter "${f}")"
    name="$(grep -E '^name:' <<<"${fm}" | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')"
    base="$(basename "${f}" .md)"
    [ "${name}" = "${base}" ] || mismatches+=("${f}: name '${name}' != filename '${base}'")
  done < <(agent_files)

  [ "${#mismatches[@]}" -eq 0 ] || {
    printf '%s\n' "${mismatches[@]}"
    return 1
  }
}

@test "every agent referenced in review-pr.md exists under .opencode/agents/" {
  local bt pattern refs ref skip na missing=()
  bt=$(printf '\x60')
  pattern="${bt}[a-z][a-z0-9]+(-[a-z0-9]+)+${bt}"
  mapfile -t refs < <(grep -hoE "${pattern}" "${review_pr_doc}" | tr -d "${bt}" | sort -u)

  for ref in "${refs[@]}"; do
    skip=0
    for na in "${non_agents[@]}"; do
      [ "${ref}" = "${na}" ] && skip=1
    done
    [ "${skip}" -eq 1 ] && continue
    [ -f "${agents_dir}/${ref}.md" ] || missing+=("${ref}")
  done

  [ "${#missing[@]}" -eq 0 ] || {
    printf 'referenced agent has no file under .opencode/agents/: %s\n' "${missing[@]}"
    return 1
  }
}

@test "opencode.jsonc parses as JSON once its // comments are stripped" {
  sed -E 's#^[[:space:]]*//.*$##' "${opencode_jsonc}" | jq empty
}

opencode_jsonc_json() {
  sed -E 's#^[[:space:]]*//.*$##' "${opencode_jsonc}"
}

@test "opencode.jsonc allow-lists every review-pr script under external_directory" {
  local default_action allow_patterns pattern expanded script scripts matched

  scripts=(resolve-app-token.sh review-pr-worktree-guard.sh review-pr-submit.sh review-pr-gh.sh)

  default_action="$(opencode_jsonc_json | jq -r '.permission.external_directory."*" // empty')"
  [ "${default_action}" = "deny" ] || {
    echo "opencode.jsonc's external_directory has no catch-all \"*\": \"deny\" rule (got: '${default_action}')"
    return 1
  }

  mapfile -t allow_patterns < <(opencode_jsonc_json | jq -r '.permission.external_directory | to_entries[] | select(.key != "*" and .value == "allow") | .key')
  [ "${#allow_patterns[@]}" -gt 0 ] || {
    echo "opencode.jsonc's external_directory has no narrow allow rule"
    return 1
  }

  for script in "${scripts[@]}"; do
    matched=0
    for pattern in "${allow_patterns[@]}"; do
      expanded="${pattern/#\$HOME/${HOME}}"
      expanded="${expanded/#~/${HOME}}"
      # shellcheck disable=SC2053
      [[ "${HOME}/.config/opencode/scripts/${script}" == ${expanded} ]] && matched=1
    done
    [ "${matched}" -eq 1 ] || {
      echo "no external_directory allow pattern (${allow_patterns[*]}) matches ${HOME}/.config/opencode/scripts/${script}"
      return 1
    }
  done
}

@test "review-pr.md and its orchestrator never invoke a review-pr script by a repository-relative path" {
  local script scripts=(review-pr-worktree-guard.sh review-pr-submit.sh review-pr-gh.sh)
  local found=()

  for script in "${scripts[@]}"; do
    grep -qE "bash \.opencode/scripts/${script//./\\.}" "${review_pr_doc}" "${review_orchestrator}" && found+=("${script}")
  done

  [ "${#found[@]}" -eq 0 ] || {
    printf 'repository-relative invocation of trust-sensitive script(s): %s\n' "${found[@]}"
    return 1
  }
}

@test "review-pr.md invokes every review-pr script only via its \$HOME-anchored path" {
  local script scripts=(review-pr-worktree-guard.sh review-pr-submit.sh review-pr-gh.sh)
  local missing=()

  for script in "${scripts[@]}"; do
    grep -qF "\"\$HOME/.config/opencode/scripts/${script}\"" "${review_pr_doc}" || missing+=("${script}")
  done

  [ "${#missing[@]}" -eq 0 ] || {
    # shellcheck disable=SC2016
    printf 'review-pr.md never invokes %s via its $HOME-anchored path\n' "${missing[@]}"
    return 1
  }
}

@test "review-pr uses the dedicated fail-closed review orchestrator" {
  local fm
  grep -qx 'agent: review-pr-orchestrator' "${review_pr_doc}"
  if grep -qE '^agent: (general|build)$' "${review_pr_doc}"; then
    echo "review-pr must not use general or build"
    return 1
  fi
  [ -f "${review_orchestrator}" ]
  fm="$(frontmatter "${review_orchestrator}")"
  grep -qE '^mode: primary$' <<<"${fm}"
  grep -qE '^  edit: deny$' <<<"${fm}"
  grep -qE '^  lsp: deny$' <<<"${fm}"
  grep -qE '^  skill: deny$' <<<"${fm}"
  grep -qF '    "*": deny' <<<"${fm}"
}

@test "every review-pr reviewer has explicit read-only permissions and invariant" {
  local agent fm path
  for agent in "${review_agents[@]}"; do
    path="${agents_dir}/${agent}.md"
    fm="$(frontmatter "${path}")"
    grep -qE '^  read: allow$' <<<"${fm}"
    grep -qE '^  glob: allow$' <<<"${fm}"
    grep -qE '^  grep: allow$' <<<"${fm}"
    grep -qE '^  lsp: deny$' <<<"${fm}"
    grep -qE '^  edit: deny$' <<<"${fm}"
    grep -qE '^  bash: deny$' <<<"${fm}"
    grep -qE '^  task: deny$' <<<"${fm}"
    grep -qE '^  skill: deny$' <<<"${fm}"
    grep -qE '^  webfetch: deny$' <<<"${fm}"
    grep -qE '^  websearch: deny$' <<<"${fm}"
    grep -qF 'This is a strictly read-only repository review. Analyze and report only.' "${path}"
  done
}

@test "review-pr cannot dispatch code-simplifier and has no broad command allow rules" {
  local fm
  if grep -qE "→[[:space:]]*\`code-simplifier\`" "${review_pr_doc}"; then
    echo "review-pr must not route to code-simplifier"
    return 1
  fi
  grep -qF '/review-pr simplify` is unavailable' "${review_pr_doc}"
  fm="$(frontmatter "${review_orchestrator}")"
  if grep -qE '"(git|gh|bash|uv|npm|npx) *": allow' <<<"${fm}"; then
    echo "review orchestrator has a broad command allow rule"
    return 1
  fi
  if grep -qE 'gh api|git (add|commit|push|reset|restore|checkout|switch|clean|stash|merge|rebase|cherry-pick|apply|am)' "${review_pr_doc}"; then
    echo "review-pr documents an unsafe command"
    return 1
  fi
}

@test "the Run OpenCode step disables project config only for the dedicated review-only entrypoint" {
  local steps run_step_env

  steps="$(yq -o=json '.runs.steps' "${action_yml}")"
  run_step_env="$(jq -r '.[] | select(.name == "Run OpenCode") | .env.OPENCODE_DISABLE_PROJECT_CONFIG // empty' <<<"${steps}")"

  [ -n "${run_step_env}" ] || {
    echo "action.yml's \"Run OpenCode\" step does not set OPENCODE_DISABLE_PROJECT_CONFIG"
    return 1
  }
  [[ "${run_step_env}" == *"inputs.enable-toolkit == 'true'"* ]] || {
    echo "OPENCODE_DISABLE_PROJECT_CONFIG is not conditioned on inputs.enable-toolkit (got: '${run_step_env}')"
    return 1
  }
  [[ "${run_step_env}" == *"inputs.review-only == 'true'"* ]] || {
    echo "OPENCODE_DISABLE_PROJECT_CONFIG is not conditioned on inputs.review-only, so it would also disable project config (and AGENTS.md) for mutation-capable workflows (got: '${run_step_env}')"
    return 1
  }
}

@test "action.yml declares a review-only input defaulting to false" {
  local inputs review_only_default

  inputs="$(yq -o=json '.inputs' "${action_yml}")"
  review_only_default="$(jq -r '."review-only".default // empty' <<<"${inputs}")"

  [ "${review_only_default}" = "false" ] || {
    echo "action.yml's review-only input does not default to 'false' (got: '${review_only_default}')"
    return 1
  }
}

@test "the Copy bundled OpenCode config step installs into a fresh directory only for review-only" {
  local steps copy_step_run copy_step_env

  steps="$(yq -o=json '.runs.steps' "${action_yml}")"
  copy_step_run="$(jq -r '.[] | select(.name == "Copy bundled OpenCode config") | .run // empty' <<<"${steps}")"
  copy_step_env="$(jq -r '.[] | select(.name == "Copy bundled OpenCode config") | .env.REVIEW_ONLY // empty' <<<"${steps}")"

  [ -n "${copy_step_run}" ] || {
    echo "action.yml has no \"Copy bundled OpenCode config\" step"
    return 1
  }
  [[ "${copy_step_env}" == *"inputs.review-only"* ]] || {
    echo "Copy bundled OpenCode config step does not pass inputs.review-only through as REVIEW_ONLY (got: '${copy_step_env}')"
    return 1
  }
  grep -qF "if [[ \"\${REVIEW_ONLY}\" == \"true\" ]]; then" <<<"${copy_step_run}" || {
    echo "Copy bundled OpenCode config step does not branch on REVIEW_ONLY"
    return 1
  }
  grep -qF "rm -rf \"\${HOME}/.config/opencode\"" <<<"${copy_step_run}" || {
    echo "Copy bundled OpenCode config step does not remove pre-existing ~/.config/opencode content in the review-only branch"
    return 1
  }
  grep -qF -- '-rn ' <<<"${copy_step_run}" || {
    echo "Copy bundled OpenCode config step no longer preserves pre-existing content for mutation-capable (non-review-only) workflows"
    return 1
  }
}

@test "review-only fails fast when enable-toolkit, agent, or prompt do not satisfy the read-only entrypoint" {
  local steps validate_step_run validate_step_if

  steps="$(yq -o=json '.runs.steps' "${action_yml}")"
  validate_step_run="$(jq -r '.[] | select(.name == "Validate review-only configuration") | .run // empty' <<<"${steps}")"
  validate_step_if="$(jq -r '.[] | select(.name == "Validate review-only configuration") | .["if"] // empty' <<<"${steps}")"

  [ -n "${validate_step_run}" ] || {
    echo "action.yml has no \"Validate review-only configuration\" step"
    return 1
  }
  [[ "${validate_step_if}" == *"inputs.review-only == 'true'"* ]] || {
    echo "Validate review-only configuration step does not run only when inputs.review-only == 'true' (got: '${validate_step_if}')"
    return 1
  }
  grep -qF 'ENABLE_TOOLKIT' <<<"${validate_step_run}" || {
    echo "Validate review-only configuration step does not reject enable-toolkit != true"
    return 1
  }
  grep -qF 'AGENT' <<<"${validate_step_run}" || {
    echo "Validate review-only configuration step does not reject an unexpected agent"
    return 1
  }
  grep -qF 'PROMPT' <<<"${validate_step_run}" || {
    echo "Validate review-only configuration step does not reject a prompt that does not invoke /review-pr"
    return 1
  }
}
