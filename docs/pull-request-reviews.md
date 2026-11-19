# Pull request reviews

The `opencode-review.yml` reusable workflow restricts reviews to eligible non-draft, non-bot pull requests opened by trusted repository collaborators, independently of the supplied model. It installs the external [`pr-review` skill](https://github.com/dceoy/pr-loop/tree/main/skills/pr-review) from `dceoy/pr-loop`. The bundled `/review-pr` slash command, dedicated agents, scripts, and local skill were removed.

## Invocation

The review workflow uses `review-only: true` and passes the pull request URL and exact head SHA from the event. The public `agent`, `mentions`, and `use-bundled-toolkit` inputs remain available for backward compatibility: the review agent is always restricted to `action-pr-review`, `mentions` has no effect on PR events, and `use-bundled-toolkit: false` is rejected by review-only mode. The action uses `gh skill install dceoy/pr-loop skills/pr-review --pin <SHA> --agent opencode --scope user` to install just the upstream Skill under `~/.config/opencode/skills/pr-review/` at the immutable `pr-review-ref` commit, then invokes it using a plain-text prompt. The workflow loads the installed skill through OpenCode's native `skill` tool; it does not generate a TUI slash command or modify upstream `SKILL.md` metadata. The default `prompt` is `/pr-review`, which is normalized to review focus before that instruction is constructed. For free-form review focus, select `runtime: v1` and `opencode-version: v1.19.3`; the old `/review-pr` command is not supported.

Review-only runs require OpenCode 1.2.14 or newer and GitHub CLI with `gh skill` support for the OpenCode agent (tested with v2.104.0). GitHub CLI v2.90.0 has `gh skill` but does not support `--agent opencode`. The composite action validates the OpenCode version and immutable SHA, then invokes `gh skill` directly in isolated user scope; no custom installer or package manager is needed.

For direct action usage, set `review-only: 'true'`, keep `use-bundled-toolkit: 'true'`, and supply `PR_REVIEW_URL` and `PR_REVIEW_HEAD_SHA` via the environment, or rely on a `pull_request` event. Comment events require both explicit variables. For manual `opencode-bot.yml` runs, provide `pr-review-url` and `pr-review-head-sha`; unresolved targets fail before OpenCode starts. Review requires a model API key and `pull-requests: write`; the default OpenCode App token flow additionally needs `id-token: write`.

```yaml
jobs:
  review:
    permissions:
      contents: read
      pull-requests: write
      id-token: write
      actions: read
    uses: dceoy/opencode-action/.github/workflows/opencode-review.yml@ab6604cc588b61690c4eae15b4a9682c5c47f011
    with:
      prompt: /pr-review
```

For a focused review with v1, use matching runtime and version inputs:

```yaml
with:
  runtime: v1
  opencode-version: v1.19.3
  prompt: Focus on security and regression risks.
```

The default review model is `opencode/deepseek-v4.1-flash-free`, currently free for a limited time through OpenCode and usable without an account or model-provider API key. GitHub token permissions and the default OIDC-based App token exchange still apply to PR review operations. Pass `with.model` to override the default and supply credentials if required. Free availability and rate limits can change.

## GitHub App token reuse

The token resolver (`.opencode/scripts/resolve-app-token.sh`) is preserved independently of the removed review command. The trusted `pr-review-gh.sh` adapter is installed alongside it under `~/.config/opencode/scripts/`. The review prompt instructs the external `pr-review` skill to route GitHub operations through the trusted native API tool and adapter. Review-only runs use the action-defined `action-pr-review` primary agent regardless of the caller's `agent` input. The v1 integration exchanges the OIDC token inside `opencode github run`. The v2 launcher exchanges it before starting OpenCode and holds the App token in memory. OpenCode and its descendants receive neither the App token nor the OIDC request credentials.

The adapter considers the v2 exchanged token and candidates from Git `http.*.extraheader`. Read-only requests never create pending reviews: with `use-github-token: true`, they preserve the caller's workflow credential; otherwise, they use the first candidate when present, or the existing environment credential when no candidate is found. Before publication, the adapter verifies a candidate with a temporary unsubmitted pending-review create/delete probe, then exports the verified credential to its child `gh` process as `GH_TOKEN` and `GITHUB_TOKEN`. The token is not written to a file or emitted as output.

- **Default (`use-github-token: false`)**: publication requires a verified OpenCode App token; unavailable or mismatched identity fails closed. Read-only requests may use the available scoped credential.
- **Explicit fallback (`use-github-token: true`)**: publication prefers a verified OpenCode App token; otherwise it uses the caller's existing workflow token and its author identity. Read requests preserve that workflow token.

For review-only runs, call the native `pr-review-api` tool with a `request` argument containing a JSON string such as `{ "endpoint": "repos/OWNER/REPO/pulls/NUMBER/reviews", "method": "GET", "paginate": true, "page": 1, "offset": 0, "limit": 4096 }`. In v1, the tool invokes the adapter through fixed process arguments and stdin. In v2, it sends structured requests to the launcher over a per-run loopback endpoint. The launcher executes scoped reads through the adapter and holds the review request in memory until OpenCode exits successfully. For publication, use `method: "POST"` with an embedded `payload` containing the commit-bound COMMENT review. Unknown fields, duplicate keys, invalid bounds and invalid payloads fail closed. No shell expressions, input paths or CLI flags are accepted.

GET responses contain `offset`, `next_offset`, `page`, `next_page`, `total_chars` and `content`. With `paginate: true`, each request fetches **one** GitHub API page (up to 10 entries); `page` defaults to 1. Reissue the same page at `next_offset` and concatenate `content` until `next_offset` is null. If `next_page` is nonnull, continue with that API page starting at `offset: 0`. A short API page terminates pagination; an exactly full page may require one final empty-page request. This avoids downloading all preceding GitHub API pages for each response slice. Commit `check-runs` and combined `status` endpoints also support pagination; their complete response objects are preserved, with continuation based on the `check_runs` or `statuses` array. Use `paginate: false` for other singleton or immutable endpoints. `offset`/`limit` bound each tool response to at most 4096 characters. Immutable `git/trees/<SHA>` and `git/blobs/<SHA>` endpoints provide frozen file evidence; blobs are decoded as UTF-8, while truncated trees and non-text blobs fail. Mutable API responses can change between slices, so revalidate their snapshot before and after reconstruction. POST accepts no output-paging fields. In v1 it returns a bounded review receipt, and the model verifies the persisted review through GET. In v2 it returns a queue acknowledgement. The launcher then verifies the App identity, submits the commit-bound `COMMENT`, and checks the returned review ID, state, and commit SHA.

The adapter accepts structured requests only through the native `pr-review-api` tool. Direct `gh pr` and `gh api` CLI compatibility, file-based `--input` payloads, and arbitrary CLI formatting flags are not supported. The internal subprocess is independently scoped to the review target and verifies commit-bound `COMMENT` payloads before any write.

Automatic formatters and language servers are disabled in review-only runs.

The v1 adapter resolves credentials for each invocation. The v2 launcher supplies its held credential only to trusted adapter processes. In either runtime, the App identity probe runs before publication and creates and deletes a pending review. Explicit workflow-token mode skips the App identity probe in v2. The review agent denies tools by default and allows only the upstream skill, trusted reference reads and globbing, and the native API tool. It denies direct GitHub/network tools, general shell commands, grep, delegation, repository edits and all checkout file reads. Repository content is read through frozen Git blobs instead, so checkout symlinks cannot redirect file reads to runner credentials. These are OpenCode tool permissions, **not an operating-system sandbox**; use trusted runners and grant `pull-requests: write`.

## OpenCode 2 review execution

OpenCode v2 is the default, pinned to `v2.3.0`. To use v1, select `runtime: v1` and a matching exact v1 release. Floating versions are rejected.

The v2 review path accepts only an empty prompt or `/pr-review`, and only pull request, pull request target, or manual dispatch events. It does not support `issue_comment` or `pull_request_review_comment` events. The bot workflow gates review comments on trusted authors and configured mentions, but the action can also be invoked directly and does not enforce those gates itself. Free-form focus is currently supported only by v1. Manual events require an explicit PR URL and full head SHA.

## Review contract and boundaries

Upstream `pr-review` freezes the base/head snapshot, validates findings against repository evidence, and publishes one verified `COMMENT` review by default. It never approves, requests changes, merges, or modifies repository contents. See [the upstream skill specification](https://github.com/dceoy/pr-loop/blob/main/skills/pr-review/SKILL.md) for the authoritative policy.

Review-only runs use a disposable HOME under the runner's temporary directory, including separate XDG paths, and clean it up at the end. Existing runner OpenCode configuration and binaries are never removed. They disable project configuration and external skill discovery, and use a fresh OpenCode installation. They force the restricted review agent and its tool permissions instead of inheriting the caller's agent permissions. Review behavior remains in the pinned upstream skill; no bundled command or orchestrator is installed.

The upstream skill's default commit SHA is defined by the `pr-review-ref` input in `action.yml`. The reusable review workflow omits this input and inherits the action default automatically. Direct action callers and the bot workflow can still override it; an empty bot-workflow input also falls back to the default in `action.yml`. The post-release CI updates the action default to the latest stable `pr-loop` release SHA via the release-pins PR, without modifying workflow files. `gh skill` installs the specified pinned commit without npm lifecycle scripts or local YAML rewrites. The action checks that the destination is unused, required reference files exist, and the installed Skill contains no symlinks. Failure is terminal; there is no bundled fallback. The existing Bats CI job exercises the exact inline installation command with a real SHA-pinned install. OpenCode GitHub integration can separately add a completion comment.

OpenCode v2 uses `opencode run --standalone`. For bot replies to review comments, the launcher posts only the final assistant message from the CLI's JSON output to the thread root.
