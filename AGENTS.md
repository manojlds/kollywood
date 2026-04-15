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

## Deploy

Production runs as a release via `systemd --user` on the local server.

```bash
# From ~/projects/kollywood:
git push origin main

# Deploy (builds release from this repo, restarts service):
mise x -- bash bin/deploy

# Optional override when you intentionally deploy from another checkout:
KOLLYWOOD_SERVER_DIR=/path/to/other/checkout mise x -- bash bin/deploy
```

- **Deploy repo**: `~/projects/kollywood` (same checkout used for dev + deploy)
- **Service**: `kollywood-server.service` (systemd user unit)
- **Release**: `~/projects/kollywood/_build/prod/rel/kollywood`
- **Env file**: `~/.kollywood/server.env` (legacy fallback: `~/.config/kollywood-server/kollywood-server.env`)
- **Manage**: `systemctl --user {status,restart,stop,logs} kollywood-server`
- Migrations run automatically on release boot.
- Do **not** use `pitchfork` to start the production server.
