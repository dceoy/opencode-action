#!/usr/bin/env bats

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  helper="${repo_root}/.opencode/scripts/review-state.sh"
  caller="${BATS_TEST_TMPDIR}/caller"
  fakebin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${caller}" "${fakebin}"
  git init -q "${caller}"
  git -C "${caller}" config user.name test
  git -C "${caller}" config user.email test@example.com
  printf 'tracked\n' >"${caller}/tracked"
  printf 'ignored\n' >"${caller}/.gitignore"
  git -C "${caller}" add tracked .gitignore
  git -C "${caller}" commit -qm initial
  make_fake_opencode
}

# shellcheck disable=SC2016 # The generated helper must receive literal variables.
make_fake_opencode() {
  local fake="${fakebin}/opencode"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'case "${MODE:-clean}" in' \
    'clean) ;;' \
    'tracked) printf changed > tracked ;;' \
    'staged) printf staged > tracked; "${OPENCODE_REAL_GIT}" add tracked ;;' \
    'untracked) touch generated ;;' \
    'ignored-create) touch ignored-artifact ;;' \
    'delete) rm tracked ;;' \
    'mode) chmod +x tracked ;;' \
    'symlink) ln -s tracked link ;;' \
    'commit) git -c user.name=test commit --allow-empty -m blocked ;;' \
    'push) git -C "$PWD" push origin HEAD ;;' \
    'failure) exit 7 ;;' \
    'timeout) sleep 2 ;;' \
    'signal) sleep 10 ;;' \
    '*) exit 99 ;;' \
    'esac' >"${fake}"
  chmod +x "${fake}"
  printf '%s\n' '#!/usr/bin/env bash' 'if [[ "${MODE:-}" == timeout ]]; then exit 124; fi' 'shift; exec "$@"' >"${fakebin}/timeout"
  chmod +x "${fakebin}/timeout"
}

# shellcheck disable=SC2016 # The child shell receives positional parameters.
run_review() {
  run env PATH="${fakebin}:${PATH}" MODE="$1" TMPDIR="${BATS_TEST_TMPDIR}" bash -c 'cd "$1" && source "$2" && opencode_review_run 1 "$3"' _ "${caller}" "${helper}" "${BATS_TEST_TMPDIR}/opencode.log"
}

@test "isolated review succeeds and removes its disposable worktree" {
  run_review clean
  [ "${status}" -eq 0 ]
  [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
  [ "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'tmp.*' | wc -l | tr -d ' ')" = 0 ]
}

@test "review invariant rejects all filesystem mutations and preserves the caller" {
  local mode
  for mode in tracked staged untracked ignored-create delete mode symlink; do
    run_review "${mode}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'Unexpected filesystem or Git mutation'* ]]
    [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
  done
}

@test "snapshot detects a change to an existing ignored file" {
  local first second
  printf first >"${caller}/ignored-artifact"
  first="${BATS_TEST_TMPDIR}/first"
  second="${BATS_TEST_TMPDIR}/second"
  run bash -c 'cd "$1" && source "$2" && opencode_review_snapshot "$3" && printf second > ignored-artifact && opencode_review_snapshot "$4" && cmp -s "$3" "$4"' _ "${caller}" "${helper}" "${first}" "${second}"
  [ "${status}" -ne 0 ]
}

@test "Git proxy blocks global-option commit and push bypasses before a local commit" {
  local mode
  for mode in commit push; do
    run_review "${mode}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'review Git proxy: blocked mutating Git command'* ]]
    [ "$(git -C "${caller}" rev-list --count HEAD)" = 1 ]
  done
}

@test "Git proxy parses argument-bearing global options and fails closed" {
  local proxy="${BATS_TEST_TMPDIR}/git"
  cp "${helper}" "${proxy}"
  chmod +x "${proxy}"
  run env OPENCODE_REVIEW_GIT_PROXY=1 OPENCODE_REAL_GIT="$(command -v git)" "${proxy}" -c user.name=test commit --allow-empty -m blocked
  [ "${status}" -eq 126 ]
  run env OPENCODE_REVIEW_GIT_PROXY=1 OPENCODE_REAL_GIT="$(command -v git)" "${proxy}" -C "${caller}" push origin HEAD
  [ "${status}" -eq 126 ]
  run env OPENCODE_REVIEW_GIT_PROXY=1 OPENCODE_REAL_GIT="$(command -v git)" "${proxy}" --git-dir="${caller}/.git" reset --hard
  [ "${status}" -eq 126 ]
  run env OPENCODE_REVIEW_GIT_PROXY=1 OPENCODE_REAL_GIT="$(command -v git)" ENV=x "${proxy}" --config-env=http.extraheader=ENV push
  [ "${status}" -eq 126 ]
}

@test "OpenCode failures and timeouts propagate and clean up" {
  local mode
  for mode in failure timeout; do
    run_review "${mode}"
    [ "${status}" -ne 0 ]
    [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
    [ "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'tmp.*' | wc -l | tr -d ' ')" = 0 ]
  done
}

@test "a signal cleans up the disposable review worktree" {
  # shellcheck disable=SC2016 # The child shell receives positional parameters.
  run env PATH="${fakebin}:${PATH}" MODE=signal TMPDIR="${BATS_TEST_TMPDIR}" bash -c '
    cd "$1"
    source "$2"
    opencode_review_run 1 "$3" &
    pid=$!
    sleep 0.2
    kill -TERM "$pid"
    wait "$pid"
  ' _ "${caller}" "${helper}" "${BATS_TEST_TMPDIR}/opencode.log"
  [ "${status}" -ne 0 ]
  [ "$(git -C "${caller}" status --porcelain --ignored=matching)" = '' ]
  [ "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'tmp.*' | wc -l | tr -d ' ')" = 0 ]
}

@test "dirty caller checkout is rejected before OpenCode starts" {
  touch "${caller}/already-there"
  run_review clean
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'Refusing /review-pr because the caller checkout'* ]]
  [ ! -f "${BATS_TEST_TMPDIR}/opencode.log" ]
}

@test "only supported non-mutating review aspects select the isolated path" {
  run bash -c 'source "$1"; opencode_review_prompt "/review-pr security performance"' _ "${helper}"
  [ "${status}" -eq 0 ]
  run bash -c 'source "$1"; opencode_review_prompt "/review-pr simplify"' _ "${helper}"
  [ "${status}" -ne 0 ]
}
