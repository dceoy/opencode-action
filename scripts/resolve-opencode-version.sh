#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

runtime = os.environ.get("INPUT_RUNTIME", "")
review_only = os.environ.get("REVIEW_ONLY", "") == "true"
age = os.environ.get("MINIMUM_RELEASE_AGE") or "24h"
api_base = (os.environ.get("GITHUB_API_URL") or "https://api.github.com").rstrip("/")
token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


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
    url = f"{api_base}/repos/anomalyco/opencode/releases?per_page=100&page={page}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "opencode-action",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            releases = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"Could not fetch OpenCode GitHub releases: {exc}")
    if not isinstance(releases, list):
        fail("GitHub releases API returned an unexpected response.")
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
        candidate = (version, tag, published)
        if selected is None or candidate[0] > selected[0]:
            selected = candidate
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
