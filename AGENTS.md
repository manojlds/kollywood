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

## Kollywood CLI (Stories)

- Install once: `cargo install --path tools/kollywood-cli --force`
- Default API base URL: `http://127.0.0.1:4000` (override with `KOLLYWOOD_API`)
- From a project directory, add a story with auto-detected project:
  - `kollywood story add --title "Story title" --status draft`
- To target a specific project explicitly:
  - `kollywood story add --project <project-slug> --title "Story title" --status draft`
