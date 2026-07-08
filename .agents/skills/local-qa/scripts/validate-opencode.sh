#!/usr/bin/env bash
# Validate .opencode/ agent frontmatter and review-pr command/skill references.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

agents_dir=".opencode/agents"
docs=(.opencode/commands/review-pr.md)
required_keys=(name description mode permission)
# Backtick-quoted identifiers in the docs that are skills, toolkits, or config
# inputs rather than agents.
non_agents=(pr-feedback-triage pr-review-toolkit use-github-token)
fail=0

warn() { echo "ERROR: $*" >&2; fail=1; }

shopt -s nullglob

# 1. Every agent markdown file has YAML frontmatter with required keys.
for f in "$agents_dir"/*.md; do
  fm="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$f")"
  if [[ -z "$fm" ]]; then
    warn "$f has no YAML frontmatter"
    continue
  fi
  for key in "${required_keys[@]}"; do
    grep -qE "^${key}:" <<<"$fm" || warn "$f missing frontmatter key: $key"
  done
  name="$(grep -E '^name:' <<<"$fm" | head -1 | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')"
  base="$(basename "$f" .md)"
  [[ "$name" == "$base" ]] || warn "$f name '$name' != filename '$base'"
done

# 2. Every agent name referenced in review-pr docs exists under .opencode/agents/.
# Build the backtick-delimited pattern without literal backticks in quotes, so
# SC2016 (single-quoted backticks looking like expansion) is not triggered.
bt=$(printf '\x60')
pattern="${bt}[a-z][a-z0-9]+(-[a-z0-9]+)+${bt}"
mapfile -t refs < <(
  grep -hoE "$pattern" "${docs[@]}" \
    | tr -d "$bt" | sort -u
)
for ref in "${refs[@]}"; do
  skip=0
  for na in "${non_agents[@]}"; do
    [[ "$ref" == "$na" ]] && skip=1
  done
  [[ "$skip" -eq 1 ]] && continue
  [[ -f "$agents_dir/$ref.md" ]] || warn "referenced agent '$ref' has no file under $agents_dir/"
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "OK: agent frontmatter and review-pr references valid."
