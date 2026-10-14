#!/usr/bin/env bash
# Run scoped GitHub reads and commit-bound review publication.
# This runs inside opencode github run, after its OIDC token exchange.
set -euo pipefail

pr_review_request() {
  # Preserve request stdin on fd 3 while the static program uses stdin.
  python3 - "${BASH_SOURCE[0]}" 3<&0 << 'PYCODE'
import base64
import json
import os
import subprocess
import sys

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result

script = sys.argv[1]
with os.fdopen(3) as stream:
    request = json.load(stream, object_pairs_hook=unique)
if not (isinstance(request, dict)
        and set(request) <= {"endpoint", "method", "paginate", "page", "payload", "offset", "limit"}
        and isinstance(request.get("endpoint"), str)
        and request.get("method", "GET") in ("GET", "POST")
        and isinstance(request.get("paginate", False), bool)):
    raise ValueError("Invalid structured review request")
method = request.get("method", "GET")
paginate = request.get("paginate", False)
page = request.get("page", 1)
if not (type(page) is int and 1 <= page <= 10000
        and (paginate or "page" not in request)):
    raise ValueError("API page requires pagination and must be a positive integer")
offset, limit = request.get("offset", 0), request.get("limit", 4096)
if not (type(offset) is int and offset >= 0 and type(limit) is int and 1 <= limit <= 4096):
    raise ValueError("Invalid response page bounds")
args = ["bash", script, "api", request["endpoint"], "--method", method]
payload = None
if method == "POST":
    if (not isinstance(request.get("payload"), dict) or request.get("paginate", False)
            or "offset" in request or "limit" in request or "page" in request):
        raise ValueError("Publication requires an embedded JSON payload")
    args += ["--input", "-"]
    payload = json.dumps(request["payload"])
elif "payload" in request:
    raise ValueError("Read requests cannot contain a payload")
if paginate:
    # Request exactly one GitHub API page per call, not all preceding pages.
    # Only allow this on scoped collections in pr_review_gh_main.
    args += ["--review-page", str(page)]
immutable = "/git/blobs/" in request["endpoint"] or "/git/trees/" in request["endpoint"]
if immutable and paginate:
    raise ValueError("Immutable evidence does not support pagination")
result = subprocess.run(args, input=payload, text=True, stdout=subprocess.PIPE)
if result.returncode:
    raise SystemExit(result.returncode)
content = result.stdout
if method == "POST":
    receipt = json.loads(content)
    print(json.dumps({"review_id": receipt.get("id"), "commit_id": receipt.get("commit_id"),
                      "state": receipt.get("state"), "url": receipt.get("html_url")}))
    raise SystemExit(0)
if immutable:
    evidence = json.loads(result.stdout)
    if "/git/blobs/" in request["endpoint"]:
        if evidence.get("encoding") != "base64":
            raise ValueError("Unsupported blob encoding")
        content = base64.b64decode(evidence["content"]).decode("utf-8")
    else:
        if evidence.get("truncated"):
            raise ValueError("Truncated tree cannot establish complete evidence")
        content = json.dumps(evidence, ensure_ascii=False)
next_page = None
if paginate:
    records = json.loads(content)
    if not isinstance(records, list):
        raise ValueError("Paginated API response must be an array")
    # A full page may have a successor; a short page is terminal.
    if len(records) == 10 and page < 10000:
        next_page = page + 1
if offset > len(content):
    raise ValueError("Response offset exceeds available evidence")
end = min(offset + limit, len(content))
print(json.dumps({"offset": offset, "next_offset": end if end < len(content) else None,
                  "page": page if paginate else None,
                  "next_page": next_page if end == len(content) else None,
                  "total_chars": len(content), "content": content[offset:end]}, ensure_ascii=False))
PYCODE
}

pr_review_gh_main() {
  local script_dir repo pr_number url
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if (($# == 0)); then
    echo "::error::Usage: pr-review-gh.sh <gh subcommand> [args...]" >&2
    return 2
  fi
  case "${1}" in
    api) ;;
    pr)
      case "${2:-}" in
        view | diff | checks) ;;
        *)
          echo "::error::Unsupported gh pr subcommand in review-only mode." >&2
          return 2
          ;;
      esac
      ;;
    *)
      echo "::error::Unsupported gh subcommand in review-only mode." >&2
      return 2
      ;;
  esac

  url="${PR_REVIEW_URL:-}"
  if [[ -n "${url}" ]]; then
    if [[ "${url}" =~ ^https://github\.com/([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)/pull/([0-9]+)/?$ ]]; then
      repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
      pr_number="${BASH_REMATCH[3]}"
    else
      echo "::error::Invalid PR_REVIEW_URL for verified GitHub App token use." >&2
      return 1
    fi
  else
    repo="${GITHUB_REPOSITORY:-}"
    pr_number=""
    if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
      pr_number="$(jq -r '.pull_request.number // .issue.number // .number // empty' "${GITHUB_EVENT_PATH}")"
    fi
  fi
  if [[ ! "${repo:-}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ || ! "${pr_number:-}" =~ ^[0-9]+$ ]]; then
    echo "::error::Cannot determine trusted owner/repo and PR number for GitHub App identity verification." >&2
    return 1
  fi

  local endpoint="" method=GET input="" payload="" review_page="" option value
  local -a safe_args=()
  if [[ "$1" == api ]]; then
    shift
    while (($#)); do
      option="$1"
      shift
      case "${option}" in
        --method | -X | --input | --jq | -q | --template | -t | --review-page)
          (($#)) || return 2
          value="$1"
          shift
          case "${option}" in
            --method | -X)
              [[ "${method}" == GET && "${value}" =~ ^(GET|POST)$ ]] || return 2
              method="${value}"
              ;;
            --input)
              [[ -z "${input}" ]] || return 2
              input="${value}"
              ;;
            --review-page)
              [[ -z "${review_page}" && "${value}" =~ ^[1-9][0-9]*$ ]] || return 2
              ((10#${value} <= 10000)) || return 2
              review_page="${value}"
              ;;
            *) safe_args+=("${option}" "${value}") ;;
          esac
          ;;
        --paginate | --slurp | --include | -i) safe_args+=("${option}") ;;
        -*)
          echo "::error::Unsupported API option." >&2
          return 2
          ;;
        *)
          [[ -z "${endpoint}" ]] || return 2
          endpoint="${option}"
          ;;
      esac
    done
    local prefix="repos/${repo}/pulls/${pr_number}"
    if [[ "${method}" == POST ]]; then
      [[ "${endpoint}" == "${prefix}/reviews" && -n "${input}" && -z "${review_page}" ]] || return 2
      [[ "${PR_REVIEW_HEAD_SHA:-}" =~ ^[0-9a-fA-F]{40}$ ]] || return 2
      if [[ "${input}" == - ]]; then
        payload="$(cat)"
      else
        payload="$(cat -- "${input}")" || return 2
      fi
      # Validate and canonicalize once; the exact authorized payload is sent on stdin.
      payload="$(python3 -c '
import json, sys

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result
p = json.load(sys.stdin, object_pairs_hook=unique)
if not (isinstance(p, dict) and set(p) <= {"event", "body", "commit_id", "comments"}
        and p.get("event") == "COMMENT"
        and isinstance(p.get("body"), str) and p["body"].strip()
        and p.get("commit_id") == sys.argv[1]
        and isinstance(p.get("comments", []), list)):
    raise ValueError("Only a commit-bound COMMENT review is authorized")
print(json.dumps(p))
' "${PR_REVIEW_HEAD_SHA}" <<< "${payload}")" || return 2
      set -- api "${endpoint}" --method POST --input - "${safe_args[@]}"
    else
      [[ -z "${input}" ]] || return 2
      case "${endpoint}" in
        "${prefix}" | "${prefix}/files" | "${prefix}/commits" | "${prefix}/comments" | "${prefix}/reviews" | "repos/${repo}/issues/${pr_number}/comments") ;;
        *)
          if [[ "${endpoint}" == "${prefix}/reviews/"* && "${endpoint#"${prefix}/reviews/"}" =~ ^[1-9][0-9]*(/comments)?$ ]]; then
            :
          elif [[ "${endpoint}" == "repos/${repo}/commits/"* && "${endpoint#"repos/${repo}/commits/"}" =~ ^[0-9a-fA-F]{40}(/(status|check-runs))?$ ]]; then
            :
          elif [[ "${endpoint}" == "repos/${repo}/compare/"* && "${endpoint#"repos/${repo}/compare/"}" =~ ^[0-9a-fA-F]{40}\.\.\.[0-9a-fA-F]{40}$ ]]; then
            :
          elif [[ "${endpoint}" == "repos/${repo}/git/"* && "${endpoint#"repos/${repo}/git/"}" =~ ^(trees|blobs)/[0-9a-fA-F]{40}$ ]]; then
            :
          else
            echo "::error::Unsupported API endpoint for this review." >&2
            return 2
          fi
          ;;
      esac
      if [[ -n "${review_page}" ]]; then
        # Only lists can be paged. The endpoint is checked before the
        # query string is appended, so no arbitrary URL can be supplied.
        case "${endpoint}" in
          "${prefix}/files" | "${prefix}/commits" | "${prefix}/comments" | "${prefix}/reviews" | "repos/${repo}/issues/${pr_number}/comments") ;;
          *)
            if [[ "${endpoint}" == "${prefix}/reviews/"* && "${endpoint#"${prefix}/reviews/"}" =~ ^[1-9][0-9]*/comments$ ]]; then
              :
            else
              echo "::error::API pagination only supports PR collection endpoints." >&2
              return 2
            fi
            ;;
        esac
        endpoint="${endpoint}?per_page=10&page=${review_page}"
      fi
      set -- api "${endpoint}" --method GET "${safe_args[@]}"
    fi
  else
    # Explicitly bind read-only PR CLI requests to the trusted URL.
    [[ "${3:-}" == "${url}" ]] || return 2
    for option in "${@:4}"; do
      case "${option}" in
        --repo | -R | --repo=* | -R* | --hostname*) return 2 ;;
      esac
    done
  fi

  # shellcheck source=.opencode/scripts/resolve-app-token.sh
  source "${script_dir}/resolve-app-token.sh"
  if [[ "${method}" == POST ]]; then
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || return 1
    exec gh "$@" <<< "${payload}"
  else
    # Evidence may take many bounded reads. Identity verification creates and
    # deletes a pending review, so reserve it for the final publication.
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    exec gh "$@"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if (($# == 1)) && [[ "$1" == --request-stdin ]]; then
    pr_review_request
  else
    pr_review_gh_main "$@"
  fi
fi
