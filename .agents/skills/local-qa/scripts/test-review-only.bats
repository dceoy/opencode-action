#!/usr/bin/env bats

setup() {
  repo="${BATS_TEST_TMPDIR}/repo"; remote="${BATS_TEST_TMPDIR}/remote.git"
  git init --bare "$remote" >/dev/null; git init "$repo" >/dev/null
  git -C "$repo" config user.email test@example.com; git -C "$repo" config user.name test
  printf 'base\n' >"$repo/base"; git -C "$repo" add base; git -C "$repo" commit -m base >/dev/null
  git -C "$repo" remote add origin "$remote"; git -C "$repo" push -u origin HEAD >/dev/null
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../../../../.opencode/scripts/review-only.sh"
}

@test "untracked review output fails without changing the remote" {
  before="$(git -C "$repo" rev-parse HEAD)"; snapshot="$(cd "$repo" && opencode_review_only_snapshot)"; touch "$repo/generated"
  run bash -c "source '$BATS_TEST_DIRNAME/../../../../.opencode/scripts/review-only.sh'; cd '$repo' && opencode_review_only_check_invariant '$snapshot'"
  [ "$status" -ne 0 ]; [ "$(git -C "$remote" rev-parse HEAD)" = "$before" ]
}

@test "git guard blocks attempted commits and pushes" {
  guard="${BATS_TEST_TMPDIR}/guard"; opencode_review_only_make_git_guard "$guard"; printf 'changed\n' >>"$repo/base"
  run env PATH="$guard:$PATH" git -C "$repo" commit -am blocked; [ "$status" -ne 0 ]
  run env PATH="$guard:$PATH" git -C "$repo" push; [ "$status" -ne 0 ]
  run env PATH="$guard:$PATH" git -c user.name=blocked -C "$repo" commit -am blocked; [ "$status" -ne 0 ]
}

@test "only literal boolean inputs are accepted" {
  run opencode_normalize_boolean yes review-only; [ "$status" -ne 0 ]
  [ "$(opencode_normalize_boolean true review-only)" = true ]
}

@test "contents-write token configuration is rejected" {
  bin="${BATS_TEST_TMPDIR}/bin"; mkdir "$bin"
  printf '#!/usr/bin/env bash\nprintf %%s "{\"push\":true}"\n' >"$bin/gh"; chmod +x "$bin/gh"
  GITHUB_REPOSITORY=owner/repo run env PATH="$bin:$PATH" bash -c "source '$BATS_TEST_DIRNAME/../../../../.opencode/scripts/review-only.sh'; opencode_review_only_assert_token"
  [ "$status" -ne 0 ]
}
