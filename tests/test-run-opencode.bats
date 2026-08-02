#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  run_script="${repo_root}/scripts/run-opencode.sh"
  lib_script="${repo_root}/scripts/opencode-action-lib.sh"
  bundled_config="${repo_root}/.opencode/opencode.jsonc"
  fake_action="${BATS_TEST_TMPDIR}/action"
  fake_home="${BATS_TEST_TMPDIR}/home"
  fake_workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${fake_action}/.opencode" "${fake_home}"
  # Pin XDG_CONFIG_HOME and XDG_DATA_HOME to fake_home rather than inheriting
  # whatever the CI runner has set (both leaked from the runner env before;
  # see the XDG_CONFIG_HOME fix), so _opencode_variant_override_reason's
  # XDG_CONFIG_HOME and persisted-auth-state checks see no override by
  # default. Tests exercising those checks override them explicitly.
  export XDG_CONFIG_HOME="${fake_home}/.config"
  export XDG_DATA_HOME="${fake_home}/.local/share"
}

@test "timeout selection prefers timeout then gtimeout and supports no timeout" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  touch "${fake_bin}/timeout" "${fake_bin}/gtimeout"
  chmod +x "${fake_bin}/timeout" "${fake_bin}/gtimeout"

  run env PATH="${fake_bin}" /bin/bash -euo pipefail -c '
    source "$1"
    opencode_select_timeout_command 7
    printf "%s" "${OPENCODE_TIMEOUT_COMMAND[*]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "timeout 7m" ]

  rm "${fake_bin}/timeout"
  run env PATH="${fake_bin}" /bin/bash -euo pipefail -c '
    source "$1"
    opencode_select_timeout_command 8
    printf "%s" "${OPENCODE_TIMEOUT_COMMAND[*]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "gtimeout 8m" ]

  rm "${fake_bin}/gtimeout"
  run env PATH="${fake_bin}" /bin/bash -euo pipefail -c '
    source "$1"
    opencode_select_timeout_command 9
    printf "size=%s" "${#OPENCODE_TIMEOUT_COMMAND[@]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No timeout command found"* ]]
  [[ "${output}" == *"size=0"* ]]
}

@test "variant validation accepts an empty variant for every model" {
  for model in sakura/preview/Kimi-K2.7-Code myprovider/my-model ''; do
    run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
      bash -euo pipefail -c '
        source "$1"
        source "$2"
        opencode_validate_variant "$3" "" "$4"
      ' _ "${run_script}" "${lib_script}" "${model}" "${bundled_config}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
  done
}

@test "variant validation accepts a declared variant for a bundled model" {
  fixture="${BATS_TEST_TMPDIR}/opencode.jsonc"
  cat > "${fixture}" << 'EOF'
{"provider": {"demo": {"models": {"nested/model": {"variants": {"low": {}, "high": {}}}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant demo/nested/model high "$3"
    ' _ "${run_script}" "${lib_script}" "${fixture}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "variant validation rejects an undeclared variant for a bundled model" {
  fixture="${BATS_TEST_TMPDIR}/opencode.jsonc"
  cat > "${fixture}" << 'EOF'
{"provider": {"demo": {"models": {"nested/model": {"variants": {"low": {}, "high": {}}}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant demo/nested/model thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${fixture}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"demo/nested/model"* ]]
  [[ "${output}" == *"variant 'thinking'"* ]]
  [[ "${output}" == *"Supported variants: high, low."* ]]
  [[ "${output}" == *"leave it empty"* ]]
}

@test "variant validation rejects any variant for a bundled model without declared variants" {
  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"sakura/preview/Kimi-K2.7-Code"* ]]
  [[ "${output}" == *"variant 'thinking'"* ]]
  [[ "${output}" == *"declares no variants"* ]]
  [[ "${output}" == *"Remove the 'variant' input"* ]]
  [[ "${output}" != *"Supported variants"* ]]
}

@test "variant validation passes models absent from the bundled registry through silently" {
  # e.g. OpenCode Go models are discovered dynamically and are never listed
  # in the bundled opencode.jsonc, so warning here on every run would be
  # pure noise unrelated to actual variant compatibility.
  for model in opencode-go/kimi-k3 myprovider/my-model anthropic/claude-opus-5 bare-model; do
    run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
      bash -euo pipefail -c '
        source "$1"
        source "$2"
        opencode_validate_variant "$3" high "$4"
      ' _ "${run_script}" "${lib_script}" "${model}" "${bundled_config}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
  done
}

@test "variant validation warns when a bundled model is declared without a variants key" {
  fixture="${BATS_TEST_TMPDIR}/opencode.jsonc"
  cat > "${fixture}" << 'EOF'
{"provider": {"demo": {"models": {"legacy-model": {"name": "legacy-model"}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant demo/legacy-model high "$3"
    ' _ "${run_script}" "${lib_script}" "${fixture}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"demo/legacy-model"* ]]
  [[ "${output}" == *"does not declare supported variants"* ]]
}

@test "variant validation passes through with a warning when use-bundled-toolkit is false" {
  run env USE_BUNDLED_TOOLKIT=false REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"sakura/preview/Kimi-K2.7-Code"* ]]
  [[ "${output}" == *"use-bundled-toolkit is false"* ]]
}

@test "variant validation passes through with a warning when OPENCODE_CONFIG or OPENCODE_CONFIG_DIR is set" {
  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_CONFIG="/tmp/caller-opencode.json" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"OPENCODE_CONFIG"* ]]
}

@test "variant validation passes through with a warning when OPENCODE_CONFIG_CONTENT redefines the model" {
  override='{"provider":{"sakura":{"models":{"preview/Kimi-K2.7-Code":{}}}}}'

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_CONFIG_CONTENT="${override}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"OPENCODE_CONFIG_CONTENT redefines"* ]]
  [[ "${output}" == *"sakura/preview/Kimi-K2.7-Code"* ]]
}

@test "variant validation ignores OPENCODE_CONFIG_CONTENT that does not touch the model" {
  other='{"provider":{"other":{"models":{"other-model":{}}}}}'

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_CONFIG_CONTENT="${other}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "variant validation passes through with a warning when a project opencode.json redefines the model" {
  mkdir -p "${fake_workspace}"
  cat > "${fake_workspace}/opencode.json" << 'EOF'
{"provider": {"sakura": {"models": {"preview/Kimi-K2.7-Code": {}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"repository's opencode.json redefines"* ]]
}

@test "variant validation passes through with a warning when a project .opencode/opencode.jsonc redefines the model" {
  # OpenCode 1.2.14+ loads .opencode/opencode.json(c) after the repository
  # root opencode.json(c), so a consumer can validly redefine a bundled
  # model there too, e.g. adding "variants.thinking" to a sakura model.
  mkdir -p "${fake_workspace}/.opencode"
  cat > "${fake_workspace}/.opencode/opencode.jsonc" << 'EOF'
{"provider": {"sakura": {"models": {"preview/Kimi-K2.7-Code": {"variants": {"thinking": {}}}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"repository's .opencode/opencode.jsonc redefines"* ]]
}

@test "variant validation passes through with a warning when OPENCODE_CONFIG_CONTENT declares a plugin" {
  # A plugin's config hook can add "variants.thinking" to a bundled model
  # before OpenCode builds its effective provider registry, so this check
  # can't see it, but the plugin declaration itself is visible.
  content='{"plugin":["./my-plugin.js"]}'

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_CONFIG_CONTENT="${content}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"OPENCODE_CONFIG_CONTENT declares a plugin"* ]]
}

@test "variant validation ignores OPENCODE_CONFIG_CONTENT with an empty plugin array" {
  content='{"plugin":[]}'

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_CONFIG_CONTENT="${content}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "variant validation passes through with a warning when a project opencode.json declares a plugin" {
  mkdir -p "${fake_workspace}"
  cat > "${fake_workspace}/opencode.json" << 'EOF'
{"plugin": ["./my-plugin.js"]}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"repository's opencode.json declares a plugin"* ]]
}

@test "variant validation passes through with a warning when the project .opencode/plugins directory is not empty" {
  mkdir -p "${fake_workspace}/.opencode/plugins"
  touch "${fake_workspace}/.opencode/plugins/my-plugin.js"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *".opencode/plugins directory is not empty"* ]]
}

@test "variant validation ignores an empty project .opencode/plugins directory" {
  mkdir -p "${fake_workspace}/.opencode/plugins"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "variant validation passes through with a warning when the global plugins directory is not empty" {
  mkdir -p "${fake_home}/.config/opencode/plugins"
  touch "${fake_home}/.config/opencode/plugins/my-plugin.js"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"/plugins' is not empty"* ]]
}

@test "variant validation still enforces the bundled registry during review-only runs" {
  override='{"provider":{"sakura":{"models":{"preview/Kimi-K2.7-Code":{}}}}}'

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=true GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_CONFIG_CONTENT="${override}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "variant validation passes through with a warning when the managed OpenCode config directory redefines the model" {
  # OpenCode loads a platform managed config directory (managedConfigDir(),
  # "/etc/opencode" by default) last, with higher precedence than even
  # OPENCODE_CONFIG_CONTENT, so an admin-controlled file there can redefine
  # the same model regardless of anything the workflow or this action sets.
  managed_config_dir="${BATS_TEST_TMPDIR}/managed"
  mkdir -p "${managed_config_dir}"
  cat > "${managed_config_dir}/opencode.jsonc" << 'EOF'
{"provider": {"sakura": {"models": {"preview/Kimi-K2.7-Code": {"variants": {"thinking": {}}}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_TEST_MANAGED_CONFIG_DIR="${managed_config_dir}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"managed OpenCode configuration"* ]]
}

@test "variant validation passes through with a warning when the managed OpenCode config directory redefines the model during review-only runs" {
  # Review-only isolation (opencode_configure_run) only clears $HOME-scoped
  # config; it cannot clear the managed config directory, so this preflight
  # must still detect it even though every other override check is skipped
  # in review-only mode.
  managed_config_dir="${BATS_TEST_TMPDIR}/managed-review"
  mkdir -p "${managed_config_dir}"
  cat > "${managed_config_dir}/opencode.jsonc" << 'EOF'
{"provider": {"sakura": {"models": {"preview/Kimi-K2.7-Code": {"variants": {"thinking": {}}}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=true GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_TEST_MANAGED_CONFIG_DIR="${managed_config_dir}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"managed OpenCode configuration"* ]]
}

@test "managed config directory resolution mirrors OpenCode's platform-specific managedConfigDir()" {
  fake_bin="${BATS_TEST_TMPDIR}/uname-bin"
  mkdir -p "${fake_bin}"

  printf '%s\n' '#!/usr/bin/env bash' 'echo Darwin' > "${fake_bin}/uname"
  chmod +x "${fake_bin}/uname"
  run env PATH="${fake_bin}:${PATH}" bash -euo pipefail -c '
    source "$1"
    _opencode_managed_config_dir
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "/Library/Application Support/opencode" ]

  printf '%s\n' '#!/usr/bin/env bash' 'echo MINGW64_NT-10.0' > "${fake_bin}/uname"
  run env PATH="${fake_bin}:${PATH}" ProgramData='C:/ProgramData' bash -euo pipefail -c '
    source "$1"
    _opencode_managed_config_dir
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "C:/ProgramData/opencode" ]

  printf '%s\n' '#!/usr/bin/env bash' 'echo Linux' > "${fake_bin}/uname"
  run env PATH="${fake_bin}:${PATH}" bash -euo pipefail -c '
    source "$1"
    _opencode_managed_config_dir
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "/etc/opencode" ]

  run env PATH="${fake_bin}:${PATH}" OPENCODE_TEST_MANAGED_CONFIG_DIR="/custom/dir" bash -euo pipefail -c '
    source "$1"
    _opencode_managed_config_dir
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "/custom/dir" ]
}

@test "MDM preference detection is overridable for testing and defaults to absent on this host" {
  run bash -euo pipefail -c '
    source "$1"
    if _opencode_mdm_preference_present; then echo present; else echo absent; fi
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "absent" ]

  run env OPENCODE_TEST_MDM_PREFERENCE_PRESENT=true bash -euo pipefail -c '
    source "$1"
    if _opencode_mdm_preference_present; then echo present; else echo absent; fi
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "present" ]

  run env OPENCODE_TEST_MDM_PREFERENCE_PRESENT=false bash -euo pipefail -c '
    source "$1"
    if _opencode_mdm_preference_present; then echo present; else echo absent; fi
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "absent" ]
}

@test "variant validation passes through with a warning when macOS MDM-managed OpenCode preferences are present" {
  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    OPENCODE_TEST_MDM_PREFERENCE_PRESENT=true \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"ai.opencode.managed"* ]]
}

@test "variant validation passes through with a warning when a persisted OpenCode auth state exists" {
  # A logged-in OpenCode account is the precondition for the remote or
  # active-organization configuration OpenCode can merge after
  # OPENCODE_CONFIG_CONTENT; this action cannot inspect that server-side
  # config, so the persisted auth state's mere presence is the signal.
  mkdir -p "${fake_home}/.local/share/opencode"
  printf '{}' > "${fake_home}/.local/share/opencode/auth.json"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"auth.json"* ]]
  [[ "${output}" == *"active-organization"* ]]
}

@test "variant validation passes through with a warning when a persisted OpenCode auth state exists during review-only runs" {
  # Review-only isolation (opencode_configure_run) only resets
  # $HOME/.config/opencode and $HOME/.opencode; it does not clear
  # XDG_DATA_HOME, so a reused runner's persisted auth state survives it.
  mkdir -p "${fake_home}/.local/share/opencode"
  printf '{}' > "${fake_home}/.local/share/opencode/auth.json"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=true GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"auth.json"* ]]
}

@test "variant validation honors a custom XDG_DATA_HOME when checking for a persisted auth state" {
  custom_data_home="${BATS_TEST_TMPDIR}/custom-xdg-data"
  mkdir -p "${custom_data_home}/opencode"
  printf '{}' > "${custom_data_home}/opencode/auth.json"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    XDG_DATA_HOME="${custom_data_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"${custom_data_home}/opencode/auth.json"* ]]
}

@test "variant validation still enforces the bundled registry when no auth state or MDM preference is present" {
  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "variant validation still enforces the bundled registry when the installed global config matches it" {
  # The normal case: prepare-opencode-config.sh copied the bundled file
  # verbatim into the installed config directory, so it stays authoritative.
  mkdir -p "${fake_home}/.config/opencode"
  cp "${bundled_config}" "${fake_home}/.config/opencode/opencode.jsonc"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"declares no variants"* ]]
}

@test "variant validation passes through with a warning when a pre-existing global OpenCode config differs from the bundled registry" {
  # prepare-opencode-config.sh only installs the bundled file when nothing
  # already sits at the destination, so a self-hosted runner with a
  # pre-existing "~/.config/opencode/opencode.jsonc" keeps its own file.
  mkdir -p "${fake_home}/.config/opencode"
  cat > "${fake_home}/.config/opencode/opencode.jsonc" << 'EOF'
{"provider": {"sakura": {"models": {"preview/Kimi-K2.7-Code": {}}}}}
EOF

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"installed OpenCode config"* ]]
  [[ "${output}" == *"pre-existing config may be authoritative"* ]]
}

@test "variant validation passes through with a warning when XDG_CONFIG_HOME points outside the installed config directory" {
  # prepare-opencode-config.sh always installs into "\${HOME}/.config/opencode",
  # ignoring a caller-set XDG_CONFIG_HOME, so OpenCode's global config search
  # can diverge from where the bundled registry actually landed.
  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/custom-xdg" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "::warning::"* ]]
  [[ "${output}" == *"XDG_CONFIG_HOME"* ]]
}

@test "variant validation surfaces a missing bundled config file as an error, not a silent passthrough" {
  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${BATS_TEST_TMPDIR}/missing.jsonc"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"not found"* ]]
}

@test "variant validation surfaces an unparseable bundled config as an error, not a silent passthrough" {
  fixture="${BATS_TEST_TMPDIR}/broken.jsonc"
  printf '%s' 'not valid json at all' > "${fixture}"

  run env USE_BUNDLED_TOOLKIT=true REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant sakura/preview/Kimi-K2.7-Code thinking "$3"
    ' _ "${run_script}" "${lib_script}" "${fixture}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == "::error::"* ]]
  [[ "${output}" == *"Failed to read the bundled OpenCode model registry"* ]]
}

@test "variant validation escapes workflow command data in its annotations" {
  # Use the use-bundled-toolkit:false passthrough branch, since a model
  # absent from the registry now passes through silently and would leave
  # nothing to check escaping on.
  run env USE_BUNDLED_TOOLKIT=false REVIEW_ONLY=false GITHUB_WORKSPACE="${fake_workspace}" HOME="${fake_home}" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_validate_variant "$3" "$4" "$5"
    ' _ "${run_script}" "${lib_script}" \
    $'myprovider/my-model%\n::notice::injected' \
    $'high\r::debug::injected' \
    "${bundled_config}"
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == *"my-model%25%0A::notice::injected"* ]]
  [[ "${output}" == *"high%0D::debug::injected"* ]]
}

@test "bundled model registry declares an explicit variants object for every model" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_jsonc_to_json < "$2" | jq -e "[.provider[].models[] | has(\"variants\")] | all"
  ' _ "${lib_script}" "${bundled_config}"
  [ "${status}" -eq 0 ]
}

@test "run script rejects an unsupported variant before invoking OpenCode" {
  fake_bin="${BATS_TEST_TMPDIR}/variant-bin"
  invocation_file="${BATS_TEST_TMPDIR}/variant-invocation"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >"${INVOCATION_FILE}"' > "${fake_bin}/opencode"
  chmod +x "${fake_bin}/opencode"
  cat > "${fake_action}/.opencode/opencode.jsonc" << 'EOF'
{"provider": {"sakura": {"models": {"preview/Kimi-K2.7-Code": {"variants": {}}}}}}
EOF

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${fake_workspace}" \
    PROMPT="explicit prompt" \
    AGENT="build" \
    MENTIONS="/oc" \
    MODEL="sakura/preview/Kimi-K2.7-Code" \
    VARIANT="thinking" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="true" \
    TIMEOUT_MINUTES="5" \
    INVOCATION_FILE="${invocation_file}" \
    "${run_script}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not support variant 'thinking'"* ]]
  [ ! -e "${invocation_file}" ]
}

@test "run script passes an unsupported variant through with a warning when use-bundled-toolkit is false" {
  fake_bin="${BATS_TEST_TMPDIR}/variant-bin-2"
  invocation_file="${BATS_TEST_TMPDIR}/variant-invocation-2"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >"${INVOCATION_FILE}"' > "${fake_bin}/opencode"
  chmod +x "${fake_bin}/opencode"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${fake_workspace}" \
    PROMPT="explicit prompt" \
    AGENT="build" \
    MENTIONS="/oc" \
    MODEL="sakura/preview/Kimi-K2.7-Code" \
    VARIANT="thinking" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="false" \
    TIMEOUT_MINUTES="5" \
    INVOCATION_FILE="${invocation_file}" \
    "${run_script}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"::warning::"* ]]
  [[ "${output}" == *"use-bundled-toolkit is false"* ]]
  [ "$(cat "${invocation_file}")" = "github run" ]
}

@test "run configuration merges default_agent into existing JSONC" {
  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace" \
    PROMPT="explicit prompt" \
    AGENT="plan" \
    MENTIONS="/oc" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="true" \
    OPENCODE_CONFIG_CONTENT='{/* comment */"nested":{"items":[1,2,],},}' \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      jq -e '\''
        .default_agent == "plan" and
        .nested.items == [1, 2]
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}"

  [ "${status}" -eq 0 ]
}

@test "review-only run configuration discards inherited config overrides" {
  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    PROMPT="/review-pr" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="true" \
    USE_BUNDLED_TOOLKIT="true" \
    OPENCODE_CONFIG="untrusted.json" \
    OPENCODE_CONFIG_DIR="untrusted.d" \
    OPENCODE_CONFIG_CONTENT='{"plugin":["untrusted"]}' \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      [[ -z "${OPENCODE_CONFIG+x}" ]]
      [[ -z "${OPENCODE_CONFIG_DIR+x}" ]]
      [[ "$OPENCODE_DISABLE_PROJECT_CONFIG" == 1 ]]
      [[ "$OPENCODE_DISABLE_EXTERNAL_SKILLS" == 1 ]]
      [[ "$XDG_CONFIG_HOME" == "$HOME/.config" ]]
      jq -e '\''
        .default_agent == "build" and
        (has("plugin") | not)
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}"

  [ "${status}" -eq 0 ]
}

@test "review-only run configuration isolates bundled command resolution" {
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${workspace}/.opencode/commands"
  cat > "${workspace}/.opencode/commands/review-pr.md" << 'EOF'
---
description: untrusted project command
agent: plan
---

MALICIOUS PROJECT REVIEW: $ARGUMENTS
EOF

  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${repo_root}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/review-pr security" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="true" \
    USE_BUNDLED_TOOLKIT="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      [[ "$OPENCODE_RESOLVED_COMMAND_FILE" == "$2/.opencode/commands/review-pr.md" ]]
      [[ "$PROMPT" == *"Load and follow the "*" skill."* ]]
      [[ "$PROMPT" == *"pr-review"* ]]
      [[ "$PROMPT" == *"security"* ]]
      [[ "$PROMPT" != *"MALICIOUS PROJECT REVIEW"* ]]
      jq -e '\''
        .default_agent == "review-pr-orchestrator" and
        .default_agent != "plan"
      '\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}" "${repo_root}"

  [ "${status}" -eq 0 ]
}

@test "review-only runtime loads the bundled skill and excludes external skills" {
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${workspace}/.agents/skills/untrusted-review"
  cat > "${workspace}/.agents/skills/untrusted-review/SKILL.md" << 'EOF'
---
name: untrusted-review
description: untrusted project skill
---

# Untrusted review
EOF

  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${repo_root}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/review-pr security" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="true" \
    USE_BUNDLED_TOOLKIT="true" \
    bash -euo pipefail -c '
      source "$1"
      source "$2"
      opencode_prepare_config "$3" true
      opencode_configure_run
      cd "$GITHUB_WORKSPACE"
      opencode debug skill >/dev/null
      skills="$(opencode debug skill)"
      jq -e \
        --arg location "$HOME/.config/opencode/skills/pr-review/SKILL.md" \
        '\''
          any(
            .[];
            .name == "pr-review"
            and .location == $location
            and (.content | contains("# Strictly Read-Only PR Review"))
          )
          and all(.[]; .name != "untrusted-review")
        '\'' <<<"$skills"
    ' _ "${run_script}" "${repo_root}/scripts/prepare-opencode-config.sh" "${repo_root}"

  [ "${status}" -eq 0 ]
}

@test "normal run configuration falls back to the bundled toolkit's commands" {
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${workspace}" "${fake_action}/.opencode/commands"
  cat > "${fake_action}/.opencode/commands/inspect.md" << 'EOF'
---
description: bundled inspect command
agent: plan
---

Bundled inspect: $ARGUMENTS
EOF

  run env \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/inspect security" \
    AGENT="build" \
    MENTIONS="/oc" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_configure_run
      [[ "$OPENCODE_RESOLVED_COMMAND_FILE" == "$2/.opencode/commands/inspect.md" ]]
      [[ "$PROMPT" == *"Bundled inspect: security"* ]]
      jq -e '\''.default_agent == "plan"'\'' <<<"$OPENCODE_CONFIG_CONTENT"
    ' _ "${run_script}" "${fake_action}"

  [ "${status}" -eq 0 ]
}

@test "OpenCode failure classification uses the terminal provider error" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'AI_APICallError: rate limit exceeded (statusCode: 429)' \
    'UnknownError: "Request timed out"' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"provider request timed out"* ]]
  [[ "${output}" != *"rate limited"* ]]

  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 124 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"timed out after 10 minutes"* ]]

  printf '%s\n' 'Error: SSE read timed out' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"provider request timed out"* ]]

  printf '%s\n' 'TimeoutError: The operation timed out' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"provider request timed out"* ]]

  printf '%s\n' 'AI_APICallError: statusCode: 429' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"rate limited"* ]]

  printf '%s\n' 'AI_APICallError: Insufficient credits (statusCode: 402)' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"billing or quota"* ]]

  printf '%s\n' 'AI_APICallError: provider unavailable' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"model provider API error"* ]]

  printf '%s\n' unrelated > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
}

@test "OpenCode failure classification surfaces a JSON parse failure alone" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' 'Failed to parse JSON' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"provider/model"* ]]
  [[ "${output}" == *"opencode 1.18.10"* ]]
  [[ "${output}" != *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification preserves a JSON parse failure followed by comment creation" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification ignores ordinary JSON.parse output" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'const value = JSON.parse(raw)' \
    'Error: unrelated failure' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
}

@test "OpenCode failure classification recognizes a SyntaxError JSON signature" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'SyntaxError: Unexpected token } in JSON at position 123' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification ignores nonterminal JSON error text" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'SyntaxError: Unexpected token } in JSON at position 123' \
    'Error: unrelated failure' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
}

@test "OpenCode failure classification surfaces a JSON parse failure masked by the .rest handler crash" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' \
    "Error: Unexpected error: undefined is not an object (evaluating 'p.rest')" > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"secondary failure"* ]]
  [[ "${output}" == *".rest"* ]]
  [[ "${output}" == *"provider/model"* ]]
  [[ "${output}" == *"opencode 1.18.10"* ]]
  [[ "${output}" == *"do not assume OIDC or credentials are at fault"* ]]
  [[ "${output}" != *"caused by OIDC"* ]]
}

@test "OpenCode failure classification recognizes the ANSI-decorated four-line failure sequence" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' \
    $'\033[31mError:\033[0m \033[1mUnexpected error\033[0m' \
    '' \
    "undefined is not an object (evaluating 'p.rest')" > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification ignores trailing ANSI-only lines" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'Creating comment...' \
    $'\033[31mError:\033[0m \033[1mUnexpected error\033[0m' \
    "undefined is not an object (evaluating 'p.rest')" \
    $'\033[0m' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" == *"secondary failure"* ]]
  [[ "${output}" != *"failed with exit code"* ]]
}

@test "OpenCode failure classification requires the .rest failure after the JSON error" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    "Error: Unexpected error: undefined is not an object (evaluating 'p.rest')" \
    'Failed to parse JSON' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"secondary failure"* ]]
}

@test "OpenCode failure classification ignores a nonterminal JSON and .rest sequence" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    "Error: Unexpected error: undefined is not an object (evaluating 'p.rest')" \
    'Error: unrelated failure' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failed with exit code 17"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
  [[ "${output}" != *"secondary failure"* ]]
}

@test "OpenCode failure classification still prefers evidenced provider errors over JSON parse noise" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' \
    'Failed to parse JSON' \
    'AI_APICallError: rate limit exceeded (statusCode: 429)' > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 1 "$2" 10 provider/model 1.18.10
  ' _ "${run_script}" "${output_file}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"rate limited"* ]]
  [[ "${output}" != *"failed to parse a JSON response"* ]]
}

@test "OpenCode failure annotations escape workflow command message data" {
  output_file="${BATS_TEST_TMPDIR}/output"

  printf '%s\n' unrelated > "${output_file}"
  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 17 "$2" "$3" "$4" "$5"
  ' _ "${run_script}" "${output_file}" \
    $'10\n::notice::injected' \
    $'provider/model%\n::warning::injected' \
    $'1.18.10\r::debug::injected'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == *"provider/model%25%0A::warning::injected"* ]]
  [[ "${output}" == *"opencode 1.18.10%0D::debug::injected"* ]]

  run bash -euo pipefail -c '
    source "$1"
    opencode_report_failure 124 "$2" "$3" provider/model 1.18.10
  ' _ "${run_script}" "${output_file}" $'10\n::notice::injected'
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == *"after 10%0A::notice::injected minutes"* ]]
}

@test "run script preserves mocked OpenCode status and classifies its output" {
  fake_bin="${BATS_TEST_TMPDIR}/run-bin"
  invocation_file="${BATS_TEST_TMPDIR}/invocation"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'shift' \
    'exec "$@"' > "${fake_bin}/timeout"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >"${INVOCATION_FILE}"' \
    'echo "Insufficient credits"' \
    'exit 23' > "${fake_bin}/opencode"
  chmod +x "${fake_bin}/timeout" "${fake_bin}/opencode"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace" \
    PROMPT="explicit prompt" \
    AGENT="build" \
    MENTIONS="/oc" \
    MODEL="provider/model" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="false" \
    TIMEOUT_MINUTES="5" \
    INVOCATION_FILE="${invocation_file}" \
    "${run_script}"

  if [[ "${status}" -ne 23 ]]; then
    printf 'unexpected status %s: %s\n' "${status}" "${output}" >&2
  fi
  [ "${status}" -eq 23 ]
  [[ "${output}" == *"billing or quota"* ]]
  [ "$(cat "${invocation_file}")" = "github run" ]
}

@test "run script expands a command and invokes mocked OpenCode successfully" {
  fake_bin="${BATS_TEST_TMPDIR}/success-bin"
  workspace="${BATS_TEST_TMPDIR}/success-workspace"
  invocation_file="${BATS_TEST_TMPDIR}/success-invocation"
  prompt_file="${BATS_TEST_TMPDIR}/success-prompt"
  config_file="${BATS_TEST_TMPDIR}/success-config"
  mkdir -p "${fake_bin}" "${workspace}/.opencode/commands"
  cat > "${workspace}/.opencode/commands/inspect.md" << 'EOF'
---
description: inspect with the plan agent
agent: plan
---

Inspect securely: $ARGUMENTS
EOF
  cat > "${fake_bin}/timeout" << 'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  cat > "${fake_bin}/opencode" << 'EOF'
#!/usr/bin/env bash
printf 'opencode %s\n' "$*" >"${INVOCATION_FILE}"
printf '%s' "${PROMPT}" >"${PROMPT_FILE}"
printf '%s' "${OPENCODE_CONFIG_CONTENT}" >"${CONFIG_FILE}"
EOF
  chmod +x "${fake_bin}/timeout" "${fake_bin}/opencode"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${workspace}" \
    PROMPT="/inspect security" \
    AGENT="build" \
    MENTIONS="/oc" \
    MODEL="provider/model" \
    REVIEW_ONLY="false" \
    USE_BUNDLED_TOOLKIT="false" \
    TIMEOUT_MINUTES="5" \
    INVOCATION_FILE="${invocation_file}" \
    PROMPT_FILE="${prompt_file}" \
    CONFIG_FILE="${config_file}" \
    "${run_script}"

  [ "${status}" -eq 0 ]
  [ "$(cat "${invocation_file}")" = "opencode github run" ]
  [[ "$(cat "${prompt_file}")" == *"Inspect securely: security"* ]]
  jq -e '.default_agent == "plan"' "${config_file}"
}
