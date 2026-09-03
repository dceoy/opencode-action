#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}
state_dir="${HOME}/.config/opencode/review-state"
context_file="${state_dir}/context.json"
metadata_file="${state_dir}/metadata.json"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_context_lib="${script_dir}/review-pr-context.sh"
[[ -f "${trusted_context_lib}" ]] || fail "Trusted review context helper is unavailable."
# shellcheck source=/dev/null
source "${trusted_context_lib}"

load_read_token() {
  local opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  if [[ -f "${opencode_app_token_lib}" ]]; then
    # shellcheck source=/dev/null
    source "${opencode_app_token_lib}"
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
  fi
}

normalize_compare_files() {
  jq -ce '
    .files
    | if type != "array" then
        error("compare response did not include a files array")
      elif length >= 300 then
        error("compare response may have truncated file metadata")
      else
        map(
          . as $file
          | if ($file | type) == "object"
            and ($file.filename | type) == "string"
            and ($file.additions | type) == "number"
            and ($file.additions | floor == . and . >= 0)
            and ($file.deletions | type) == "number"
            and ($file.deletions | floor == . and . >= 0) then
              {
                path: $file.filename,
                additions: $file.additions,
                deletions: $file.deletions
              }
            else
              error("compare response contained an invalid file entry")
            end
        )
      end
  '
}

normalize_pull_request_metadata() {
  jq -ce '
    {
      number,
      title,
      body,
      baseRefName: .base.ref,
      baseRefOid: .base.sha,
      headRefName: .head.ref,
      headRefOid: .head.sha,
      url: .html_url
    }
  '
}

normalize_metadata() {
  local metadata="${1}" base_sha="${2}" head_sha="${3}" number="${4}" files="${5}"

  jq -ce \
    --arg base_sha "${base_sha}" \
    --arg head_sha "${head_sha}" \
    --argjson expected_number "${number}" \
    --slurpfile files <(printf '%s\n' "${files}") '
      if (.number | type) != "number" or .number != $expected_number then
        error("pull request metadata did not match the pinned PR")
      elif (.title | type) != "string" then
        error("pull request metadata did not include a title")
      elif ((.body | type) != "string" and (.body | type) != "null") then
        error("pull request metadata did not include a valid body")
      elif (.baseRefName | type) != "string" then
        error("pull request metadata did not include a base branch")
      elif (.headRefName | type) != "string" then
        error("pull request metadata did not include a head branch")
      elif (.url | type) != "string" then
        error("pull request metadata did not include a URL")
      else
        . + {
          baseRefOid: $base_sha,
          headRefOid: $head_sha,
          files: $files[0]
        }
      end
    ' <<< "${metadata}"
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take exactly one operation name and no additional arguments."
load_read_token

case "${operation}" in
  context)
    [[ -d "${state_dir}" && ! -s "${context_file}" ]] || fail "Run prepare exactly once before pinning context."
    repo="${GITHUB_REPOSITORY:-}"
    number="$(opencode_review_event_pr_number)" || fail "Trusted pull request number is unavailable."
    [[ "${repo}" =~ ^[^/]+/[^/]+$ ]] || fail "Trusted repository is unavailable."
    event_path="${GITHUB_EVENT_PATH:-}"
    if jq -e '(.pull_request | type) == "object"' "${event_path}" > /dev/null; then
      event_metadata="$(jq -ce '.pull_request' "${event_path}")" \
        || fail "Trusted pull request event is unavailable."
      metadata="$(normalize_pull_request_metadata <<< "${event_metadata}")" \
        || fail "Pull request event metadata could not be normalized."
      base_sha="$(jq -er '.baseRefOid | select(type == "string")' <<< "${metadata}")" \
        || fail "Trusted PR base SHA is unavailable."
      head_sha="$(jq -er '.headRefOid | select(type == "string")' <<< "${metadata}")" \
        || fail "Trusted PR head SHA is unavailable."
    else
      metadata_raw="$(gh api "repos/${repo}/pulls/${number}")" \
        || fail "Failed to read pull request metadata at snapshot time."
      metadata="$(normalize_pull_request_metadata <<< "${metadata_raw}")" \
        || fail "Pull request metadata could not be normalized."
      base_sha="$(jq -er '.baseRefOid | select(type == "string")' <<< "${metadata}")" \
        || fail "Trusted PR base SHA is unavailable."
      head_sha="$(jq -er '.headRefOid | select(type == "string")' <<< "${metadata}")" \
        || fail "Trusted PR head SHA is unavailable."
    fi
    metadata_number="$(jq -er '.number | select(type == "number" and floor == . and . > 0) | tostring' <<< "${metadata}")" \
      || fail "Pull request metadata did not include a valid PR number."
    [[ "${metadata_number}" == "${number}" ]] \
      || fail "Pull request metadata did not match the trusted PR number."
    opencode_review_sha_is_valid "${base_sha}" || fail "Trusted PR base SHA is unavailable."
    opencode_review_sha_is_valid "${head_sha}" || fail "Trusted PR head SHA is unavailable."
    opencode_review_verify_commit "${repo}" "${number}" "${head_sha}" \
      || fail "Pinned PR commit cannot be read."

    compare_metadata="$(gh api "repos/${repo}/compare/${base_sha}...${head_sha}")" \
      || fail "Failed to read the pinned pull request comparison."
    compare_files="$(normalize_compare_files <<< "${compare_metadata}")" \
      || fail "Pinned pull request comparison contained invalid file metadata."
    metadata_snapshot="$(normalize_metadata "${metadata}" "${base_sha}" "${head_sha}" "${number}" "${compare_files}")" \
      || fail "Pull request metadata could not be normalized to the pinned snapshot."

    context_tmp="$(mktemp "${state_dir}/context.XXXXXX.json")"
    metadata_tmp="$(mktemp "${state_dir}/metadata.XXXXXX.json")"
    trap 'rm -f "${context_tmp}" "${metadata_tmp}"' EXIT
    jq -n --arg repository "${repo}" --arg pr_number "${number}" \
      --arg base_sha "${base_sha}" --arg head_sha "${head_sha}" \
      '{repository: $repository, pr_number: ($pr_number | tonumber), base_sha: $base_sha, head_sha: $head_sha}' \
      > "${context_tmp}"
    printf '%s\n' "${metadata_snapshot}" > "${metadata_tmp}"
    chmod 600 "${context_tmp}" "${metadata_tmp}"
    mv -- "${metadata_tmp}" "${metadata_file}"
    mv -- "${context_tmp}" "${context_file}"
    trap - EXIT
    cat "${context_file}"
    ;;
  metadata)
    trusted_context="$(opencode_review_trusted_context)" \
      || fail "Pinned review context is unavailable or the pinned commit cannot be read."
    IFS=$'\t' read -r repo number base_sha head_sha <<< "${trusted_context}"
    [[ -s "${metadata_file}" ]] || fail "Pinned review metadata is unavailable."
    metadata="$(jq -ce \
      --argjson expected_number "${number}" \
      --arg base_sha "${base_sha}" \
      --arg head_sha "${head_sha}" '
        if (.number == $expected_number
            and .baseRefOid == $base_sha
            and .headRefOid == $head_sha
            and (.files | type) == "array") then
          .
        else
          error("pinned metadata does not match the trusted context")
        end
      ' "${metadata_file}")" \
      || fail "Pinned review metadata is unavailable or invalid."
    printf '%s\n' "${metadata}"
    ;;
  diff)
    trusted_context="$(opencode_review_trusted_context)" \
      || fail "Pinned review context is unavailable or the pinned commit cannot be read."
    IFS=$'\t' read -r repo number base_sha head_sha <<< "${trusted_context}"
    exec gh api -H 'Accept: application/vnd.github.diff' \
      "repos/${repo}/compare/${base_sha}...${head_sha}"
    ;;
  validate)
    opencode_review_trusted_context > /dev/null \
      || fail "Pinned review context is unavailable or the pinned commit cannot be read."
    ;;
  *) fail "Unsupported review-pr GitHub read operation." ;;
esac
