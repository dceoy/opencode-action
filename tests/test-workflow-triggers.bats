#!/usr/bin/env bats
# Regression tests for the workflow trigger contract, independent of model selection.

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  bot="${repo_root}/.github/workflows/opencode-bot.yml"
  review="${repo_root}/.github/workflows/opencode-review.yml"
  check_script="${BATS_TEST_TMPDIR}/comment-trigger.py"
  python3 - "${bot}" "${check_script}" <<'PY'
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
    '/unrelated message|/opencode,/oc|false' \
    '/oc fix the issue|/team-review|false'; do
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
