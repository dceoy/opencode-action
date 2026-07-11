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

# Fail closed unless $1 is a canonical x.y.z release version at or above
# OPENCODE_REVIEW_MIN_VERSION. Anything unparseable (empty, "latest" left
# unresolved, branch names, pre-release suffixes) is rejected because
# OPENCODE_DISABLE_PROJECT_CONFIG support cannot be proven for it.
opencode_review_enforce_version_floor() {
  local version="${1:-}"
  local version_major version_minor version_patch
  local minimum_major minimum_minor minimum_patch

  if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "::error::Review-only mode requires a plain x.y.z OpenCode release version to prove OPENCODE_DISABLE_PROJECT_CONFIG support; got '${version}'." >&2
    return 1
  fi

  IFS=. read -r version_major version_minor version_patch <<<"${version}"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<<"${OPENCODE_REVIEW_MIN_VERSION}"
  if ((
    version_major < minimum_major ||
      (version_major == minimum_major && version_minor < minimum_minor) ||
      (version_major == minimum_major && version_minor == minimum_minor && version_patch < minimum_patch)
  )); then
    echo "::error::Review-only mode requires OpenCode >= ${OPENCODE_REVIEW_MIN_VERSION}, the first release that supports OPENCODE_DISABLE_PROJECT_CONFIG; resolved version ${version} would load the reviewed project's OpenCode config." >&2
    return 1
  fi
}

# Unset every caller-controlled source that can redirect or override OpenCode
# configuration even when OPENCODE_DISABLE_PROJECT_CONFIG is set. This keeps
# review-only runs on the freshly installed toolkit under $HOME/.config and
# prevents direct permission overrides. XDG_DATA_HOME is also stripped here so
# the well-known XDG data path does not leak through; it is then re-exported
# by opencode_review_isolate_data_dir to a fresh empty directory below.
opencode_review_strip_config_env() {
  local var
  for var in \
    OPENCODE_CONFIG \
    OPENCODE_CONFIG_DIR \
    OPENCODE_CONFIG_CONTENT \
    OPENCODE_PERMISSION \
    OPENCODE_TEST_HOME \
    XDG_CONFIG_HOME \
    XDG_DATA_HOME; do
    if [[ -n "${!var:-}" ]]; then
      echo "::warning::Ignoring caller-provided ${var} in review-only mode." >&2
    fi
    unset "${var}"
  done
}

# Create a fresh, empty XDG data directory and export XDG_DATA_HOME pointing
# at it. Merely unsetting XDG_DATA_HOME is not enough: OpenCode v1.1.29
# derives Global.Path.data from XDG data paths and Auth.all() reads
# ${Global.Path.data}/auth.json, where every wellknown entry is fetched and
# merged as remote config (including plugin arrays) before the bundled
# global config. With XDG_DATA_HOME unset, OpenCode falls back to the
# persistent $HOME/.local/share tree, so a caller who can influence that
# location (or any inherited XDG_DATA_HOME) would still load arbitrary
# plugin code. Pointing XDG_DATA_HOME at a fresh empty mktemp -d directory
# breaks that path and prevents any auth.json or remote config from being
# loaded for review-only runs. The directory is left in place for the run
# and is not removed by the guard; the caller's normal tmp cleanup is
# responsible for it.
opencode_review_isolate_data_dir() {
  local data_dir
  if ! data_dir="$(mktemp -d -t opencode-review-data.XXXXXX 2>/dev/null)"; then
    echo "::error::Review-only mode could not create an isolated OpenCode data directory." >&2
    return 1
  fi
  chmod 700 "${data_dir}"
  export XDG_DATA_HOME="${data_dir}"
}
