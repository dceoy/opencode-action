#!/usr/bin/env bats
# Validate .opencode/ agent frontmatter, review-pr command/skill references,
# that opencode.jsonc parses, and that its external_directory permission
# allow-lists the resolver path review-pr.md actually sources.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  review_pr_doc="${repo_root}/.opencode/commands/review-pr.md"
  opencode_jsonc="${repo_root}/.opencode/opencode.jsonc"
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

@test "review-pr preserves the resolver path opencode.jsonc allow-lists under external_directory" {
  local resolver_suffix resolver_path default_action allow_patterns pattern expanded matched=0

  resolver_suffix="$(grep -oE 'opencode_app_token_lib="\$\{HOME\}/[^"]+"' "${review_pr_doc}" | head -1 | sed -E 's/^opencode_app_token_lib="\$\{HOME\}\/(.*)"$/\1/')"
  [ -n "${resolver_suffix}" ] || {
    echo "review-pr.md does not set opencode_app_token_lib to a \${HOME}-relative path"
    return 1
  }
  resolver_path="${HOME}/${resolver_suffix}"

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

  for pattern in "${allow_patterns[@]}"; do
    expanded="${pattern/#\$HOME/${HOME}}"
    expanded="${expanded/#~/${HOME}}"
    # shellcheck disable=SC2053
    [[ "${resolver_path}" == ${expanded} ]] && matched=1
  done

  [ "${matched}" -eq 1 ] || {
    echo "no external_directory allow pattern (${allow_patterns[*]}) matches the resolver path ${resolver_path} that review-pr.md sources"
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
    grep -qE '^  lsp: allow$' <<<"${fm}"
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
