#!/usr/bin/env bats

@test "runtime release-age policy is exposed without a version input" {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  run python3 - "${repo_root}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = [
    "action.yml",
    ".github/workflows/opencode-bot.yml",
    ".github/workflows/opencode-review.yml",
]
for path in paths:
    text = (root / path).read_text()
    assert "minimum-release-age:" in text, path
    assert "default: 24h" in text, path
    assert "opencode-version: ${{ inputs.opencode-version" not in text, path
    if path == "action.yml":
        assert "\n  opencode-version:\n" in text  # The resolved-version output remains.
        assert "\n  opencode-version:\n    required:" not in text
        assert "MINIMUM_RELEASE_AGE: ${{ inputs.minimum-release-age }}" in text
    else:
        assert "minimum-release-age: ${{ inputs.minimum-release-age || '24h' }}" in text
        assert "\n      opencode-version:" not in text
config = json.loads((root / ".github/renovate.json").read_text())
assert not config.get("customManagers"), "Dynamic release selection should not need Renovate pins"
assert config["minimumReleaseAge"] == "1 day"
PY
  [ "${status}" -eq 0 ]
}
