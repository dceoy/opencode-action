#!/usr/bin/env bash
# Sourceable production helpers for the isolated /review-pr execution path.

opencode_review_prompt() {
  [[ "${1:-}" =~ ^/review-pr([[:space:]]+(all|code|quality|performance|security|tests|coverage|docs|documentation|comments|errors|types))*[[:space:]]*$ ]]
}

opencode_review_snapshot() {
  local output="$1" path mode type digest target
  : >"${output}"
  # A worktree's .git is an implementation detail, not reviewed content.  All
  # other entries, including ignored files and empty directories, are recorded.
  while IFS= read -r -d '' path; do
    if stat -c '%a' -- "${path}" >/dev/null 2>&1; then
      mode="$(stat -c '%a' -- "${path}")"
    else
      mode="$(stat -f '%Lp' -- "${path}")"
    fi
    if [[ -L "${path}" ]]; then
      target="$(readlink -- "${path}")"
      printf 'link\t%s\t%s\t%s\n' "${mode}" "${path#./}" "${target}" >>"${output}"
    elif [[ -f "${path}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum -- "${path}" | awk '{print $1}')"
      else
        digest="$(shasum -a 256 -- "${path}" | awk '{print $1}')"
      fi
      printf 'file\t%s\t%s\t%s\n' "${mode}" "${path#./}" "${digest}" >>"${output}"
    elif [[ -d "${path}" ]]; then
      printf 'dir\t%s\t%s\n' "${mode}" "${path#./}" >>"${output}"
    else
      if stat -c '%F' -- "${path}" >/dev/null 2>&1; then
        type="$(stat -c '%F' -- "${path}")"
      else
        type="$(stat -f '%HT' -- "${path}")"
      fi
      printf 'other\t%s\t%s\t%s\n' "${mode}" "${path#./}" "${type}" >>"${output}"
    fi
  done < <(find -P . -mindepth 1 ! -path './.git' -print0)
}

opencode_review_checkout_is_clean() {
  local state
  state="$(git status --porcelain=v1 --ignored=matching --untracked-files=all)"
  if [[ -n "${state}" ]]; then
    echo '::error::Refusing /review-pr because the caller checkout has tracked, untracked, or ignored changes. Start from a clean checkout.' >&2
    git status --short --ignored >&2 || true
    return 1
  fi
}

opencode_review_git_proxy() {
  local -a args=("$@")
  local command='' query=false arg
  while ((${#args[@]})); do
    case "${args[0]}" in
      -C|-c|--config-env|--git-dir|--work-tree|--namespace|--exec-path)
        ((${#args[@]} >= 2)) || { echo 'review Git proxy: incomplete global option' >&2; return 126; }
        args=("${args[@]:2}") ;;
      -C=*|-c=*|--config-env=*|--git-dir=*|--work-tree=*|--namespace=*|--exec-path=*) args=("${args[@]:1}") ;;
      --no-pager|--paginate|--literal-pathspecs|--no-literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) args=("${args[@]:1}") ;;
      --version|-v) exec "${OPENCODE_REAL_GIT:?}" "${args[@]}" ;;
      --|-*) echo 'review Git proxy: cannot safely classify Git command' >&2; return 126 ;;
      *) command="${args[0]}"; args=("${args[@]:1}"); break ;;
    esac
  done
  [[ -n "${command}" ]] || { echo 'review Git proxy: missing Git subcommand' >&2; return 126; }
  case "${command}" in
    add|am|apply|bisect|branch|checkout|cherry-pick|clean|clone|commit|merge|mv|rebase|reset|restore|revert|rm|sparse-checkout|stash|submodule|switch|tag|update-ref|worktree|push|fetch|pull)
      echo "review Git proxy: blocked mutating Git command '${command}'" >&2; return 126 ;;
    config)
      for arg in "${args[@]}"; do
        case "${arg}" in
          --get|--get-all|--get-regexp|--get-urlmatch|--list|-l) query=true ;;
          --show-origin|--show-scope|--null|-z|--name-only|--fixed-value) ;;
          --add|--replace-all|--unset|--unset-all|--rename-section|--remove-section|--global|--system|--local|--worktree|--file|--blob|--*) echo 'review Git proxy: blocked or unknown git config option' >&2; return 126 ;;
        esac
      done
      "${query}" || { echo 'review Git proxy: git config is allowed only for reads' >&2; return 126; }
      ;;
    cat-file|diff|diff-tree|for-each-ref|grep|log|ls-files|ls-tree|merge-base|name-rev|remote|rev-list|rev-parse|show|show-ref|status|symbolic-ref|describe) ;;
    *) echo "review Git proxy: cannot safely classify Git subcommand '${command}'" >&2; return 126 ;;
  esac
  exec "${OPENCODE_REAL_GIT:?}" "${command}" "${args[@]}"
}

opencode_review_run() (
  set -euo pipefail
  local timeout_minutes="$1" output_file="$2" real_git temp_root worktree before after before_head after_head opencode_status
  opencode_review_checkout_is_clean
  real_git="$(command -v git)"
  temp_root="$(mktemp -d)"
  worktree="${temp_root}/worktree"
  # shellcheck disable=SC2329 # Invoked by the EXIT and signal traps below.
  cleanup() {
    "${real_git}" worktree remove --force "${worktree}" >/dev/null 2>&1 || true
    rm -rf "${temp_root}"
  }
  trap cleanup EXIT
  trap 'cleanup; exit 130' HUP INT TERM
  "${real_git}" worktree add --detach "${worktree}" HEAD >/dev/null
  before="${temp_root}/before.snapshot"
  after="${temp_root}/after.snapshot"
  (
    cd "${worktree}"
    opencode_review_snapshot "${before}"
  )
  before_head="$("${real_git}" -C "${worktree}" rev-parse HEAD)"
  mkdir "${temp_root}/bin"
  cp "${BASH_SOURCE[0]}" "${temp_root}/bin/git"
  chmod 700 "${temp_root}/bin/git"
  set +e
  (
    cd "${worktree}"
    if command -v timeout >/dev/null 2>&1; then
      review_timeout=(timeout "${timeout_minutes}m")
    else
      review_timeout=(gtimeout "${timeout_minutes}m")
    fi
    PATH="${temp_root}/bin:${PATH}" OPENCODE_REVIEW_GIT_PROXY=1 OPENCODE_REAL_GIT="${real_git}" \
      "${review_timeout[@]}" opencode github run 2>&1 | tee "${output_file}"
    exit "${PIPESTATUS[0]}"
  )
  opencode_status=$?
  set -e
  (
    cd "${worktree}"
    opencode_review_snapshot "${after}"
  )
  after_head="$("${real_git}" -C "${worktree}" rev-parse HEAD)"
  if [[ "${before_head}" != "${after_head}" ]] || ! cmp -s "${before}" "${after}"; then
    echo '::error::Unexpected filesystem or Git mutation during /review-pr; the disposable review checkout was discarded.' >&2
    "${real_git}" -C "${worktree}" status --short --ignored >&2 || true
    "${real_git}" -C "${worktree}" diff --no-ext-diff >&2 || true
    "${real_git}" -C "${worktree}" diff --cached --no-ext-diff >&2 || true
    return 1
  fi
  return "${opencode_status}"
)

if [[ "${OPENCODE_REVIEW_GIT_PROXY:-}" == '1' && "${BASH_SOURCE[0]}" == "$0" ]]; then
  opencode_review_git_proxy "$@"
fi
