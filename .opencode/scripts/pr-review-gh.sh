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
args = ["bash", script, "--scoped-api", method, request["endpoint"], str(page) if paginate else ""]
payload = None
if method == "POST":
    if (not isinstance(request.get("payload"), dict) or request.get("paginate", False)
            or "offset" in request or "limit" in request or "page" in request):
        raise ValueError("Publication requires an embedded JSON payload")
    payload = json.dumps(request["payload"])
elif "payload" in request:
    raise ValueError("Read requests cannot contain a payload")
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
    collection = None
    if request["endpoint"].endswith("/check-runs"):
        collection = "check_runs"
    elif request["endpoint"].endswith("/status"):
        collection = "statuses"
    if collection:
        if not isinstance(records, dict):
            raise ValueError("Paginated CI response must be an object")
        records = records.get(collection)
    if not isinstance(records, list):
        raise ValueError("Paginated API response must contain the expected array")
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

  if (($# != 4)) || [[ "$1" != "--scoped-api" ]]; then
    echo "::error::Use the structured pr-review-api tool, not a direct gh CLI." >&2
    return 2
  fi
  local method="$2" endpoint="$3" review_page="$4" payload=""
  [[ "${method}" == GET || "${method}" == POST ]] || return 2
  [[ -z "${review_page}" || "${review_page}" =~ ^[1-9][0-9]*$ ]] || return 2
  if [[ -n "${review_page}" ]]; then
    ((10#${review_page} <= 10000)) || return 2
  fi

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

  local prefix="repos/${repo}/pulls/${pr_number}"
  if [[ "${method}" == POST ]]; then
    [[ "${endpoint}" == "${prefix}/reviews" && -z "${review_page}" ]] || return 2
    [[ "${PR_REVIEW_HEAD_SHA:-}" =~ ^[0-9a-fA-F]{40}$ ]] || return 2
    payload="$(cat)" || return 2
    # The internal subprocess is also scoped: direct invocation cannot bypass
    # the exact reviewed commit or request validation.
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
    set -- api "${endpoint}" --method POST --input -
  else
    case "${endpoint}" in
      "${prefix}" | "${prefix}/files" | "${prefix}/commits" | "${prefix}/comments" | "${prefix}/reviews" | "repos/${repo}/issues/${pr_number}/comments") ;;
      *)
        if [[ "${endpoint}" == "${prefix}/reviews/"* && "${endpoint#"${prefix}/reviews/"}" =~ ^[1-9][0-9]*(/comments)?$ ]]; then
          :
        elif [[ "${endpoint}" == "repos/${repo}/commits/"* && "${endpoint#"repos/${repo}/commits/"}" =~ ^[0-9a-fA-F]{40}(/(status|check-runs))?$ ]]; then
          :
        elif [[ "${endpoint}" == "repos/${repo}/compare/"* && "${endpoint#"repos/${repo}/compare/"}" =~ ^[0-9a-fA-F]{40}(\.\.\.)[0-9a-fA-F]{40}$ ]]; then
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
      case "${endpoint}" in
        "${prefix}/files" | "${prefix}/commits" | "${prefix}/comments" | "${prefix}/reviews" | "repos/${repo}/issues/${pr_number}/comments") ;;
        *)
          if [[ "${endpoint}" == "${prefix}/reviews/"* && "${endpoint#"${prefix}/reviews/"}" =~ ^[1-9][0-9]*/comments$ ]]; then
            :
          elif [[ "${endpoint}" == "repos/${repo}/commits/"* && "${endpoint#"repos/${repo}/commits/"}" =~ ^[0-9a-fA-F]{40}/(status|check-runs)$ ]]; then
            :
          else
            echo "::error::API pagination only supports scoped collection endpoints." >&2
            return 2
          fi
          ;;
      esac
      endpoint="${endpoint}?per_page=10&page=${review_page}"
    fi
    set -- api "${endpoint}" --method GET
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
