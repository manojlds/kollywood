# Kollywood Workspace Instructions

## Scope

- Focus only on the current story/issue.
- Avoid changing systemd, tailscale, or machine-level server configuration unless the story explicitly requires it.
- Do not modify other active stories.

## Git Commits

- Always commit with author and committer set to **Manoj Mahalingam <manojlds@gmail.com>** only.
- Never add `Co-Authored-By` or any other author/trailer lines.
- Commit message format: `type(scope): description` (conventional commits).

## Local Runtime Safety

- Do not stop or restart shared local dev services when validating a story.
- Run tests in isolated test mode by explicitly setting `PHX_SERVER=` and `MIX_ENV=test`.
- If a command reports port conflicts, adjust the test command/environment rather than mutating running services.
