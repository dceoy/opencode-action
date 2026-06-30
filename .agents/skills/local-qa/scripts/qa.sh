#!/usr/bin/env bash

set -euox pipefail
cd "$(git rev-parse --show-toplevel)"

# Markdown
npx -y prettier --write './**/*.md'

# YAML
git ls-files -z -- '*.yml' | xargs -0 -t uvx yamllint -d '{"extends": "relaxed", "rules": {"line-length": "disable"}}'

# GitHub Actions
zizmor --fix=safe .github/workflows
git ls-files -z -- '.github/workflows/*.yml' | xargs -0 -t actionlint
checkov --framework=all --output=github_failed_only --directory=.

# OpenCode agent frontmatter and review-pr references
./.agents/skills/local-qa/scripts/validate-opencode.sh
