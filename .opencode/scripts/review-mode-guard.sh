#!/usr/bin/env bash
# Review-only mode guards for action.yml. Intended to be sourced (not
# executed) from the composite action's steps so that stripping
# caller-controlled OpenCode config environment variables applies to the
# step shell that later invokes `opencode github run`.

# First upstream release whose `opencode` honors
# OPENCODE_DISABLE_PROJECT_CONFIG: anomalyco/opencode commit
# a18ae2c8b7b29f89aa4bbe56d14b786f41c9f4f5 ("feat: add
# OPENCODE_DISABLE_PROJECT_CONFIG env var", #8093) first shipped in
# v1.1.29. Older versions silently ignore the variable and would load the
# reviewed project's .opencode/ config, so review-only mode must refuse to
# run them.
OPENCODE_REVIEW_MIN_VERSION="1.1.29"

# Fail closed unless $1 is a plain x.y.z release version at or above
# OPENCODE_REVIEW_MIN_VERSION. Anything unparseable (empty, "latest" left
# unresolved, branch names, pre-release suffixes) is rejected because
# OPENCODE_DISABLE_PROJECT_CONFIG support cannot be proven for it.
opencode_review_enforce_version_floor() {
  local version="${1:-}"
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error::Review-only mode requires a plain x.y.z OpenCode release version to prove OPENCODE_DISABLE_PROJECT_CONFIG support; got '${version}'." >&2
    return 1
  fi
  if [[ "$(printf '%s\n' "${OPENCODE_REVIEW_MIN_VERSION}" "${version}" | sort -V | head -n1)" != "${OPENCODE_REVIEW_MIN_VERSION}" ]]; then
    echo "::error::Review-only mode requires OpenCode >= ${OPENCODE_REVIEW_MIN_VERSION}, the first release that supports OPENCODE_DISABLE_PROJECT_CONFIG; resolved version ${version} would load the reviewed project's OpenCode config." >&2
    return 1
  fi
}

# Unset the caller-controlled OpenCode config sources that upstream still
# honors even when OPENCODE_DISABLE_PROJECT_CONFIG is set, so a workflow
# (or a step that ran before this action) cannot inject configuration into
# a review-only run.
opencode_review_strip_config_env() {
  local var
  for var in OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT; do
    if [[ -n "${!var:-}" ]]; then
      echo "::warning::Ignoring caller-provided ${var} in review-only mode." >&2
    fi
    unset "${var}"
  done
}
