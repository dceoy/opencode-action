# Security model

`opencode-action` runs an AI agent against an untrusted repository checkout. Its review-only mode separates repository analysis from the small set of trusted operations required to read pull request metadata and submit a GitHub review.

## Trust boundaries

The action treats these inputs as untrusted:

- repository files and project-level OpenCode configuration
- pull request titles, descriptions, comments, and diffs
- git credential entries until their identity is verified

Trusted code is installed from the action bundle into `~/.config/opencode/` before OpenCode analyzes the repository.

## Review-only isolation

When the effective prompt starts with `/review-pr`, the action:

1. requires `enable-toolkit: true`
2. requires OpenCode 1.2.14 or newer
3. installs a fresh copy of the bundled OpenCode configuration
4. sets `OPENCODE_DISABLE_PROJECT_CONFIG=1`
5. removes inherited OpenCode plugins, agents, and configuration that could affect the run
6. resolves the command only from the action's bundled command directory

The bundled configuration denies `external_directory` access by default. It allows only:

- `~/.config/opencode/scripts/resolve-app-token.sh`
- `~/.config/opencode/scripts/review-pr-gh.sh`
- `~/.config/opencode/scripts/review-pr-submit.sh`
- files under `~/.config/opencode/review-state/`

This prevents an unattended GitHub Actions run from blocking on an unanswerable permission prompt and prevents repository-controlled files from replacing trusted helper scripts.

## Trusted review context

The helpers derive the repository and pull request number from the GitHub Actions event and pin the pull request head SHA before analysis.

The orchestrator does not pass arbitrary repositories, pull request numbers, commits, review IDs, HTTP methods, or API endpoints to the submission helper. The helper validates the event context, pinned commit, payload shape, and exact pull request review endpoint.

If the pull request head changes after the diff is captured, the run fails before submitting stale findings.

## GitHub App token discovery

The default flow exchanges the workflow's OIDC token for an OpenCode GitHub App installation token. For direct review API writes, `/review-pr` resolves candidate tokens from git credential configuration in this order:

1. the local `http.https://github.com/.extraheader` value
2. `git config --get-urlmatch` for `https://github.com/`
3. matching `http.*.extraheader` values from merged git configuration
4. values discovered through `git config --show-origin --get-regexp`

Only entries whose host is exactly `github.com` are considered. Duplicate token values are removed while preserving discovery order.

A candidate's encoding is not proof of identity. A GitHub App token, a checkout-persisted `GITHUB_TOKEN`, and a PAT can all use the same `x-access-token:<token>` Basic authentication form.

## Identity verification

Before each structured review write, every candidate is tried in order until one verifies as `opencode-agent[bot]`.

GitHub does not provide a read-only identity endpoint for installation tokens: `GET /user` requires user-to-server authentication and returns 403 for installation tokens. The action therefore:

1. creates an empty pending pull request review with the candidate token
2. checks the response's `user.login`
3. immediately deletes the pending review
4. accepts the token only when the login is `opencode-agent[bot]`

A pending review is not published to other pull request participants, but the probe is still a real create-and-delete API operation.

Tokens and decoded authorization headers are never printed.

## Credential precedence

Every structured review write applies the following policy:

1. The first candidate that verifies as `opencode-agent[bot]` is used, even when `use-github-token: true`.
2. If no candidate verifies and `use-github-token: true`, the action preserves and uses the caller's original `GH_TOKEN` or `GITHUB_TOKEN`.
3. If no candidate verifies and `use-github-token` is not `true`, the run fails without submitting a review.

The explicit fallback may make the review appear as `github-actions[bot]` or another identity associated with the supplied token.

For read-only commands such as retrieving pull request metadata or a diff, the action may use the highest-priority unverified candidate when `use-github-token` is false. Unverified candidates are never accepted by the structured-write gate.

## Fail-closed behavior

Review-only mode fails instead of silently weakening its guarantees when:

- the bundled toolkit is disabled
- the OpenCode version is unsupported
- trusted pull request context cannot be established
- the pull request head changes
- no App token verifies and workflow-token fallback was not explicitly enabled
- review payload validation or structured submission fails

See [Pull request reviews](pull-request-reviews.md) for reviewer selection and submission behavior.
