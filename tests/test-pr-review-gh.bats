#!/usr/bin/env bats
# shellcheck disable=SC2016
# Verify that the upstream reviewer CLI adapter uses the authenticated identity.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  wrapper="${repo_root}/.opencode/scripts/pr-review-gh.sh"
  temp_repo="${BATS_TEST_TMPDIR}/repo"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  git init -q "${temp_repo}"
  mkdir -p "${fake_bin}"
  request_home="${BATS_TEST_TMPDIR}/home"
  request_head=""
  request_file="${BATS_TEST_TMPDIR}/request.json"
  mkdir -p "$(dirname "${request_file}")"
  cat > "${fake_bin}/gh" << 'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf x >> "${GH_CALL_LOG}"
printf "%s\n" "$*" >> "${GH_ARGS_LOG:-/dev/null}"
if [[ "$*" == *"--method POST"* ]]; then
  cat > "${GH_PAYLOAD_LOG:-/dev/null}"
  if [[ "${GH_TOKEN:-}" == ghs_verified ]]; then
    printf '%s' '{"id":101,"user":{"login":"opencode-agent[bot]"}}'
  else
    printf '%s' '{"id":101,"user":{"login":"github-actions[bot]"}}'
  fi
elif [[ "$*" == *"--method DELETE"* ]]; then
  exit 0
elif [[ -n "${GH_PAGED_FIXTURE_DIR:-}" && "$*" == *"?per_page=10&page="* ]]; then
  for arg in "$@"; do
    if [[ "${arg}" == *"?per_page=10&page="* ]]; then
      page="${arg##*page=}"
      cat "${GH_PAGED_FIXTURE_DIR}/${page}.json"
      break
    fi
  done
elif [[ "$*" == *"?per_page=10&page="* ]]; then
  printf '%s' '[]'
elif [[ -n "${GH_RESPONSE_FILE:-}" ]]; then
  cat "${GH_RESPONSE_FILE}"
elif [[ "$*" == *"/git/blobs/"* ]]; then
  printf '%s' '{"encoding":"base64","content":"RnJvemVuIGV2aWRlbmNlCg=="}'
elif [[ "$*" == *"/git/trees/"* ]]; then
  printf '{"truncated":%s,"tree":[]}' "${GH_TREE_TRUNCATED:-false}"
else
  printf 'GITHUB_IDENTITY_TOKEN=%s\n' "${GH_TOKEN:-}"
  printf 'ARGUMENTS=%s\n' "$*"
fi
STUB
  chmod +x "${fake_bin}/gh"
}

set_git_candidate() {
  git -C "${temp_repo}" config --local http.https://github.com/.extraheader \
    "AUTHORIZATION: basic $(printf '%s' "x-access-token:$1" | base64 | tr -d '\n')"
}

run_wrapper() {
  run env -u GH_TOKEN -u GITHUB_TOKEN \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" PATH="${fake_bin}:${PATH}" PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    bash -c 'cd "$1"; shift; "$@"' _ "${temp_repo}" bash "${wrapper}" "$@"
}

run_request() {
  run env -u GH_TOKEN -u GITHUB_TOKEN HOME="${request_home}" \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" GH_ARGS_LOG="${BATS_TEST_TMPDIR}/gh-args" GH_PAYLOAD_LOG="${BATS_TEST_TMPDIR}/payload" \
    PATH="${fake_bin}:${PATH}" PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    PR_REVIEW_HEAD_SHA="${request_head}" \
    bash -c 'cd "$1"; bash "$2" --request-stdin < "$3"' _ "${temp_repo}" "${wrapper}" "${request_file}"
}

@test "publishes using verified OpenCode GitHub App token" {
  set_git_candidate ghs_verified
  run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GITHUB_IDENTITY_TOKEN=ghs_verified"* ]]
  [[ "${output}" == *"ARGUMENTS=api repos/dceoy/opencode-action/pulls/127/reviews"* ]]
}

@test "rejects an unverified candidate with default policy" {
  set_git_candidate ghs_wrong
  run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unable to resolve and verify an OpenCode GitHub App token"* ]]
  [[ "${output}" != *"GITHUB_IDENTITY_TOKEN="* ]]
}

@test "explicit workflow-token fallback is permitted" {
  set_git_candidate ghs_wrong
  run env GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" PATH="${fake_bin}:${PATH}" \
    GH_TOKEN=workflow_tok GITHUB_TOKEN=workflow_tok USE_GITHUB_TOKEN=true \
    PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    bash -c 'cd "$1"; shift; "$@"' _ "${temp_repo}" bash "${wrapper}" api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GITHUB_IDENTITY_TOKEN=workflow_tok"* ]]
}

@test "rejects invalid event PR URL before accessing credentials" {
  run env PR_REVIEW_URL=https://github.com/not-valid \
    bash "${wrapper}" api repos/dceoy/opencode-action/pulls/127/reviews
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid PR_REVIEW_URL"* ]]
}

@test "only allows review-oriented gh commands" {
  for subcommand in merge status; do
    run_wrapper pr "${subcommand}" "https://github.com/dceoy/opencode-action/pull/127"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Unsupported gh pr subcommand"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "rejects arbitrary methods endpoints hosts and field mutations before credentials" {
  for args in 'api repos/dceoy/opencode-action/pulls/127 --method DELETE' \
    'api repos/other/repo/pulls/127' 'api graphql' \
    'api repos/dceoy/opencode-action/pulls/127/reviews -f event=APPROVE' \
    'api repos/dceoy/opencode-action/pulls/127 --hostname attacker.example' \
    'api repos/dceoy/opencode-action/pulls/127 --method=POST'; do
    # Intentional whitespace splitting supplies hostile CLI arguments.
    # shellcheck disable=SC2086
    run_wrapper ${args}
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "accepts commit-bound COMMENT JSON and rejects approval wrong SHA and duplicate keys" {
  set_git_candidate ghs_verified
  payload="${BATS_TEST_TMPDIR}/review.json"
  sha=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  export PR_REVIEW_HEAD_SHA="${sha}" PYTHONOPTIMIZE=1
  printf '{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}' "${sha}" > "${payload}"
  run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews --method POST --input "${payload}"
  [ "${status}" -eq 0 ]
  for json in '{"event":"APPROVE","body":"x"}' \
    '{"event":"COMMENT","body":"x","commit_id":"wrong"}' \
    '{"event":"APPROVE","event":"COMMENT","body":"x"}'; do
    printf '%s' "${json}" > "${payload}"
    run_wrapper api repos/dceoy/opencode-action/pulls/127/reviews --method POST --input "${payload}"
    [ "${status}" -ne 0 ]
  done
}

@test "structured requests allow scoped reads and commit-bound publication" {
  set_git_candidate ghs_verified
  printf '%s' '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","paginate":true}' > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  jq -e '.page == 1 and .next_page == null and .next_offset == null' <<< "${output}"
  grep -q 'pulls/127/reviews?per_page=10&page=1' "${BATS_TEST_TMPDIR}/gh-args"
  run ! grep -q -- '--paginate' "${BATS_TEST_TMPDIR}/gh-args"
  [ "${status}" -eq 0 ]
  request_head=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}}' "${request_head}" > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  jq -e '.event == "COMMENT" and .body == "Reviewed"' "${BATS_TEST_TMPDIR}/payload"
}

@test "structured requests reject hostile schema and endpoints before credentials" {
  for request in '{"endpoint":"repos/other/repo/pulls/127"}' \
    '{"endpoint":"repos/dceoy/opencode-action/pulls/127","method":"DELETE"}' \
    '{"endpoint":"repos/dceoy/opencode-action/pulls/127","args":["--jq","env"]}' \
    '{"endpoint":"repos/dceoy/opencode-action/pulls/127","paginate":"true"}' \
    '{"endpoint":"repos/dceoy/opencode-action/pulls/127","payload":{}}' \
    '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":{"event":"APPROVE"}}' \
    '{"endpoint":"bad","endpoint":"repos/dceoy/opencode-action/pulls/127"}' \
    '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":{"event":"APPROVE","event":"COMMENT"}}'; do
    printf '%s' "${request}" > "${request_file}"
    run_request
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "structured requests return decoded immutable blobs and reject truncated trees" {
  set_git_candidate ghs_verified
  sha=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  printf '{"endpoint":"repos/dceoy/opencode-action/git/blobs/%s"}' "${sha}" > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  jq -e '.content == "Frozen evidence\n" and .next_offset == null' <<< "${output}"
  printf '{"endpoint":"repos/dceoy/opencode-action/git/trees/%s"}' "${sha}" > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  jq -e '.content | fromjson | .truncated == false' <<< "${output}"
  export GH_TREE_TRUNCATED=true
  run_request
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Truncated tree"* ]]
}

@test "structured response pages reconstruct oversized metadata and Unicode blobs" {
  set_git_candidate ghs_verified
  run env -u GH_TOKEN -u GITHUB_TOKEN HOME="${request_home}" \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" PATH="${fake_bin}:${PATH}" \
    PR_REVIEW_URL=https://github.com/dceoy/opencode-action/pull/127 \
    python3 - "${wrapper}" "${temp_repo}" "${BATS_TEST_TMPDIR}" << 'PYCODE'
import base64
import json
import os
import subprocess
import sys
from pathlib import Path

wrapper, repo, temporary = sys.argv[1:]
text = ("Frozen evidence 日本語\n" * 3000)
response = Path(temporary) / "response.json"
for kind in ["metadata", "blob"]:
    if kind == "blob":
        response.write_text(json.dumps({"encoding": "base64", "content": base64.b64encode(text.encode()).decode()}))
        endpoint = "repos/dceoy/opencode-action/git/blobs/abcdefabcdefabcdefabcdefabcdefabcdefabcd"
    else:
        response.write_text(text)
        endpoint = "repos/dceoy/opencode-action/pulls/127/files"
    chunks, offset = [], 0
    while True:
        raw = subprocess.check_output(["bash", wrapper, "--request-stdin"],
            input=json.dumps({"endpoint": endpoint, "offset": offset, "limit": 4096}).encode(),
            cwd=repo, env={**os.environ, "GH_RESPONSE_FILE": str(response)})
        assert len(raw) < 32768
        page = json.loads(raw)
        assert page["offset"] == offset and page["total_chars"] == len(text)
        chunks.append(page["content"])
        offset = page["next_offset"]
        if offset is None:
            break
    assert "".join(chunks) == text
PYCODE
  [ "${status}" -eq 0 ]
}

@test "structured paging rejects invalid bounds before credentials" {
  for bounds in '"offset":true' '"offset":-1' '"offset":1.5' '"offset":"0"' \
    '"limit":false' '"limit":0' '"limit":4097' '"limit":1.5' '"limit":"10"' \
    '"paginate":true,"page":0' '"paginate":true,"page":10001' \
    '"paginate":true,"page":true' '"paginate":true,"page":1.5' \
    '"paginate":false,"page":1'; do
    printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127",%s}' "${bounds}" > "${request_file}"
    run_request
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
  request_head=abcdefabcdefabcdefabcdefabcdefabcdefabcd
  printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","offset":0,"payload":{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}}' "${request_head}" > "${request_file}"
  run_request
  [ "${status}" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
}

@test "paginated requests advance remote pages without downloading earlier pages again" {
  set_git_candidate ghs_verified
  fixture_dir="${BATS_TEST_TMPDIR}/pages"
  mkdir -p "${fixture_dir}"
  python3 - "${fixture_dir}" << 'PYCODE'
import json
import sys
from pathlib import Path
directory = Path(sys.argv[1])
(directory / "1.json").write_text(json.dumps(
    [{"id": i, "body": "Large evidence 日本語" * 80} for i in range(10)],
    ensure_ascii=False))
(directory / "2.json").write_text(json.dumps([{"id": 10, "body": "Final record"}]))
PYCODE
  run env -u GH_TOKEN -u GITHUB_TOKEN HOME="${request_home}" \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" GH_ARGS_LOG="${BATS_TEST_TMPDIR}/gh-args" \
    GH_PAGED_FIXTURE_DIR="${fixture_dir}" PATH="${fake_bin}:${PATH}" \
    PR_REVIEW_URL=https://github.com/dceoy/opencode-action/pull/127 \
    python3 - "${wrapper}" "${temp_repo}" "${BATS_TEST_TMPDIR}/gh-args" << 'PYCODE'
import json
import os
import subprocess
import sys
from pathlib import Path

wrapper, repo, log_path = sys.argv[1:]
page, offset, texts = 1, 0, []
while True:
    request = {"endpoint": "repos/dceoy/opencode-action/pulls/127/files",
               "paginate": True, "page": page, "offset": offset, "limit": 4096}
    raw = subprocess.check_output(["bash", wrapper, "--request-stdin"],
        input=json.dumps(request).encode(), cwd=repo)
    result = json.loads(raw)
    assert result["page"] == page
    texts.append(result["content"])
    if result["next_offset"] is not None:
        assert result["next_page"] is None
        offset = result["next_offset"]
        continue
    items = json.loads("".join(texts))
    if page == 1:
        assert len(items) == 10
        assert result["next_page"] == 2
    else:
        assert len(items) == 1 and items[0]["id"] == 10
        assert result["next_page"] is None
        break
    page, offset, texts = result["next_page"], 0, []

requests = [line for line in Path(log_path).read_text().splitlines()
            if "?per_page=10&page=" in line]
assert len(requests) >= 3
assert any("page=1 " in line for line in requests)
assert any("page=2 " in line for line in requests)
assert all("page=2 " not in line for line in requests[:-1])
assert "page=2 " in requests[-1]
assert all("--paginate" not in line for line in requests)
PYCODE
  [ "${status}" -eq 0 ]
}

@test "pagination rejects singleton and immutable endpoints before auth" {
  for endpoint in repos/dceoy/opencode-action/pulls/127 \
      repos/dceoy/opencode-action/git/blobs/abcdefabcdefabcdefabcdefabcdefabcdefabcd; do
    printf '{"endpoint":"%s","paginate":true}' "${endpoint}" > "${request_file}"
    run_request
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}
