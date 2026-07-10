#!/usr/bin/env bash
# Sourceable helpers used by action.yml to detect repository mutations during
# the bundled /review-pr command. This is defense in depth, not a sandbox.

opencode_review_state_snapshot() {
  git rev-parse HEAD
  git status --porcelain=v1 --untracked-files=all
}

opencode_review_state_changed() {
  local before="${1:-}" after
  after="$(opencode_review_state_snapshot)"
  [[ "${after}" != "${before}" ]]
}
