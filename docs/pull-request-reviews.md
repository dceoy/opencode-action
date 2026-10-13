# Pull request reviews

The `opencode-review.yml` reusable workflow installs the external [`pr-review` skill](https://github.com/dceoy/pr-loop/tree/main/skills/pr-review) from `dceoy/pr-loop`. The bundled `/review-pr` slash command, dedicated agents, scripts, and local skill were removed.

## Invocation

The review workflow uses `review-only: true`, passing the pull request URL and exact head SHA from the event. The action installs the upstream skill under `~/.config/opencode/skills/pr-review/` at an immutable `pr-review-ref` commit and invokes it using a plain-text prompt. Override `prompt` with review focus such as `security and performance`; the old `/review-pr` command is not supported.

For direct action usage, set `review-only: 'true'`, keep `use-bundled-toolkit: 'true'`, and supply `PR_REVIEW_URL` and `PR_REVIEW_HEAD_SHA` via the environment, or rely on the GitHub event context. Review requires a model API key and `pull-requests: write`; the default OpenCode App token flow additionally needs `id-token: write`.

```yaml
jobs:
  review:
    permissions:
      contents: read
      pull-requests: write
      id-token: write
      actions: read
    uses: dceoy/opencode-action/.github/workflows/opencode-review.yml@main
    with:
      model: sakura/preview/Kimi-K2.7-Code
      prompt: Focus on security and regression risks.
    secrets:
      SAKURA_AI_ENGINE_API_KEY: ${{ secrets.SAKURA_AI_ENGINE_API_KEY }}
```

## GitHub App token reuse

The token resolver (`.opencode/scripts/resolve-app-token.sh`) is preserved independently of the removed review command. The trusted `pr-review-gh.sh` adapter is installed alongside it under `~/.config/opencode/scripts/`. The review prompt instructs the external `pr-review` skill to route `gh api` and read-only `gh pr` operations through this adapter. It must run **inside** `opencode github run`: the OpenCode OIDC exchange and Git credential configuration are established at that point, not during action setup.

The adapter extracts token candidates from Git `http.*.extraheader`, verifies that writes are attributed to `opencode-agent[bot]` with a temporary unsubmitted pending-review create/delete probe, then exports the verified credential to its child `gh` process as `GH_TOKEN` and `GITHUB_TOKEN`. The token is not written to a file or emitted as output. Unverified credentials are never accepted as GitHub App tokens.

- **Default (`use-github-token: false`)**: only a verified OpenCode App token is accepted; unavailable or mismatched identity fails closed.
- **Explicit fallback (`use-github-token: true`)**: prefer a verified OpenCode App token; otherwise use the caller's existing workflow token and its author identity.

The adapter verifies identity on each invocation rather than persisting a short-lived token between processes. The pending-review probe performs real GitHub API create/delete operations, although it never publishes a review. The skill prompt and adapter **do not constitute a process-level sandbox**: a coding agent with other GitHub tools or shell permissions could bypass the adapter. Use trusted runners and grant `pull-requests: write`.
## Review contract and boundaries

Upstream `pr-review` freezes the base/head snapshot, validates findings against repository evidence, and publishes one verified `COMMENT` review by default. It never approves, requests changes, merges, or modifies repository contents. See [the upstream skill specification](https://github.com/dceoy/pr-loop/blob/main/skills/pr-review/SKILL.md) for the authoritative policy.

Review-only runs replace inherited global OpenCode configuration, disable project configuration and external skill discovery, and use a fresh OpenCode installation. They **do not enforce the previous command's fine-grained shell/edit permission boundary**. The coding agent retains its configured tool permissions and is instructed to follow the skill's review-only contract; use trusted runners.

The upstream skill is pinned by default to `ddd538f6e9347b13cf6aaebfbda86ba704ee8415`. Set `pr-review-ref` to another complete immutable commit SHA to update it. If installation, pinned commit verification, or required upstream files fail, the workflow fails rather than falling back to the removed bundled implementation. OpenCode GitHub integration can separately add a completion comment.
