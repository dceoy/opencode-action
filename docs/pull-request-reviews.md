# Pull request reviews

The `opencode-review.yml` reusable workflow installs the external [`pr-review` skill](https://github.com/dceoy/pr-loop/tree/main/skills/pr-review) from `dceoy/pr-loop`. The bundled `/review-pr` slash command, dedicated agents, scripts, and local skill were removed.

## Invocation

The review workflow uses `review-only: true`, passing the pull request URL and exact head SHA from the event. The action installs the upstream skill under `~/.config/opencode/skills/pr-review/` at the immutable `pr-review-ref` commit and invokes it using a plain-text prompt. The installed skill enables native TUI `/pr-review` through `metadata.opencode/slash: "true"`; no separate command file is generated. GitHub runs explicitly instruct the model to load the skill with the native `skill` tool. The default `prompt` is `/pr-review`, which is normalized to review focus before that instruction is constructed. Override it with `/pr-review security and performance` or plain-text review focus; the old `/review-pr` command is not supported.

For direct action usage, set `review-only: 'true'`, keep `use-bundled-toolkit: 'true'`, and supply `PR_REVIEW_URL` and `PR_REVIEW_HEAD_SHA` via the environment, or rely on a `pull_request` event. Comment events require both explicit variables. For manual `opencode-bot.yml` runs, provide `pr-review-url` and `pr-review-head-sha`; unresolved targets fail before OpenCode starts. Review requires a model API key and `pull-requests: write`; the default OpenCode App token flow additionally needs `id-token: write`.

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

The token resolver (`.opencode/scripts/resolve-app-token.sh`) is preserved independently of the removed review command. The trusted `pr-review-gh.sh` adapter is installed alongside it under `~/.config/opencode/scripts/`. The review prompt instructs the external `pr-review` skill to route GitHub operations through the trusted native API tool and adapter. Review-only runs use the action-defined `action-pr-review` primary agent regardless of the caller's `agent` input. It must run **inside** `opencode github run`: the OpenCode OIDC exchange and Git credential configuration are established at that point, not during action setup.

The adapter extracts token candidates from Git `http.*.extraheader`, verifies that writes are attributed to `opencode-agent[bot]` with a temporary unsubmitted pending-review create/delete probe, then exports the verified credential to its child `gh` process as `GH_TOKEN` and `GITHUB_TOKEN`. The token is not written to a file or emitted as output. Unverified credentials are never accepted as GitHub App tokens.

- **Default (`use-github-token: false`)**: only a verified OpenCode App token is accepted; unavailable or mismatched identity fails closed.
- **Explicit fallback (`use-github-token: true`)**: prefer a verified OpenCode App token; otherwise use the caller's existing workflow token and its author identity.

For review-only runs, call the native `pr-review-api` tool with a `request` argument containing a JSON string such as `{ "endpoint": "repos/OWNER/REPO/pulls/NUMBER/reviews", "method": "GET", "paginate": true, "page": 1, "offset": 0, "limit": 4096 }`. The trusted tool invokes the adapter through fixed process arguments and stdin; the agent has no shell or file-modification tools. For publication, use `method: "POST"` with an embedded `payload` containing the commit-bound COMMENT review. Unknown fields, duplicate keys, invalid bounds and invalid payloads fail closed. No shell expressions, input paths or CLI flags are accepted.

GET responses contain `offset`, `next_offset`, `page`, `next_page`, `total_chars` and `content`. With `paginate: true`, each request fetches **one** GitHub API page (up to 10 entries); `page` defaults to 1. Reissue the same page at `next_offset` and concatenate `content` until `next_offset` is null. If `next_page` is nonnull, continue with that API page starting at `offset: 0`. A short API page terminates pagination; an exactly full page may require one final empty-page request. This avoids downloading all preceding GitHub API pages for each response slice. Use `paginate: false` for singleton or immutable endpoints. `offset`/`limit` bound each tool response to at most 4096 characters. Immutable `git/trees/<SHA>` and `git/blobs/<SHA>` endpoints provide frozen file evidence; blobs are decoded as UTF-8, while truncated trees and non-text blobs fail. Mutable API responses can change between slices, so revalidate their snapshot before and after reconstruction. POST accepts no output-paging fields and returns a bounded review receipt; verify the complete persisted review through GET.

The adapter retains a direct CLI interface for trusted callers. It permits scoped API reads and only `gh api repos/<repo>/pulls/<PR>/reviews --method POST --input <JSON-file-or-dash>` publication with `event: COMMENT`, a nonempty body, and the exact reviewed `commit_id`. Use `--input` JSON for publication; field flags, custom hosts, unknown options, other mutation methods, and other targets are rejected before token resolution. Read-only `gh pr view`, `diff`, and `checks` require the explicit target URL.

Automatic formatters and language servers are disabled in review-only runs.

The adapter verifies identity on each invocation rather than persisting a short-lived token between processes. The pending-review probe performs real GitHub API create/delete operations, although it never publishes a review. The review agent denies tools by default and allows only the upstream skill, trusted reference reads and globbing, and the native API tool. It denies direct GitHub/network tools, general shell commands, grep, delegation, repository edits and all checkout file reads. Repository content is read through frozen Git blobs instead, so checkout symlinks cannot redirect file reads to runner credentials. These are OpenCode tool permissions, **not an operating-system sandbox**; use trusted runners and grant `pull-requests: write`.

## Review contract and boundaries

Upstream `pr-review` freezes the base/head snapshot, validates findings against repository evidence, and publishes one verified `COMMENT` review by default. It never approves, requests changes, merges, or modifies repository contents. See [the upstream skill specification](https://github.com/dceoy/pr-loop/blob/main/skills/pr-review/SKILL.md) for the authoritative policy.

Review-only runs replace inherited global OpenCode configuration, disable project configuration and external skill discovery, and use a fresh OpenCode installation. They force the restricted review agent and its tool permissions instead of inheriting the caller's agent permissions. Review behavior remains in the pinned upstream skill; no bundled command or orchestrator is installed.

The upstream skill is pinned by default to `v1.0.0`. The SHA is fixed once in `opencode-review.yml` as `env.PR_LOOP_REF`; direct action and bot review-only calls must supply `pr-review-ref`. Set `pr-review-ref` to another complete commit SHA to override it. The post-release CI updates the default to the latest stable `pr-loop` release SHA and version comments via the release-pins PR. If installation, commit SHA verification (when specified), or required upstream files fail, the workflow fails rather than falling back to the removed bundled implementation. OpenCode GitHub integration can separately add a completion comment.
