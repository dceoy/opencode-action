#!/usr/bin/env bash
# Sourceable helpers for the isolated /review-pr execution path.

opencode_review_prompt() {
  [[ "${1:-}" =~ ^/review-pr([[:space:]]+(all|code|quality|performance|security|tests|coverage|docs|documentation|comments|errors|types))*[[:space:]]*$ ]]
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

opencode_review_pr_number() {
  local event_path="${GITHUB_EVENT_PATH:-}" number=''
  if [[ -n "${event_path}" && -f "${event_path}" ]]; then
    number="$(jq -r '.pull_request.number // .issue.number // empty' "${event_path}")"
  fi
  if [[ -z "${number}" && "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/merge$ ]]; then
    number="${BASH_REMATCH[1]}"
  fi
  [[ "${number}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${number}"
}

opencode_review_prepare_workspace() {
  local workspace="$1" action_path="$2" pr_number="$3"
  mkdir -p "${workspace}/.review-input"
  # git archive gives analysis a plain directory, not a linked worktree: it
  # has no refs, remotes, config, hooks, or index to mutate.
  git archive --format=tar HEAD | tar -xf - -C "${workspace}"
  # OpenCode discovers these names in the project directory. Preserve neither
  # configuration nor command/plugin code from the reviewed PR at discovery
  # locations; the action-owned configuration below is the only policy tier.
  if [[ -e "${workspace}/opencode.json" ]]; then
    mv "${workspace}/opencode.json" "${workspace}/.review-input/project-opencode.json"
  fi
  if [[ -e "${workspace}/opencode.jsonc" ]]; then
    mv "${workspace}/opencode.jsonc" "${workspace}/.review-input/project-opencode.jsonc"
  fi
  if [[ -d "${workspace}/.opencode" ]]; then
    mv "${workspace}/.opencode" "${workspace}/.review-input/project-opencode"
  fi
  gh pr view "${pr_number}" --json number,title,body,baseRefName,headRefName,headRefOid,files,url >"${workspace}/.review-input/pr.json"
  gh pr diff "${pr_number}" >"${workspace}/.review-input/pr.diff"
  mkdir -p "${workspace}/trusted-config/opencode"
  cp -R "${action_path}/.opencode/." "${workspace}/trusted-config/opencode/"
}

opencode_review_validate_findings() {
  local findings="$1"
  jq -e '
    type == "array" and
    all(.[]; type == "object" and
      (.file | type == "string" and length > 0) and
      (.line | type == "number" and floor == . and . > 0) and
      (.severity | IN("critical", "important", "suggestion")) and
      (.message | type == "string" and length > 0 and length <= 4000))
  ' "${findings}" >/dev/null
}

opencode_review_submit() {
  local pr_number="$1" findings="$2" payload response
  opencode_review_validate_findings "${findings}" || {
    echo '::error::Review model returned an invalid structured findings payload.' >&2
    return 1
  }
  if [[ "$(jq 'length' "${findings}")" -eq 0 ]]; then
    echo 'No noteworthy issues found.'
    return 0
  fi
  payload="$(mktemp "${TMPDIR:-/tmp}/opencode-review-payload.XXXXXX")"
  trap 'rm -f "${payload}"' RETURN
  jq --argjson findings "$(<"${findings}")" '
    {event: "COMMENT", body: "OpenCode PR Review", comments:
      [$findings[] | {path: .file, line: .line, side: "RIGHT", body: ("**" + .severity + "**: " + .message)}]}
  ' >"${payload}"
  response="$(gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/reviews" --input "${payload}")"
  jq -e '.id' <<<"${response}" >/dev/null
}

opencode_review_run() (
  set -euo pipefail
  local timeout_minutes="$1" output_file="$2" action_path="$3"
  local temp_root workspace pr_number result_file status timeout_command
  opencode_review_checkout_is_clean
  pr_number="$(opencode_review_pr_number)" || {
    echo '::error::/review-pr requires a pull request event context.' >&2
    return 1
  }
  temp_root="$(mktemp -d)"
  workspace="${temp_root}/workspace"
  result_file="${temp_root}/findings.json"
  if command -v timeout >/dev/null 2>&1; then
    timeout_command=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_command=gtimeout
  else
    echo '::error::A timeout command is required for isolated /review-pr execution.' >&2
    return 1
  fi
  # shellcheck disable=SC2329 # Called by the EXIT and signal traps below.
  cleanup() { rm -rf "${temp_root}"; }
  trap cleanup EXIT HUP INT TERM
  opencode_review_prepare_workspace "${workspace}" "${action_path}" "${pr_number}"
  set +e
  (
    cd "${workspace}"
    # The model receives an isolated, non-Git directory and no GitHub token.
    # The trusted parent retains the token solely for context collection and
    # validated review submission.
    env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM \
      XDG_CONFIG_HOME="${workspace}/trusted-config" \
      "${timeout_command}" "${timeout_minutes}m" opencode run /review-pr 2>&1 | tee "${output_file}"
    exit "${PIPESTATUS[0]}"
  )
  status=$?
  set -e
  [[ "${status}" -eq 0 ]] || return "${status}"
  # The trusted command writes only this explicitly named structured artifact.
  cp "${workspace}/.review-output/findings.json" "${result_file}" || {
    echo '::error::Review model did not produce .review-output/findings.json.' >&2
    return 1
  }
  opencode_review_submit "${pr_number}" "${result_file}"
)
