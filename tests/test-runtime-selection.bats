#!/usr/bin/env bats
# shellcheck disable=SC2016 # Single-quoted programs expand in the child shell.
setup() {
  root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  touch "${GITHUB_OUTPUT}"
}

@test "installed binaries must report the exact selected release and major" {
  for spec in 'v1 1.19.3 1.19.3 0' 'v2 2.3.0 opencode_v2.3.0 0' 'v1 1.19.3 2.3.0 1' 'v2 2.3.0 opencode_v2.3.1 1' 'v2 2.3.0 garbage_v2.3.0 1'; do
    read -r runtime version reported result <<< "${spec}"
    export OPENCODE_INSTALL_HOME="${BATS_TEST_TMPDIR}/${runtime}"
    mkdir -p "${OPENCODE_INSTALL_HOME}/.opencode/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "${reported//_/ }" > "${OPENCODE_INSTALL_HOME}/.opencode/bin/opencode"
    chmod +x "${OPENCODE_INSTALL_HOME}/.opencode/bin/opencode"
    run env OPENCODE_RUNTIME="${runtime}" OPENCODE_VERSION="${version}" "${root}/scripts/verify-opencode.sh"
    [ "${status}" -eq "${result}" ]
    if [ "${result}" -eq 0 ]; then
      [[ "${output}" == *"installed version ${version}"* ]]
      grep -qx "runtime=${runtime}" "${GITHUB_OUTPUT}"
      grep -qx "opencode-version=${version}" "${GITHUB_OUTPUT}"
    fi
  done
  export OPENCODE_INSTALL_HOME="${BATS_TEST_TMPDIR}/missing"
  run env OPENCODE_RUNTIME=v1 OPENCODE_VERSION=1.19.3 "${root}/scripts/verify-opencode.sh"
  [ "${status}" -ne 0 ]
}

@test "v2 runtime is accepted" {
  run env OPENCODE_RUNTIME=v2 bash -c 'source "$1"; opencode_validate_runtime' _ "${root}/scripts/run-opencode.sh"
  [ "${status}" -eq 0 ]
}

@test "installers use separate homes for sequential and parallel major installs" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  cat > "${fake_bin}/curl" <<'SCRIPT'
#!/usr/bin/env bash
case "$2" in
  https://opencode.ai/install) major=1 ;;
  https://opencode.ai/v2/install) major=2 ;;
  *) exit 1 ;;
esac
cat > "$4" <<INSTALLER
#!/usr/bin/env bash
set -eu
[[ "\$1" == --version && "\$3" == --no-modify-path ]]
[[ "\$2" == ${major}.* ]]
mkdir -p "\$HOME/.opencode/bin"
printf '%s\n' '${major}' > "\$HOME/.opencode/bin/installed-major"
INSTALLER
SCRIPT
  cat > "${fake_bin}/shasum" <<'SCRIPT'
#!/usr/bin/env bash
if grep -q '== 1.\*' "$3"; then
  echo 'a2dd59522b9a091b6cdb2e4870c0f2135f7da09807cd5a7e04222d4316925b72  fixture'
else
  echo 'bbc4584fd6a888bcd14623b8a63afa0f1b4075a2e84a2c3518cd509b446b3135  fixture'
fi
SCRIPT
  chmod +x "${fake_bin}/curl" "${fake_bin}/shasum"
  export PATH="${fake_bin}:${PATH}"
  for runtime in v1 v2; do
    major="${runtime#v}"
    run env OPENCODE_RUNTIME="${runtime}" OPENCODE_VERSION="${major}.2.3" OPENCODE_INSTALL_HOME="${BATS_TEST_TMPDIR}/${runtime}" "${root}/scripts/install-opencode.sh"
    [ "${status}" -eq 0 ]
  done
  env OPENCODE_RUNTIME=v1 OPENCODE_VERSION=1.2.3 OPENCODE_INSTALL_HOME="${BATS_TEST_TMPDIR}/v1" "${root}/scripts/install-opencode.sh" &
  pid1=$!
  env OPENCODE_RUNTIME=v2 OPENCODE_VERSION=2.2.3 OPENCODE_INSTALL_HOME="${BATS_TEST_TMPDIR}/v2" "${root}/scripts/install-opencode.sh" &
  pid2=$!
  wait "${pid1}"
  wait "${pid2}"
  [ "$(cat "${BATS_TEST_TMPDIR}/v1/.opencode/bin/installed-major")" = 1 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/v2/.opencode/bin/installed-major")" = 2 ]
}

@test "v2 command uses the selected binary and preserves the trusted prompt and variant" {
  binary="${BATS_TEST_TMPDIR}/opencode"
  printf '#!/bin/bash\necho "opencode v2.3.0"\n' > "${binary}"
  chmod +x "${binary}"
  run env OPENCODE_BIN="${binary}" OPENCODE_RUNTIME=v2 MODEL=provider/model VARIANT=fast \
    AGENT=action-pr-review PROMPT='trusted prompt' bash -c \
    'source "$1"; opencode_select_run_command; printf "<%s>\n" "${OPENCODE_RUN_COMMAND[@]}"' _ "${root}/scripts/run-opencode.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "<${binary}>
<run>
<--standalone>
<--model>
<provider/model#fast>
<--agent>
<action-pr-review>
<trusted prompt>" ]
}

@test "v2 command rejects a missing or malformed model before execution" {
  binary="${BATS_TEST_TMPDIR}/opencode"
  printf '#!/bin/bash\necho "opencode v2.3.0"\n' > "${binary}"
  chmod +x "${binary}"
  for model in '' model 'provider/model#variant' 'provider/'; do
    run env OPENCODE_BIN="${binary}" OPENCODE_RUNTIME=v2 MODEL="${model}" \
      AGENT=action-pr-review PROMPT=trusted bash -c \
      'source "$1"; opencode_select_run_command' _ "${root}/scripts/run-opencode.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'requires a model'* ]]
  done
}
