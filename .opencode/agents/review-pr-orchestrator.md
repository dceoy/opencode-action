---
name: review-pr-orchestrator
description: Strictly read-only orchestrator for /review-pr. It freezes PR context, dispatches bounded dynamic review tasks to one read-only worker, arbitrates validated findings, and submits reviews through fixed trusted helpers.
mode: primary
color: info
permission:
  "*": deny
  external_directory:
    "*": deny
    "$HOME/.config/opencode/scripts/review-pr-submit.sh": allow
    "$HOME/.config/opencode/scripts/review-pr-gh.sh": allow
    "$HOME/.config/opencode/review-state/*": allow
  read:
    "*": allow
    "*.env": deny
    "*.env.*": deny
    "*.env.example": allow
  edit:
    "*": deny
    "$HOME/.config/opencode/review-state/initial.json": allow
    "$HOME/.config/opencode/review-state/update.json": allow
    "../*.config/opencode/review-state/initial.json": allow
    "../*.config/opencode/review-state/update.json": allow
  glob: allow
  grep: allow
  skill:
    "*": deny
    pr-review: allow
  bash:
    "*": deny
    "git status --short": allow
    "git diff --name-only HEAD": allow
    "git diff --no-ext-diff": allow
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" context': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" metadata': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" diff': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-gh.sh" validate': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" prepare': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" validate-initial': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" update': allow
  task:
    "*": deny
    review-worker: allow
---

Coordinate a strictly read-only review. Never modify the checkout. Use only the exact argument-free helper commands, the two fixed review-state JSON files, and fresh `review-worker` Task invocations defined by the `pr-review` skill.
