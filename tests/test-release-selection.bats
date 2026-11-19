#!/usr/bin/env bats

setup() {
  root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : > "${GITHUB_OUTPUT}"
  export MOCK_RELEASES_DIR="${BATS_TEST_TMPDIR}/releases"
  mkdir -p "${MOCK_RELEASES_DIR}" "${BATS_TEST_TMPDIR}/bin"
  # The resolver must not require the GitHub CLI: any `gh` invocation fails
  # the run and records that it happened.
  cat > "${BATS_TEST_TMPDIR}/bin/gh" <<'SH'
#!/usr/bin/env bash
touch "${MOCK_RELEASES_DIR}/gh-invoked"
exit 99
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  cat > "${BATS_TEST_TMPDIR}/releases-server.py" <<'PY'
import http.server
import os
from pathlib import Path
from urllib.parse import parse_qs, urlparse

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        root = Path(os.environ["MOCK_RELEASES_DIR"])
        if (root / "api-error").exists():
            self.send_error(500)
            return
        page = parse_qs(urlparse(self.path).query).get("page", ["1"])[0]
        page_file = root / f"page-{page}.json"
        body = page_file.read_bytes() if page_file.exists() else b"[]"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
Path(os.environ["PORT_FILE"]).write_text(str(server.server_port))
server.serve_forever()
PY
  PORT_FILE="${BATS_TEST_TMPDIR}/port" MOCK_RELEASES_DIR="${MOCK_RELEASES_DIR}" \
    python3 "${BATS_TEST_TMPDIR}/releases-server.py" &
  server_pid=$!
  for _ in {1..100}; do [[ -s "${BATS_TEST_TMPDIR}/port" ]] && break; sleep 0.01; done
  export GITHUB_API_URL="http://127.0.0.1:$(cat "${BATS_TEST_TMPDIR}/port")"
  export GH_TOKEN=test-token
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

teardown() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
  fi
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
  touch "${MOCK_RELEASES_DIR}/api-error"
  run env INPUT_RUNTIME=v2 MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Could not fetch OpenCode GitHub releases"* ]]
}

@test "version resolution does not require the GitHub CLI" {
  run env INPUT_RUNTIME=v2 MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'opencode-version=2.10.0' "${GITHUB_OUTPUT}"
  [ ! -e "${MOCK_RELEASES_DIR}/gh-invoked" ]
}

@test "scans all release pages before choosing the SemVer maximum" {
  python3 - "${MOCK_RELEASES_DIR}" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)

def release(tag, hours):
    return {
        "tag_name": tag, "prerelease": False, "draft": False,
        "published_at": (now - timedelta(hours=hours)).isoformat().replace("+00:00", "Z"),
    }

# Page 1 is full and holds an eligible lower version plus ineligible
# recent releases; the higher version was published earlier, on page 2.
page1 = [release("v2.3.1", 48)] + [release("v2.8.0", 1)] * 99
with open(f"{path}/page-1.json", "w", encoding="utf-8") as output:
    json.dump(page1, output)
with open(f"{path}/page-2.json", "w", encoding="utf-8") as output:
    json.dump([release("v2.4.0", 72)], output)
PY
  run env INPUT_RUNTIME=v2 MINIMUM_RELEASE_AGE=24h "${root}/scripts/resolve-opencode-version.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'opencode-version=2.4.0' "${GITHUB_OUTPUT}"
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
