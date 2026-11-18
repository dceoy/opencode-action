#!/usr/bin/env bats
# shellcheck disable=SC2016  # Literal workflow expressions are matched as text.
# Regression tests for the workflow trigger contract, independent of model selection.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  bot="${repo_root}/.github/workflows/opencode-bot.yml"
  review="${repo_root}/.github/workflows/opencode-review.yml"
  check_script="${BATS_TEST_TMPDIR}/comment-trigger.py"
  python3 - "${bot}" "${check_script}" << 'PY'
import sys
import textwrap
from pathlib import Path

source = Path(sys.argv[1]).read_text()
code = source.split("          python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0]
Path(sys.argv[2]).write_text(textwrap.dedent(code))
PY
}

@test "comment triggers honor the custom mentions independently of the required model" {
  for example in '/TEAM-REVIEW please examine|/team-review|true' \
    '/oc fix the issue|/opencode,/oc|true' \
    '/OC, take a look|/opencode,/oc|true' \
    'please review this PR|please review|true' \
    'please do review this PR|please review|false' \
    '@opencode, fix this|@opencode|true' \
    'I installed opencode locally|@opencode|false' \
    '/unrelated message|/opencode,/oc|false' \
    '/oc fix the issue|/team-review|false' \
    'https://github.com/octocat/example|/opencode,/oc|false' \
    'have you seen /october updates?|/opencode,/oc|false' \
    'path/octocat/example|/opencode,/oc|false'; do
    IFS='|' read -r body mentions expected <<< "${example}"
    output_file="${BATS_TEST_TMPDIR}/trigger-output"
    : > "${output_file}"
    env COMMENT_BODY="${body}" MENTIONS="${mentions}" GITHUB_OUTPUT="${output_file}" \
      python3 "${check_script}"
    [ "$(cat "${output_file}")" = "matched=${expected}" ]
  done
}

@test "PR review job always enforces author, draft, and bot policies" {
  run grep -Fq "inputs.model != ''" "${review}"
  [ "${status}" -ne 0 ]
  grep -Fq "github.event.pull_request.author_association" "${review}"
  grep -Fq "! github.event.pull_request.draft" "${review}"
  grep -Fq "github.event.pull_request.user.type != 'Bot'" "${review}"
}

@test "bot job gates execution on comment mention detection" {
  run grep -Fq "inputs.model != ''" "${bot}"
  [ "${status}" -ne 0 ]
  [ "$(grep -Fc "steps.comment-trigger.outputs.matched == 'true'" "${bot}")" -ge 2 ]
  grep -Fq "inputs.mentions || '/opencode,/oc'" "${bot}"
}

@test "review-only environment overrides never escape the composite run step" {
  action="${repo_root}/action.yml"
  grep -Fq 'review_home="$(mktemp -d' "${action}"
  grep -Fq 'export HOME="${review_home}"' "${action}"
  grep -Fq "trap 'rm -rf -- " "${action}"
  run grep -F 'GITHUB_ENV' "${action}"
  [ "${status}" -ne 0 ]
}

@test "PR review retains public input compatibility across pr-loop migration" {
  for input in agent mentions use-bundled-toolkit; do
    grep -Eq "^      ${input}:" "${review}"
    grep -Fq "inputs.${input}" "${review}"
  done
  grep -Fq '          review-only: true' "${review}"
}

@test "bot does not subscribe to issue or PR conversation comments" {
  # yq parses YAML 1.2, preserving "on" as a string; it is installed on
  # the ubuntu-slim runner used by the Bats CI job.
  run yq -e 'explode(.) | (.on | tag) == "!!map" and (.on | has("issue_comment") == false) and (.on | has("pull_request_review_comment"))' "${bot}"
  [ "${status}" -eq 0 ]
}

@test "review comment execution requires a trusted non-bot author" {
  run python3 - "${bot}" << 'PYCODE'
import re
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text()
match = re.findall(
    r"^jobs:\n  opencode-bot:\n    if: >\n((?:      .*\n|\n)+)    runs-on:",
    workflow, re.MULTILINE,
)
assert len(match) == 1, "could not uniquely extract the bot job condition"
condition = " ".join(match[0].split())
expected = " ".join("""
    ( github.event_name == 'pull_request_review_comment'
      && github.event.comment.user.type != 'Bot'
      && contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)
    ) || ( github.event_name != 'pull_request_review_comment'
      && inputs.prompt != '' )
""".split())
assert condition == expected, "bot job condition changed"
PYCODE
  [ "${status}" -eq 0 ]
}
