#!/usr/bin/env bats
# Regression test for the Renovate-managed OpenCode version pin.

@test "OpenCode v1 defaults are consistent and discoverable by Renovate" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  run python3 - "${repo_root}" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
config = json.loads((root / ".github/renovate.json").read_text())
manager = next(
    item for item in config["customManagers"]
    if "OpenCode" in item.get("description", "")
)
paths = [
    "action.yml",
    ".github/workflows/opencode-bot.yml",
    ".github/workflows/opencode-review.yml",
]
versions = set()
for path in paths:
    content = (root / path).read_text()
    assert any(re.search(pattern[1:-1], path) for pattern in manager["managerFilePatterns"]), path
    matches = list(re.finditer(manager["matchStrings"][0], content))
    assert len(matches) == 1, (path, len(matches))
    match = matches[0].groupdict()
    assert match["datasource"] == "github-releases", path
    assert match["depName"] == "anomalyco/opencode", path
    assert match["versioning"] == "semver", path
    assert re.fullmatch(r"v1\.\d+\.\d+", match["currentValue"]), path
    versions.add(match["currentValue"])
    if path != "action.yml":
        assert "opencode-version: ${{ inputs.opencode-version }}" in content, path
assert len(versions) == 1, versions
assert any(
    rule.get("matchPackageNames") == ["anomalyco/opencode"]
    and rule.get("matchDatasources") == ["github-releases"]
    and rule.get("allowedVersions") == "<2.0.0"
    for rule in config["packageRules"]
)
PY
  [ "${status}" -eq 0 ]
}
