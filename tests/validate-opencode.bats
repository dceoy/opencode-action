#!/usr/bin/env bats
# Validate .opencode/ agent and skill frontmatter, pr-review references, that
# opencode.jsonc parses, and that its external_directory permission allow-lists
# the resolver path the skill actually sources and the runtime review-state
# directory pattern.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  review_pr_command="${repo_root}/.opencode/commands/review-pr.md"
  review_pr_skill="${repo_root}/.opencode/skills/pr-review/SKILL.md"
  opencode_jsonc="${repo_root}/.opencode/opencode.jsonc"
  # shellcheck source=scripts/opencode-action-lib.sh
  source "${repo_root}/scripts/opencode-action-lib.sh"
  required_keys=(name description mode permission)
  # Backtick-quoted identifiers in the pr-review skill that are skills, toolkits, or
  # config inputs rather than agents.
  non_agents=(pr-feedback-triage pr-review-toolkit use-github-token)
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

@test "pr-review skill has valid frontmatter" {
  local fm name description

  fm="$(frontmatter "${review_pr_skill}")"
  name="$(grep -E '^name:' <<<"${fm}" | sed -E 's/^name:[[:space:]]*//')"
  description="$(grep -E '^description:' <<<"${fm}" | sed -E 's/^description:[[:space:]]*//')"

  [ "${name}" = "pr-review" ]
  [ -n "${description}" ]
}

@test "review-pr command is a thin wrapper around the pr-review skill" {
  local body

  body="$(awk '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { in_frontmatter = 0; next }
    !in_frontmatter && NF { print }
  ' "${review_pr_command}")"

  [ "${body}" = $'Load and follow the `pr-review` skill.\nRequested review aspects: "$ARGUMENTS"' ]
}

@test "review-pr orchestrator may load only the pr-review skill" {
  local orchestrator="${agents_dir}/review-pr-orchestrator.md"

  grep -Fq '  skill:' "${orchestrator}"
  grep -Fq '    "*": deny' "${orchestrator}"
  grep -Fq '    pr-review: allow' "${orchestrator}"
}

@test "review-pr default selection names the core six reviewers" {
  local reviewer

  # shellcheck disable=SC2016
  grep -Fq 'the core reviewers `code-quality-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, `security-code-reviewer`, and `code-reviewer`' "${review_pr_skill}"
  grep -Fq 'include specialty reviewers when the supplied diff is relevant' "${review_pr_skill}"

  for reviewer in \
    code-quality-reviewer \
    performance-reviewer \
    test-coverage-reviewer \
    documentation-accuracy-reviewer \
    security-code-reviewer \
    code-reviewer; do
    grep -Fq "${reviewer}" "${review_pr_skill}"
  done
}

@test "review-pr explicit core aspects force their documented reviewers" {
  # shellcheck disable=SC2016
  grep -Fq -- '- `performance`: `performance-reviewer`' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq -- '- `security`: `security-code-reviewer`' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq -- '- `tests` or `coverage`: `test-coverage-reviewer`, `pr-test-analyzer`' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq -- '- `docs` or `documentation`: `documentation-accuracy-reviewer`' "${review_pr_skill}"
  grep -Fq 'Requested aspects always force their mapped reviewers.' "${review_pr_skill}"
}

@test "review-pr sends reviewer-specific context subsets" {
  grep -Fq 'classify changed files and individual diff hunks by concern' "${review_pr_skill}"
  grep -Fq 'Build a separate, minimal Task request for every selected reviewer.' "${review_pr_skill}"
  grep -Fq 'Include only its relevant files, diff hunks, and containing-function source context' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq '`code-reviewer` may receive the complete changed-file list, but do not include unrelated full-file contents.' "${review_pr_skill}"
}

@test "every agent referenced in the pr-review skill exists under .opencode/agents/" {
  local bt pattern refs ref skip na missing=()
  bt=$(printf '\x60')
  pattern="${bt}[a-z][a-z0-9]+(-[a-z0-9]+)+${bt}"
  mapfile -t refs < <(grep -hoE "${pattern}" "${review_pr_skill}" | tr -d "${bt}" | sort -u)

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
  opencode_jsonc_json | jq empty
}

@test "review-pr local fallback is limited to a missing trusted PR number" {
  # shellcheck disable=SC2016
  grep -Fq 'If `context` reports `Trusted pull request number is unavailable.`, continue in local mode; for every other `context` failure, stop.' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq 'Once `context` succeeds, any later metadata, diff, or validation failure must abort the review rather than falling back to local mode.' "${review_pr_skill}"
}

@test "code-quality findings retain rich actionable Markdown" {
  local quality_reviewer="${agents_dir}/code-quality-reviewer.md"

  grep -Fq 'message: |-' "${quality_reviewer}"
  grep -Fq '<what is wrong and the behavior that demonstrates it>' "${quality_reviewer}"
  grep -Fq 'why it matters to users or maintainers' "${quality_reviewer}"
  grep -Fq '<a concrete fix, including a fenced suggestion when it can be applied safely>' "${quality_reviewer}"
  grep -Fq '```suggestion' "${quality_reviewer}"
  grep -Fq "Preserve each finding message's Markdown" "${review_pr_skill}"
  grep -Fq 'followed by a blank line and the unmodified finding message' "${review_pr_skill}"
  grep -Fq 'message: |-' "${review_pr_skill}"
  grep -Fq '<actionable Markdown with the issue, impact, and concrete fix>' "${review_pr_skill}"
}

@test "suggestion blocks are withheld or stripped for relocated anchors" {
  local quality_reviewer="${agents_dir}/code-quality-reviewer.md"

  grep -Fq 'reported line is not itself a head-side changed' "${quality_reviewer}"
  # shellcheck disable=SC2016
  grep -Fq 'strip any `suggestion` block from its message before submission' "${review_pr_skill}"
}

opencode_jsonc_json() {
  opencode_jsonc_to_json < "${opencode_jsonc}"
}

@test "pr-review skill sources the resolver from a path opencode.jsonc allow-lists under external_directory" {
  local resolver_suffix resolver_path default_action allow_patterns pattern expanded matched=0

  resolver_suffix="$(grep -oE 'opencode_app_token_lib="\$\{HOME\}/[^"]+"' "${review_pr_skill}" | head -1 | sed -E 's/^opencode_app_token_lib="\$\{HOME\}\/(.*)"$/\1/')"
  [ -n "${resolver_suffix}" ] || {
    echo "pr-review skill does not set opencode_app_token_lib to a \${HOME}-relative path"
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
    echo "no external_directory allow pattern (${allow_patterns[*]}) matches the resolver path ${resolver_path} that the pr-review skill sources"
    return 1
  }
}

@test "OpenCode permits only the orchestrator's installed runtime review payloads" {
  local config_home state_dir payload unauthorized_path
  local positive_status positive_output positive_exists
  local negative_status negative_output negative_exists
  local model_config

  command -v opencode >/dev/null || {
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
