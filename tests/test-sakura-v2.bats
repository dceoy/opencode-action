#!/usr/bin/env bats
# shellcheck disable=SC2016

@test "v2 loads the bundled Sakura catalog through isolated review configuration" {
  root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  cli="${OPENCODE_V2_BIN:-${root}/node_modules/@opencode/cli/bin/opencode.exe}"
  [ -x "${cli}" ]
  home="${BATS_TEST_TMPDIR}/home"
  workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${home}" "${workspace}"
  run env HOME="${home}" XDG_DATA_HOME="${home}/.local/share" XDG_CACHE_HOME="${home}/.cache" \
    ACTION_PATH="${root}" REVIEW_ONLY=true OPENCODE_RUNTIME=v2 USE_BUNDLED_TOOLKIT=true \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    USE_GITHUB_TOKEN=true GITHUB_WORKSPACE="${workspace}" MODEL=sakura/preview/example VARIANT= AGENT=build PROMPT=/pr-review GITHUB_EVENT_NAME=pull_request \
    PR_REVIEW_URL=https://github.com/example/repo/pull/1 PR_REVIEW_HEAD_SHA=0123456789012345678901234567890123456789 \
    SAKURA_AI_ENGINE_API_KEY=credential_sentinel CLI="${cli}" ROOT="${root}" bash -euo pipefail -c '
      source "$ROOT/scripts/prepare-opencode-config.sh"
      opencode_prepare_config "$ROOT" true v2
      mkdir -p "$HOME/.config/opencode/skills/pr-review"
      touch "$HOME/.config/opencode/skills/pr-review/SKILL.md"
      source "$ROOT/scripts/run-opencode.sh"
      opencode_configure_run
      cd "$GITHUB_WORKSPACE"
      "$CLI" debug config --standalone > "$HOME/debug.json" 2> "$HOME/debug.err"
      "$CLI" models --standalone > "$HOME/models" 2> "$HOME/models.err"
      ! grep -q credential_sentinel "$HOME/debug.json" "$HOME/debug.err" "$HOME/models" "$HOME/models.err"
      test ! -s "$HOME/debug.err"
      test ! -s "$HOME/models.err"
      source "$ROOT/scripts/opencode-action-lib.sh"
      opencode_jsonc_to_json < "$ROOT/.opencode/opencode.jsonc" > "$HOME/catalog.json"
      jq -e --slurpfile original "$HOME/catalog.json" '\''
        (map(select(.info.providers.sakura))[0].info.providers.sakura) as $p |
        ([.[] | select(.info.providers.sakura)] | length) == 1 and
        ([.[] | select(.info.default_agent == "action-pr-review")] | length) == 1 and
        $p.package == "aisdk:@ai-sdk/openai-compatible" and
        $p.settings.baseURL == $original[0].provider.sakura.options.baseURL and
        $p.settings.timeout == $original[0].provider.sakura.options.timeout and
        $p.settings.chunkTimeout == $original[0].provider.sakura.options.chunkTimeout and
        $p.settings.apiKey == "***" and
        ($p.models | keys) == ($original[0].provider.sakura.models | keys) and
        ([$p.models[].variants == []] | all)
      '\'' "$HOME/debug.json" >/dev/null
      jq -r '\''.provider.sakura.models | keys[] | "sakura/" + .'\'' "$HOME/catalog.json" | LC_ALL=C sort > "$HOME/expected"
      grep "^sakura/" "$HOME/models" | LC_ALL=C sort > "$HOME/actual"
      diff -u "$HOME/expected" "$HOME/actual"
    '
  [ "${status}" -eq 0 ]
}
