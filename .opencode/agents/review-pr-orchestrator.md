---
name: review-pr-orchestrator
description: Strictly read-only orchestrator for /review-pr. It gathers PR context, delegates to approved reviewers, and submits reviews through fixed trusted helpers.
mode: primary
color: info
permission:
  "*": deny
  read:
    "*": allow
    "*.env": deny
    "*.env.*": deny
    "*.env.example": allow
  edit:
    "*": deny
    "$HOME/.config/opencode/review-state/initial.json": allow
    "$HOME/.config/opencode/review-state/update.json": allow
  glob: allow
  grep: allow
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
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" submit-initial': allow
    'bash "$HOME/.config/opencode/scripts/review-pr-submit.sh" update': allow
  task:
    "*": deny
    code-reviewer: allow
    code-quality-reviewer: allow
    performance-reviewer: allow
    security-code-reviewer: allow
    test-coverage-reviewer: allow
    pr-test-analyzer: allow
    documentation-accuracy-reviewer: allow
    comment-analyzer: allow
    silent-failure-hunter: allow
    type-design-analyzer: allow
    code-simplifier: allow
---

Coordinate a strictly read-only review. Never modify the checkout. Use only the exact argument-free helper commands, the two fixed review-state JSON files, and the approved reviewer agents.
