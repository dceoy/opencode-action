#!/usr/bin/env bash

opencode_normalize_boolean() {
  case "${1:-}" in
    true|false) printf '%s\n' "$1" ;;
    *) echo "::error::${2:-input} must be exactly 'true' or 'false'." >&2; return 1 ;;
  esac
}

opencode_review_only_snapshot() {
  git status --porcelain=v1 --untracked-files=all
  git rev-parse HEAD
  git symbolic-ref -q --short HEAD || true
}

opencode_review_only_assert_clean() {
  [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "::error::review-only requires a clean worktree before OpenCode starts." >&2
    git status --short >&2
    return 1
  }
}

opencode_review_only_assert_token() {
  local permissions
  permissions="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.permissions // {}')" || return 1
  jq -e '.push == false and .admin == false and .maintain == false' <<<"$permissions" >/dev/null || {
    echo "::error::review-only requires a token without repository contents-write capability." >&2
    return 1
  }
}

opencode_review_only_check_invariant() {
  [[ "$(opencode_review_only_snapshot)" == "$1" ]] && return 0
  echo "::error::review-only worktree invariant was violated; refusing to publish repository changes." >&2
  git status --short >&2 || true
  git diff --no-ext-diff >&2 || true
  git diff --cached --no-ext-diff >&2 || true
  return 1
}

opencode_review_only_make_git_guard() {
  local directory="$1" real_git
  real_git="$(command -v git)"
  mkdir -p "$directory"
  cat >"$directory/git" <<EOF
#!/usr/bin/env bash
args=("\$@")
index=0
while [[ "\${args[index]:-}" == -* ]]; do
  if [[ "\${args[index]}" == -C || "\${args[index]}" == -c || "\${args[index]}" == --git-dir || "\${args[index]}" == --work-tree ]]; then
    ((index += 2))
  else
    ((index += 1))
  fi
done
case "\${args[index]:-}" in
  add|commit|push|reset|restore|clean|checkout|switch|merge|rebase|cherry-pick|am|apply)
    echo "review-only: git \${args[index]} is blocked" >&2; exit 77 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod 755 "$directory/git"
}
