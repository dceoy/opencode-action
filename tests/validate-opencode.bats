#!/usr/bin/env bats
# Validate .opencode/ agent and skill frontmatter, pr-review routing and
# references, release examples, opencode.jsonc parsing, and the runtime
# read-only review permission boundary.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  review_pr_command="${repo_root}/.opencode/commands/review-pr.md"
  review_pr_skill="${repo_root}/.opencode/skills/pr-review/SKILL.md"
  opencode_jsonc="${repo_root}/.opencode/opencode.jsonc"
  # shellcheck source=scripts/opencode-action-lib.sh
  source "${repo_root}/scripts/opencode-action-lib.sh"
  required_keys=(name description mode permission)
  # Backtick-quoted identifiers in the pr-review skill that are operations or
  # inputs rather than agents.
  non_agents=(submit-initial use-github-token validate-initial)
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
      grep -qE "^${key}:" <<< "${fm}" || missing+=("${f}: missing '${key}'")
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
    name="$(grep -E '^name:' <<< "${fm}" | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')"
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
  name="$(grep -E '^name:' <<< "${fm}" | sed -E 's/^name:[[:space:]]*//')"
  description="$(grep -E '^description:' <<< "${fm}" | sed -E 's/^description:[[:space:]]*//')"

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

@test "review-pr default selection uses five core reviewers for all documented dimensions" {
  local reviewer

  # shellcheck disable=SC2016
  grep -Fq 'the core reviewers `code-reviewer`, `performance-reviewer`, `test-coverage-reviewer`, `documentation-accuracy-reviewer`, and `security-code-reviewer`' "${review_pr_skill}"
  grep -Fq 'The five core reviewers still cover the six documented default dimensions' "${review_pr_skill}"
  grep -Fq 'include specialty reviewers when the supplied diff is relevant' "${review_pr_skill}"

  for reviewer in \
    code-reviewer \
    performance-reviewer \
    test-coverage-reviewer \
    documentation-accuracy-reviewer \
    security-code-reviewer; do
    grep -Fq "${reviewer}" "${review_pr_skill}"
  done
}

@test "review-pr explicit core aspects force one canonical reviewer each" {
  # shellcheck disable=SC2016
  grep -Fq -- '- `code` or `quality`: `code-reviewer`' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq -- '- `performance`: `performance-reviewer`' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq -- '- `security`: `security-code-reviewer`' "${review_pr_skill}"
  # shellcheck disable=SC2016
  grep -Fq -- '- `tests` or `coverage`: `test-coverage-reviewer`' "${review_pr_skill}"
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

@test "removed reviewer and legacy helper names have no remaining references" {
  local legacy_symbol removed_a removed_b

  legacy_symbol='opencode_assert_pr_head_''unchanged'
  removed_a='code-quality-''reviewer'
  removed_b='pr-test-''analyzer'

  run git -C "${repo_root}" grep -n -F "${legacy_symbol}"
  [ "${status}" -eq 1 ]

  run git -C "${repo_root}" grep -n -F "${removed_a}"
  [ "${status}" -eq 1 ]

  run git -C "${repo_root}" grep -n -F "${removed_b}"
  [ "${status}" -eq 1 ]
}

@test "copyable action examples pin the current release" {
  local expected
  expected='uses: dceoy/opencode-action@da47df8f9d60c12de7b76dc1ca37633b147f0241 # v0.6.4'

  grep -Fq "${expected}" "${repo_root}/README.md"
  grep -Fq "${expected}" "${repo_root}/docs/pull-request-reviews.md"
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

@test "canonical code findings retain rich actionable Markdown" {
  local code_reviewer="${agents_dir}/code-reviewer.md"

  grep -Fq 'message: |-' "${code_reviewer}"
  grep -Fq '<what is wrong and the behavior that demonstrates it>' "${code_reviewer}"
  grep -Fq 'why it matters to users or maintainers' "${code_reviewer}"
  grep -Fq '<a concrete fix, including a fenced suggestion when it can be applied safely>' "${code_reviewer}"
  grep -Fq '```suggestion' "${code_reviewer}"
  grep -Fq "Preserve each finding message's Markdown" "${review_pr_skill}"
  grep -Fq 'followed by a blank line and the unmodified finding message' "${review_pr_skill}"
  grep -Fq 'message: |-' "${review_pr_skill}"
  grep -Fq '<actionable Markdown with the issue, impact, and concrete fix>' "${review_pr_skill}"
}

@test "suggestion blocks are withheld or stripped for relocated anchors" {
  local code_reviewer="${agents_dir}/code-reviewer.md"

  grep -Fq 'reported line is not itself a head-side changed line' "${code_reviewer}"
  # shellcheck disable=SC2016
  grep -Fq 'strip any `suggestion` block from its message before submission' "${review_pr_skill}"
}

opencode_jsonc_json() {
  opencode_jsonc_to_json < "${opencode_jsonc}"
}

@test "external directory allow-list exposes only invoked review helpers and payload state" {
  local default_action
  local -a allow_patterns expected_patterns

  default_action="$(opencode_jsonc_json | jq -r '.permission.external_directory."*" // empty')"
  [ "${default_action}" = "deny" ] || {
    echo "opencode.jsonc's external_directory has no catch-all \"*\": \"deny\" rule (got: '${default_action}')"
    return 1
  }

  mapfile -t allow_patterns < <(opencode_jsonc_json | jq -r '.permission.external_directory | to_entries[] | select(.key != "*" and .value == "allow") | .key' | sort)
  expected_patterns=(
    "\$HOME/.config/opencode/review-state/*"
    "\$HOME/.config/opencode/scripts/review-pr-gh.sh"
    "\$HOME/.config/opencode/scripts/review-pr-submit.sh"
  )
  mapfile -t expected_patterns < <(printf '%s\n' "${expected_patterns[@]}" | sort)

  [ "${allow_patterns[*]}" = "${expected_patterns[*]}" ] || {
    printf 'unexpected external_directory allow rules: %s\n' "${allow_patterns[*]}"
    return 1
  }
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
