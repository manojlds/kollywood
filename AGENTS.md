# Kollywood Agent Instructions

## Git Commits

- Always commit with author and committer set to **Manoj Mahalingam <manojlds@gmail.com>** only
- Never add `Co-Authored-By` or any other author/trailer lines
- Commit message format: `type(scope): description` (conventional commits)

## Dev Server Management

- Manage local dev processes with `vaibhav dev`.
- Use `vaibhav dev list` to check process state and ports.
- Start server: `vaibhav dev start kollywood server`
- Restart server: `vaibhav dev restart kollywood server`
- Stop server: `vaibhav dev stop kollywood server`
- Never stop/restart shared dev services only to make tests pass.
- Prefer isolated test commands instead: `PHX_SERVER= MIX_ENV=test ...`.

## Stable Server Deployment

- Treat `/home/manojlds/projects/kollywood` as the only source-of-truth code checkout.
- Never make direct code edits in `/home/manojlds/projects/kollywood-server`.
- Deploy by committing/pushing from the source repo, then updating the server clone.
- Preferred deploy command: `~/.local/bin/kollywood-server-update.sh`
- If assets are stale/missing, run in server clone: `devenv shell -- bash -lc 'MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix phx.digest'`
- Runtime service: `systemctl --user status kollywood-server.service`
- Public endpoint mapping: `systemctl --user status kollywood-tailscale-serve.service` and `tailscale serve status`
- Repo-scoped runtime config lives at `.kollywood/WORKFLOW.md` and `.kollywood/AGENTS.md`.

## Kollywood CLI (Stories)

- Install once: `cargo install --path tools/kollywood-cli --force`
- Default API base URL: `http://127.0.0.1:4000` (override with `KOLLYWOOD_API`)
- From a project directory, add a story with auto-detected project:
  - `kollywood story add --title "Story title" --status draft`
- To target a specific project explicitly:
  - `kollywood story add --project <project-slug> --title "Story title" --status draft`
