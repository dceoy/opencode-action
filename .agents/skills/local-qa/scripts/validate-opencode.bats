#!/usr/bin/env bats
# Validate .opencode agent frontmatter, command references, and workflow token
# boundaries.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  agents_dir="${repo_root}/.opencode/agents"
  review_pr_doc="${repo_root}/.opencode/commands/review-pr.md"
  opencode_jsonc="${repo_root}/.opencode/opencode.jsonc"
  required_keys=(name description mode permission)
  # Backtick-quoted identifiers in review-pr.md that are skills, toolkits, or
  # config inputs rather than agents.
  non_agents=(use-github-token)
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

@test "bundled review workflow uses the read-scoped workflow token" {
  local workflow="${repo_root}/.github/workflows/opencode.yml"
  # shellcheck disable=SC2016 # Ruby interpolation is intentionally literal.
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV[0])
    job = workflow.fetch("jobs").fetch("opencode-review")
    permissions = job.fetch("permissions")
    expected = {"contents" => "read", "pull-requests" => "write"}
    abort "unexpected review permissions: #{permissions}" unless permissions == expected
    checkout = job.fetch("steps").find { |step| step["name"] == "Checkout repository" }.fetch("with")
    abort unless checkout["persist-credentials"] == false && checkout["token"] == "${{ github.token }}"
    run = job.fetch("steps").find { |step| step["name"] == "Run OpenCode" }
    abort unless run.fetch("env") == {"OPENCODE_API_KEY" => "${{ secrets.OPENCODE_API_KEY }}", "GITHUB_TOKEN" => "${{ github.token }}"}
    action = run.fetch("with")
    abort unless action["use-github-token"] == true && !action.key?("review-only")
  ' "${workflow}"
  [ "${status}" -eq 0 ]
}

@test "review analysis uses the confined action-owned agent" {
  local fm
  grep -Fq 'agent: review-analyzer' "${review_pr_doc}"
  fm="$(frontmatter "${agents_dir}/review-analyzer.md")"
  grep -q '^  bash: deny$' <<<"${fm}"
  grep -q '^  task: deny$' <<<"${fm}"
  grep -q '^    "\.review-output/findings.json": allow$' <<<"${fm}"
}

opencode_jsonc_json() {
  sed -E 's#^[[:space:]]*//.*$##' "${opencode_jsonc}"
}
