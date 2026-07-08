#!/usr/bin/env bash
# Regression tests for scripts/suppress-duplicate-review-comment.sh: it must
# delete only the completion comment authored by the same actor at or after
# the recorded review submission time, never by matching comment body text,
# and must no-op when no marker file (i.e. no structured review) exists.
set -uo pipefail
repo_root="$(git rev-parse --show-toplevel)"
script="${repo_root}/scripts/suppress-duplicate-review-comment.sh"

fail=0
tmpdirs=()

cleanup() {
  for d in "${tmpdirs[@]}"; do
    rm -rf "${d}"
  done
}
trap cleanup EXIT

ok() { echo "ok - $1"; }
ng() {
  echo "not ok - $1" >&2
  fail=1
}

mk_fake_gh() {
  local dir="$1" calls_log="$2"
  cat > "${dir}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${calls_log}"
if [[ "\${1:-}" == "api" && "\${2:-}" == "--method" && "\${3:-}" == "DELETE" ]]; then
  exit 0
elif [[ "\${1:-}" == "api" ]]; then
  cat <<'JSON'
[
  {"id": 1001, "user": {"login": "opencode-agent[bot]"}, "created_at": "2026-07-08T09:00:00Z"},
  {"id": 1002, "user": {"login": "opencode-agent[bot]"}, "created_at": "2026-07-08T10:05:00Z"},
  {"id": 1003, "user": {"login": "some-human"}, "created_at": "2026-07-08T10:06:00Z"},
  {"id": 1004, "user": {"login": "github-actions[bot]"}, "created_at": "2026-07-08T10:07:00Z"}
]
JSON
  exit 0
fi
exit 1
EOF
  chmod +x "${dir}/gh"
}

deleted_ids() {
  # Extract comment IDs targeted by DELETE calls, sorted, comma-joined.
  grep -oE 'api --method DELETE repos/[^ ]+/issues/comments/[0-9]+' "$1" 2>/dev/null \
    | grep -oE '[0-9]+$' | sort -n | paste -sd, -
}

run_case() {
  local desc="$1" marker_content="$2" expected_ids="$3"
  local fakebin calls_log marker actual out err rc

  fakebin="$(mktemp -d)"
  tmpdirs+=("${fakebin}")
  calls_log="$(mktemp)"
  tmpdirs+=("${calls_log}")
  mk_fake_gh "${fakebin}" "${calls_log}"

  marker="$(mktemp)"
  if [[ -n "${marker_content}" ]]; then
    printf '%s' "${marker_content}" > "${marker}"
  else
    rm -f "${marker}"
  fi

  out="$(mktemp)"
  err="$(mktemp)"
  tmpdirs+=("${out}" "${err}")
  PATH="${fakebin}:${PATH}" "${script}" "${marker}" >"${out}" 2>"${err}"
  rc=$?

  actual="$(deleted_ids "${calls_log}")"
  if [[ "${rc}" -ne 0 ]]; then
    ng "${desc}: script exited ${rc} (stderr: $(cat "${err}"))"
  elif [[ "${actual}" == "${expected_ids}" ]]; then
    ok "${desc} (deleted: ${actual:-none})"
  else
    ng "${desc}: expected deletions '${expected_ids}' got '${actual}'"
  fi

  if [[ -e "${marker}" ]]; then
    ng "${desc}: marker file was not cleaned up"
    rm -f "${marker}"
  fi
}

run_case "no marker file is a no-op" "" ""

run_case "deletes only the post-submission comment by the recorded actor" \
  '{"repository":"owner/repo","pr_number":"42","actor_login":"opencode-agent[bot]","submitted_at":"2026-07-08T10:00:00Z"}' \
  "1002"

run_case "no deletions when actor_login matches nobody" \
  '{"repository":"owner/repo","pr_number":"42","actor_login":"someone-else[bot]","submitted_at":"2026-07-08T10:00:00Z"}' \
  ""

run_case "no deletions when marker is missing required fields" \
  '{"repository":"owner/repo"}' \
  ""

run_case "never matches other users or unrelated bots regardless of timing" \
  '{"repository":"owner/repo","pr_number":"42","actor_login":"some-human","submitted_at":"2026-07-08T00:00:00Z"}' \
  "1003"

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "OK: suppress-duplicate-review-comment.sh regression tests passed."
