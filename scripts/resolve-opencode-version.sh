#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

runtime = os.environ.get("INPUT_RUNTIME", "")
review_only = os.environ.get("REVIEW_ONLY", "") == "true"
age = os.environ.get("MINIMUM_RELEASE_AGE") or "24h"


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


if runtime not in ("v1", "v2"):
    fail(f"Invalid runtime '{runtime}'; choose v1 or v2.")
match = re.fullmatch(r"(0|[1-9][0-9]*)([smhdw])", age)
if not match:
    fail(f"Invalid minimum-release-age '{age}'; use a duration such as 24h, 7d, or 0s.")

amount, unit = match.groups()
cutoff = datetime.now(timezone.utc) - timedelta(
    seconds=int(amount) * {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}[unit]
)
tag_pattern = re.compile(rf"v{runtime[1:]}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
selected = None
for page in range(1, 21):
    try:
        response = subprocess.run(
            ["gh", "api", f"repos/anomalyco/opencode/releases?per_page=100&page={page}"],
            capture_output=True, text=True, check=True,
        )
        releases = json.loads(response.stdout)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        fail(f"Could not fetch OpenCode GitHub releases: {exc}")
    if not isinstance(releases, list):
        fail("GitHub releases API returned an unexpected response.")
    eligible = []
    for release in releases:
        if not isinstance(release, dict) or release.get("draft") or release.get("prerelease"):
            continue
        tag = release.get("tag_name", "")
        if not isinstance(tag, str) or not tag_pattern.fullmatch(tag):
            continue
        try:
            published = datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
            if published.tzinfo is None or published > cutoff:
                continue
        except (KeyError, AttributeError, ValueError, TypeError):
            continue
        version = tuple(map(int, tag[1:].split(".")))
        if runtime == "v1" and review_only and version < (1, 2, 14):
            continue
        eligible.append((version, tag, published))
    if eligible:
        selected = max(eligible, key=lambda item: item[0])
        break
    if len(releases) < 100:
        break

if selected is None:
    fail(f"No stable OpenCode {runtime} release satisfies minimum-release-age={age}.")
_, tag, published = selected
version = tag[1:]
with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
    output.write(f"opencode-version={version}\nruntime={runtime}\n")
print(
    f"::notice::Selected OpenCode {runtime} {tag}, published "
    f"{published.isoformat()}, minimum release age {age}."
)
PY
