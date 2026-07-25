# Security model

`opencode-action` runs an AI agent against an untrusted repository checkout. Review-only mode separates repository analysis from the trusted operations required to read pull request metadata and submit a review.

## Trust boundaries

The action treats repository files, project OpenCode configuration, pull request content, and unverified git credentials as untrusted.

Trusted agents, commands, configuration, and helper scripts are installed from the action bundle under `~/.config/opencode/` before the repository is analyzed.

## Review-only isolation

When the effective prompt starts with `/review-pr`, the action:

1. requires OpenCode 1.2.14 or newer and `enable-toolkit: true`
2. installs a fresh bundled OpenCode configuration
3. disables project-provided OpenCode configuration
4. removes inherited plugins, agents, and configuration
5. resolves the review command only from the action bundle

External-directory access is denied by default. Only the three trusted review helpers and their dedicated state directory under `~/.config/opencode/` are allowed. This prevents repository-controlled files from replacing trusted scripts and avoids unattended permission prompts.

## Trusted pull request context

The helpers derive the repository and pull request number from the GitHub Actions event and pin the pull request head SHA before analysis.

The submission helper accepts only the fixed review operations and validates the event context, pinned commit, payload shape, and target endpoint. If the pull request head changes after the diff is captured, the run fails before submitting stale findings.

## Token verification and precedence

The default OIDC flow supplies an OpenCode GitHub App installation token. Credentials discovered through git configuration are candidates only; their encoding does not prove which App or identity issued them.

Before a structured review write, the action verifies candidates by creating an empty pending review, checking that its author is `opencode-agent[bot]`, and immediately deleting it. The probe is not published, but it is a real create-and-delete API operation. Tokens and decoded authorization headers are never printed.

Structured writes use this precedence:

1. the first candidate verified as `opencode-agent[bot]`
2. the caller's existing `GH_TOKEN` or `GITHUB_TOKEN` only when `use-github-token: true`
3. otherwise, fail without submitting a review

The explicit workflow-token fallback may make reviews appear under `github-actions[bot]` or another identity associated with that token. Unverified candidates may be used for read-only metadata access but never pass the structured-write gate.

## Fail-closed behavior

Review-only mode fails rather than weakening its guarantees when:

- the bundled toolkit is disabled or the OpenCode version is unsupported
- trusted pull request context cannot be established
- the pull request head changes
- no App token verifies and workflow-token fallback was not explicitly enabled
- review payload validation or structured submission fails

See [Pull request reviews](pull-request-reviews.md) for reviewer selection and submission behavior.
