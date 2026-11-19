#!/usr/bin/env bats

setup() {
  root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "${GITHUB_OUTPUT}"
  export MOCK_RELEASES_DIR="${BATS_TEST_TMPDIR}/releases"
  mkdir -p "${MOCK_RELEASES_DIR}" "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == api ]] || exit 2
[[ "${MOCK_API_ERROR:-}" != 1 ]] || exit 1
page="${2##*page=}"
cat "${MOCK_RELEASES_DIR}/page-${page}.json"
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  python3 - "${MOCK_RELEASES_DIR}/page-1.json" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)

def release(tag, hours, *, prerelease=False, draft=False):
    return {
        "tag_name": tag, "prerelease": prerelease, "draft": draft,
        "published_at": (now - timedelta(hours=hours)).isoformat().replace("+00:00", "Z"),
        "created_at": (now - timedelta(days=100)).isoformat(),
    }

releases = [
    release("v2.11.0", 1),   # Too recent under the default 24h policy
    release("v2.10.0", 72),  # Numeric semver ordering, not lexical ordering
    release("v2.3.1", 48),
    release("v2.3.0", 240),
    release("v2.1.5", 1000),
    release("v2.99.0-rc.1", 1000, prerelease=True),
    release("v2.99.0", 1000, draft=True),
    release("v1.19.6", 48),
    release("v1.2.13", 1000),
    release("process-daemon-v1.0.0", 1000),
]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(releases, output)
PY
}

@test "selects the highest eligible stable v2 version using publication timestamp" {
  run env INPUT_RUNTIME=v2 REVIEW_ONLY=false MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'opencode-version=2.10.0' "${GITHUB_OUTPUT}"
  grep -qx 'runtime=v2' "${GITHUB_OUTPUT}"
}

@test "minimum release age controls selection" {
  for spec in '0s 2.11.0' '7d 2.3.0' '40d 2.1.5'; do
    read -r age expected <<< "${spec}"
    : > "${GITHUB_OUTPUT}"
    run env INPUT_RUNTIME=v2 REVIEW_ONLY=false MINIMUM_RELEASE_AGE="${age}" "${root}/scripts/resolve-opencode-version.sh"
    [ "${status}" -eq 0 ]
    grep -qx "opencode-version=${expected}" "${GITHUB_OUTPUT}"
  done
}

@test "v1 selection excludes v2 and honors the review minimum version" {
  run env INPUT_RUNTIME=v1 REVIEW_ONLY=true MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'opencode-version=1.19.6' "${GITHUB_OUTPUT}"
  python3 - "${MOCK_RELEASES_DIR}/page-1.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    releases = json.load(source)
with open(path, "w", encoding="utf-8") as output:
    json.dump([item for item in releases if item["tag_name"] != "v1.19.6"], output)
PY
  run env INPUT_RUNTIME=v1 REVIEW_ONLY=true MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"No stable OpenCode v1 release"* ]]
}

@test "invalid runtime and release age are rejected" {
  for spec in 'v3 24h' 'v2 24hours' 'v2 -1d' 'v2 01d'; do
    read -r runtime age <<< "${spec}"
    run env INPUT_RUNTIME="${runtime}" MINIMUM_RELEASE_AGE="${age}" "${root}/scripts/resolve-opencode-version.sh"
    [ "${status}" -ne 0 ]
  done
}

@test "GitHub API failures do not bypass the age policy" {
  run env INPUT_RUNTIME=v2 MINIMUM_RELEASE_AGE=24h MOCK_API_ERROR=1 "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Could not fetch OpenCode GitHub releases"* ]]
}

@test "version lookup continues to a second release page when necessary" {
  python3 - "${MOCK_RELEASES_DIR}" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)
fresh = (now - timedelta(minutes=10)).isoformat().replace("+00:00", "Z")
old = (now - timedelta(days=30)).isoformat().replace("+00:00", "Z")
with open(f"{path}/page-1.json", "w", encoding="utf-8") as output:
    json.dump([{"tag_name": "v2.8.0", "published_at": fresh, "prerelease": False, "draft": False}] * 100, output)
with open(f"{path}/page-2.json", "w", encoding="utf-8") as output:
    json.dump([{"tag_name": "v2.7.0", "published_at": old, "prerelease": False, "draft": False}], output)
PY
  run env INPUT_RUNTIME=v2 MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'opencode-version=2.7.0' "${GITHUB_OUTPUT}"
}
