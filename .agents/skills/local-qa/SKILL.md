---
name: local-qa
description: Run local QA including formatting, linting, and testing for the repository. Use whenever any file has been updated.
disable-model-invocation: false
---

# Local QA (format, lint, and test)

Run the local QA script `scripts/qa.sh` in this skill.

## Procedure

- Execute the script exactly as shown above when this skill is triggered.
- Capture and summarize key output (success/failure, major warnings, and any files modified).
- If the script fails due to missing tooling (`command not found`, missing executable, or equivalent), install the missing tool(s) and rerun `./scripts/qa.sh`.
- Install tools using this order of preference:
  1. Use the project's package manager when applicable (`uv`/`poetry` for Python, package manager scripts/dependencies for Node.js).
  2. Use a system package manager (`brew` on macOS, `apt` on Debian/Ubuntu) when project-local install is not applicable.
  3. Use language-specific installers as fallback (`pipx`/`pip`, `npm`, `go install`, etc.).
- If multiple tools are missing, repeat install -> rerun until QA completes or you hit a blocker.
- If installation fails or requires unavailable privileges, report what was attempted, the exact failure, and stop.
- Do not run unrelated commands; only run commands needed for QA and missing-tool installation.
