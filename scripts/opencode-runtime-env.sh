#!/usr/bin/env bash
# Run v2 without GitHub credentials, including for installer/version probes.
opencode_runtime_exec() (
  if [[ "${OPENCODE_RUNTIME:-v1}" == "v2" ]]; then
    unset OPENCODE_APP_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN OIDC_BASE_URL \
      GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN PR_REVIEW_INSTALL_TOKEN \
      OPENCODE_REVIEW_PARENT_AUTH OPENCODE_REVIEW_BROKER_URL || return 1
  fi
  exec "$@"
)
