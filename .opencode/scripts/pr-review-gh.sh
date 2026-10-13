#!/usr/bin/env bash
# Run GitHub CLI commands through a verified OpenCode GitHub App identity.
# This runs inside opencode github run, after its OIDC token exchange.
set -euo pipefail

pr_review_request() {
  # Only this exact no-argument command is available to the review agent.
  python3 - "${BASH_SOURCE[0]}" "${HOME}/.config/opencode/review-state/request.json" << 'PYCODE'
import base64
import json
import os
import subprocess
import sys
from pathlib import Path

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result

script, filename = sys.argv[1:]
path = Path(filename)
if path.parent.is_symlink() or path.is_symlink():
    raise ValueError("Review request path must not be a symbolic link")
with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
    request = json.load(stream, object_pairs_hook=unique)
if not (isinstance(request, dict)
        and set(request) <= {"endpoint", "method", "paginate", "payload"}
        and isinstance(request.get("endpoint"), str)
        and request.get("method", "GET") in ("GET", "POST")
        and isinstance(request.get("paginate", False), bool)):
    raise ValueError("Invalid structured review request")
method = request.get("method", "GET")
args = ["bash", script, "api", request["endpoint"], "--method", method]
payload = None
if method == "POST":
    if not isinstance(request.get("payload"), dict) or request.get("paginate", False):
        raise ValueError("Publication requires an embedded JSON payload")
    args += ["--input", "-"]
    payload = json.dumps(request["payload"])
elif "payload" in request:
    raise ValueError("Read requests cannot contain a payload")
if request.get("paginate", False):
    args += ["--paginate"]
immutable = "/git/blobs/" in request["endpoint"] or "/git/trees/" in request["endpoint"]
if immutable and request.get("paginate", False):
    raise ValueError("Immutable evidence does not support pagination")
result = subprocess.run(args, input=payload, text=True,
                        stdout=subprocess.PIPE if immutable else None)
if result.returncode:
    raise SystemExit(result.returncode)
if immutable:
    evidence = json.loads(result.stdout)
    if "/git/blobs/" in request["endpoint"]:
        if evidence.get("encoding") != "base64":
            raise ValueError("Unsupported blob encoding")
        sys.stdout.buffer.write(base64.b64decode(evidence["content"]))
    else:
        if evidence.get("truncated"):
            raise ValueError("Truncated tree cannot establish complete evidence")
        print(json.dumps(evidence))
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

  local endpoint="" method=GET input="" payload="" option value
  local -a safe_args=()
  if [[ "$1" == api ]]; then
    shift
    while (($#)); do
      option="$1"
      shift
      case "${option}" in
        --method | -X | --input | --jq | -q | --template | -t)
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
      [[ "${endpoint}" == "${prefix}/reviews" && -n "${input}" ]] || return 2
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
  opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}" || return 1
  if [[ "${method}" == POST ]]; then
    exec gh "$@" <<< "${payload}"
  else
    exec gh "$@"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if (($# == 0)); then
    pr_review_request
  else
    pr_review_gh_main "$@"
  fi
fi
