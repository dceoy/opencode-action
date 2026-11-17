# GitHub runner event inventory

This inventory describes the reusable workflows at the base of #60. It is not a
claim that the action has a general v2 GitHub runner. General automation still
uses OpenCode 1's `github run`; the v2 path is review-only. The separate review
adapter has its own pinned-snapshot policy and is outside this inventory's
proposed mutation policy.

| Entry point | Current routing | Mutation considerations for a future runner |
| --- | --- | --- |
| `pull_request_review_comment` created | The bot job requires a non-bot comment author with OWNER, MEMBER, or COLLABORATOR association, and a configured mention. The body is input to the model, not authorization. | Resolve the PR through GitHub, bind the repository, PR number, head repository, branch and full head SHA, check permissions, and reject forks and changed heads before writes. |
| `workflow_call` | Inherited non-review-comment events require a nonempty prompt; inherited review-comment events retain the trusted-author and mention gates. | A prompt alone does not identify or authorize a write target. Define and validate a target for each supported inherited event before enabling mutations. |
| `workflow_dispatch` | The bot requires a nonempty prompt. | Define a trusted target and immutable expected SHA; do not infer write endpoints from model output. |
| `pull_request` opened or ready for review | The review workflow checks author association, non-bot author and non-draft status. It also exposes `workflow_call`, but its job currently runs only for `pull_request`. | This is the separate review-only path, not the general mutation runner. |
| `issue_comment` | The bot has no trigger for issue or PR conversation comments. | Unsupported; restoring this trigger requires a separate security decision. |

The bot checks out the event's default checkout ref at depth one; it does not
explicitly check out the PR head. When `use-github-token` is true it persists
checkout credentials and configures a bot Git identity. Otherwise general v1
behavior, including App token exchange, progress, publication, reactions and any
attachment handling, is delegated to `opencode github run`; the workflow does
not independently guarantee those behaviors. Neither the workflow's trigger
check nor its checkout establishes a safe v2 mutation target. Fork behavior and
token permissions also depend on GitHub and caller settings. A future runner
must make its own checks and must not execute checkout-controlled configuration
as trusted authorization logic.

The allowlist mentioned in #59's draft PR #163 is not present on this base.
When reconciling that PR, drop `issue_comment` from its v2 runner allowlist;
this inventory does not authorize it. The PR review-comment event is distinct
from an issue/PR conversation comment.
