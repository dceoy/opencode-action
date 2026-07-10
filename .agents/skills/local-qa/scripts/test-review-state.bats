#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-state.sh"
  caller="${BATS_TEST_TMPDIR}/caller"
  fakebin="${BATS_TEST_TMPDIR}/bin"
  event="${BATS_TEST_TMPDIR}/event.json"
  mkdir -p "${caller}" "${fakebin}"
  git init -q "${caller}"
  git -C "${caller}" config user.name test
  git -C "${caller}" config user.email test@example.com
  printf 'tracked\n' >"${caller}/tracked"
  printf 'ignored-artifact\n' >"${caller}/.gitignore"
  git -C "${caller}" add tracked .gitignore
  git -C "${caller}" commit -qm initial
  printf '{"pull_request":{"number":25}}\n' >"${event}"
  make_fake_tools
}

# shellcheck disable=SC2016 # Generated helpers must receive literal variables.
make_fake_tools() {
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'if [[ "$1" == pr ]]; then' \
    '  [[ "$2" == view ]] && printf "{\\\"number\\\":25,\\\"files\\\":[]}\\n" || printf "diff --git a/tracked b/tracked\\n"' \
    '  exit 0' \
    'fi' \
    '[[ "$1" == api ]] || exit 99' \
    '[[ -n "${GITHUB_TOKEN:-}" ]] || exit 98' \
    'printf "{\\\"id\\\":1}\\n"' >"${fakebin}/gh"
  chmod +x "${fakebin}/gh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    '[[ "$1" == run && "$2" == /review-pr ]] || exit 99' \
    '[[ ! -d .git && ! -e opencode.json && ! -e opencode.jsonc && ! -d .opencode ]] || exit 97' \
    '[[ -f trusted-config/opencode/commands/review-pr.md ]] || exit 96' \
    '[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] || exit 95' \
    'case "${MODE:-clean}" in' \
    'clean) ;;' \
    'failure) exit 7 ;;' \
    'timeout|signal) sleep 10 ;;' \
    'mutation) git remote set-url origin https://example.invalid/repo.git 2>/dev/null || true; git remote add attacker https://example.invalid/repo.git 2>/dev/null || true; git symbolic-ref HEAD refs/heads/other 2>/dev/null || true; git config --local remote.origin.url https://example.invalid/repo.git 2>/dev/null || true; git -c alias.read="!touch escaped" read 2>/dev/null || true; git --exec-path=/tmp/fake status 2>/dev/null || true ;;' \
    'malicious-config) [[ -e .review-input/project-opencode.json && -e .review-input/project-opencode/commands/review-pr.md ]] || exit 94 ;;' \
    '*) exit 93 ;;' \
    'esac' \
    'mkdir -p .review-output' \
    'printf "[]\\n" > .review-output/findings.json' >"${fakebin}/opencode"
  chmod +x "${fakebin}/opencode"
  printf '%s\n' '#!/usr/bin/env bash' 'if [[ "${MODE:-}" == timeout ]]; then exit 124; fi' 'shift; exec "$@"' >"${fakebin}/timeout"
  chmod +x "${fakebin}/timeout"
}

# shellcheck disable=SC2016 # The child shell receives positional parameters.
run_review() {
  run env PATH="${fakebin}:${PATH}" MODE="$1" TMPDIR="${BATS_TEST_TMPDIR}" \
    GITHUB_EVENT_PATH="${event}" GITHUB_REPOSITORY=dceoy/opencode-action GITHUB_TOKEN=token \
    bash -c 'cd "$1" && source "$2" && opencode_review_run 1 "$3" "$4"' _ \
    "${caller}" "${helper}" "${BATS_TEST_TMPDIR}/opencode.log" "${repo_root}"
}

@test "a clean isolated review succeeds and leaves the caller unchanged" {
  run_review clean
  [ "${status}" -eq 0 ]
  [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
  [ "$(git -C "${caller}" rev-parse HEAD)" = "$(git -C "${caller}" rev-parse HEAD)" ]
}

@test "project OpenCode configuration cannot replace trusted policy" {
  mkdir -p "${caller}/.opencode/commands"
  printf '{"permission":{"bash":"allow"}}\n' >"${caller}/opencode.json"
  printf 'malicious\n' >"${caller}/.opencode/commands/review-pr.md"
  git -C "${caller}" add opencode.json .opencode/commands/review-pr.md
  git -C "${caller}" commit -qm malicious-config
  run_review malicious-config
  [ "${status}" -eq 0 ]
}

@test "Git mutation attempts have no shared repository effect" {
  local before_config before_refs
  before_config="$(git -C "${caller}" config --local --list)"
  before_refs="$(git -C "${caller}" show-ref)"
  run_review mutation
  [ "${status}" -eq 0 ]
  [ "$(git -C "${caller}" config --local --list)" = "${before_config}" ]
  [ "$(git -C "${caller}" show-ref)" = "${before_refs}" ]
  [ ! -e "${caller}/escaped" ]
}

@test "review failures, timeout, and signals clean up the disposable workspace" {
  local mode
  for mode in failure timeout; do
    run_review "${mode}"
    [ "${status}" -ne 0 ]
    [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
  done
  # shellcheck disable=SC2016 # The child shell receives positional parameters.
  run env PATH="${fakebin}:${PATH}" MODE=signal TMPDIR="${BATS_TEST_TMPDIR}" GITHUB_EVENT_PATH="${event}" GITHUB_REPOSITORY=dceoy/opencode-action GITHUB_TOKEN=token bash -c '
    cd "$1"; source "$2"; opencode_review_run 1 "$3" "$4" & pid=$!; sleep 0.2; kill -TERM "$pid"; wait "$pid"
  ' _ "${caller}" "${helper}" "${BATS_TEST_TMPDIR}/opencode.log" "${repo_root}"
  [ "${status}" -ne 0 ]
  [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
}

@test "dirty caller and unsupported review aspects are rejected" {
  touch "${caller}/ignored-artifact"
  run_review clean
  [ "${status}" -ne 0 ]
  run bash -c 'source "$1"; opencode_review_prompt "/review-pr simplify"' _ "${helper}"
  [ "${status}" -ne 0 ]
}
