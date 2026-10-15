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
  request_head=abcdefabcdefabcdefabcdefabcdefabcdefabcd
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

run_request() {
  run env -u GH_TOKEN -u GITHUB_TOKEN HOME="${request_home}" \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" GH_ARGS_LOG="${BATS_TEST_TMPDIR}/gh-args" GH_PAYLOAD_LOG="${BATS_TEST_TMPDIR}/payload" \
    PATH="${fake_bin}:${PATH}" PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    PR_REVIEW_HEAD_SHA="${request_head}" \
    bash -c 'cd "$1"; bash "$2" --request-stdin < "$3"' _ "${temp_repo}" "${wrapper}" "${request_file}"
}

assert_no_matching_lines() {
  local pattern="$1" file="$2" count
  count="$(grep -Ec -- "${pattern}" "${file}" || true)"
  [ "${count}" -eq 0 ]
}

@test "publishes a commit-bound COMMENT with verified OpenCode GitHub App identity" {
  set_git_candidate ghs_verified
  printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}}' "${request_head}" > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  [ "$(grep -c -- '--method POST' "${BATS_TEST_TMPDIR}/gh-args")" -eq 2 ]
  [ "$(grep -c -- '--method DELETE' "${BATS_TEST_TMPDIR}/gh-args")" -eq 1 ]
  jq -e '.event == "COMMENT" and .body == "Reviewed"' "${BATS_TEST_TMPDIR}/payload"
}

@test "rejects an unverified App token before publishing" {
  set_git_candidate ghs_wrong
  printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}}' "${request_head}" > "${request_file}"
  run_request
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unable to resolve and verify an OpenCode GitHub App token"* ]]
  [ "$(grep -c -- '--method POST' "${BATS_TEST_TMPDIR}/gh-args")" -eq 1 ]
  [ "$(grep -c -- '--method DELETE' "${BATS_TEST_TMPDIR}/gh-args")" -eq 1 ]
  jq -e 'keys | length == 0' "${BATS_TEST_TMPDIR}/payload"
}

@test "scoped reads use a candidate without identity probes" {
  set_git_candidate ghs_wrong
  printf '%s' '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews"}' > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GITHUB_IDENTITY_TOKEN=ghs_wrong"* ]]
  [ "$(wc -c < "${BATS_TEST_TMPDIR}/gh-calls")" -eq 1 ]
  assert_no_matching_lines '--method (POST|DELETE)' "${BATS_TEST_TMPDIR}/gh-args"
}

@test "explicit workflow-token fallback can publish" {
  set_git_candidate ghs_wrong
  printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":{"event":"COMMENT","body":"Reviewed","commit_id":"%s"}}' "${request_head}" > "${request_file}"
  run env GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" PATH="${fake_bin}:${PATH}" \
    GH_ARGS_LOG="${BATS_TEST_TMPDIR}/gh-args" GH_PAYLOAD_LOG="${BATS_TEST_TMPDIR}/payload" \
    GH_TOKEN=workflow_tok GITHUB_TOKEN=workflow_tok USE_GITHUB_TOKEN=true \
    PR_REVIEW_URL="https://github.com/dceoy/opencode-action/pull/127" \
    PR_REVIEW_HEAD_SHA="${request_head}" \
    bash -c 'cd "$1"; bash "$2" --request-stdin < "$3"' _ "${temp_repo}" "${wrapper}" "${request_file}"
  [ "${status}" -eq 0 ]
  [ "$(grep -c -- '--method POST' "${BATS_TEST_TMPDIR}/gh-args")" -eq 2 ]
  [ "$(grep -c -- '--method DELETE' "${BATS_TEST_TMPDIR}/gh-args")" -eq 1 ]
}

@test "rejects malformed PR context before accessing credentials" {
  printf '%s' '{"endpoint":"repos/dceoy/opencode-action/pulls/127"}' > "${request_file}"
  run env PR_REVIEW_URL=https://github.com/not-valid \
    bash -c 'bash "$1" --request-stdin < "$2"' _ "${wrapper}" "${request_file}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Invalid PR_REVIEW_URL"* ]]
}

@test "legacy direct gh CLI is disabled" {
  for command in api pr; do
    run bash "${wrapper}" "${command}" repos/dceoy/opencode-action/pulls/127
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Use the structured pr-review-api tool"* ]]
  done
  [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
}

@test "internal adapter cannot access unscoped endpoints or non-GET methods" {
  run env PR_REVIEW_URL=https://github.com/dceoy/opencode-action/pull/127 \
    bash "${wrapper}" --scoped-api GET repos/other/repo/pulls/127 ''
  [ "${status}" -eq 2 ]
  run env PR_REVIEW_URL=https://github.com/dceoy/opencode-action/pull/127 \
    bash "${wrapper}" --scoped-api DELETE repos/dceoy/opencode-action/pulls/127 ''
  [ "${status}" -eq 2 ]
  [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
}

@test "rejects approvals wrong commit and duplicate JSON keys" {
  for payload in '{"event":"APPROVE","body":"x"}' \
    '{"event":"COMMENT","body":"x","commit_id":"wrong"}' \
    '{"event":"APPROVE","event":"COMMENT","body":"x"}'; do
    printf '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","method":"POST","payload":%s}' "${payload}" > "${request_file}"
    run_request
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "structured requests allow scoped reads and commit-bound publication" {
  set_git_candidate ghs_verified
  printf '%s' '{"endpoint":"repos/dceoy/opencode-action/pulls/127/reviews","paginate":true}' > "${request_file}"
  run_request
  [ "${status}" -eq 0 ]
  jq -e '.page == 1 and .next_page == null and .next_offset == null' <<< "${output}"
  grep -q 'pulls/127/reviews?per_page=10&page=1' "${BATS_TEST_TMPDIR}/gh-args"
  assert_no_matching_lines '--method (POST|DELETE)' "${BATS_TEST_TMPDIR}/gh-args"
  assert_no_matching_lines '--paginate' "${BATS_TEST_TMPDIR}/gh-args"
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
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" GH_ARGS_LOG="${BATS_TEST_TMPDIR}/gh-args" PATH="${fake_bin}:${PATH}" \
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
args = Path(temporary, "gh-args").read_text().splitlines()
assert args and all("--method GET" in line for line in args)
assert not any("--method POST" in line or "--method DELETE" in line for line in args)
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
    repos/dceoy/opencode-action/commits/abcdefabcdefabcdefabcdefabcdefabcdefabcd \
    repos/other/repo/commits/abcdefabcdefabcdefabcdefabcdefabcdefabcd/check-runs \
    repos/dceoy/opencode-action/commits/invalid/status \
    'repos/dceoy/opencode-action/commits/abcdefabcdefabcdefabcdefabcdefabcdefabcd/status?per_page=100' \
    repos/dceoy/opencode-action/git/blobs/abcdefabcdefabcdefabcdefabcdefabcdefabcd; do
    printf '{"endpoint":"%s","paginate":true}' "${endpoint}" > "${request_file}"
    run_request
    [ "${status}" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/gh-calls" ]
  done
}

@test "CI object pagination preserves metadata and traverses bounded response slices" {
  fixture_dir="${BATS_TEST_TMPDIR}/ci-pages"
  mkdir -p "${fixture_dir}"
  run env -u GH_TOKEN -u GITHUB_TOKEN HOME="${request_home}" \
    GH_CALL_LOG="${BATS_TEST_TMPDIR}/gh-calls" GH_ARGS_LOG="${BATS_TEST_TMPDIR}/gh-args" \
    GH_PAGED_FIXTURE_DIR="${fixture_dir}" PATH="${fake_bin}:${PATH}" \
    PR_REVIEW_URL=https://github.com/dceoy/opencode-action/pull/127 \
    python3 - "${wrapper}" "${temp_repo}" "${fixture_dir}" "${BATS_TEST_TMPDIR}/gh-args" << 'PYCODE'
import json
import subprocess
import sys
from pathlib import Path

wrapper, repo, fixtures, log = sys.argv[1:]
fixtures = Path(fixtures)
for suffix, collection in [("check-runs", "check_runs"), ("status", "statuses")]:
    endpoint = "repos/dceoy/opencode-action/commits/" + "a" * 40 + "/" + suffix
    for count in [10, 1, 0]:
        expected = {"total_count": count, "state": "success", collection:
                    [{"id": i, "body": "CI evidence 日本語" * 80} for i in range(count)]}
        (fixtures / "2.json").write_text(json.dumps(expected, ensure_ascii=False))
        offset, chunks = 0, []
        while True:
            request = {"endpoint": endpoint, "paginate": True, "page": 2, "offset": offset}
            result = json.loads(subprocess.check_output(["bash", wrapper, "--request-stdin"],
                input=json.dumps(request).encode(), cwd=repo))
            assert result["page"] == 2
            assert len(result["content"]) <= 4096
            chunks.append(result["content"])
            offset = result["next_offset"]
            if offset is None:
                assert result["next_page"] == (3 if count == 10 else None)
                break
            assert result["next_page"] is None
        assert json.loads("".join(chunks)) == expected
        if count == 10:
            assert len(chunks) > 1
            (fixtures / "3.json").write_text(json.dumps({collection: []}))
            request = {"endpoint": endpoint, "paginate": True, "page": 3}
            result = json.loads(subprocess.check_output(["bash", wrapper, "--request-stdin"],
                input=json.dumps(request).encode(), cwd=repo))
            assert result["next_page"] is None and result["next_offset"] is None
            assert json.loads(result["content"]) == {collection: []}
    for malformed in [[], {}, {collection: None}, {collection: {}}]:
        (fixtures / "2.json").write_text(json.dumps(malformed))
        request = {"endpoint": endpoint, "paginate": True, "page": 2}
        result = subprocess.run(["bash", wrapper, "--request-stdin"],
            input=json.dumps(request).encode(), cwd=repo, capture_output=True)
        assert result.returncode != 0, (suffix, malformed)
requests = Path(log).read_text().splitlines()
assert all("?per_page=10&page=" in line for line in requests)
assert all("page=1 " not in line and "--paginate" not in line for line in requests)
assert all("--method GET" in line for line in requests)
PYCODE
  [ "${status}" -eq 0 ]
}
