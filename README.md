# Kollywood

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

### mise + pitchfork flow

This project uses `mise.toml` for tool management (Elixir, Erlang) and
`pitchfork.toml` for process management (Phoenix server).

```bash
pitchfork start server
```

To stop:

```bash
pitchfork stop server
```

On first start, pitchfork runs the setup task via mise which bootstraps
deps and the database.

`vaibhav` auto-discovers process ports from pitchfork and live
process checks, so no per-project metadata file is required.

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

### Testing agent prerequisites

Kollywood testing runs assume browser-evidence tooling is available:

- `agent-browser` (global install, outside this repo) for browser automation
- `ffmpeg` for `.webm` recording (install via system package manager)

Quick checks:

```bash
mise x -- agent-browser --version
mise x -- ffmpeg -version
```

Testing runtime behavior:

- runtime-managed service ports come from injected URLs (`runtime_base_url` and `runtime_urls_json`)
- testing should not start ad-hoc servers (`mix phx.server`, custom `PORT=...`, or extra `pitchfork start`)
- if injected runtime URLs are unreachable, treat that as runtime/test failure context instead of probing random localhost ports

## Runtime Modes

Kollywood supports role-based startup via `KOLLYWOOD_APP_MODE`.

- `all` (default): web UI + orchestrator + agent pool
- `web`: web UI only
- `orchestrator`: orchestrator + agent pool (no web endpoint)
- `worker`: agent pool only

Examples:

```bash
# Default local dev behaviour (single node, everything enabled)
mix phx.server

# Web-only node
KOLLYWOOD_APP_MODE=web mix phx.server

# Orchestrator-only node
KOLLYWOOD_APP_MODE=orchestrator mix run --no-halt

# Worker-pool-only node
KOLLYWOOD_APP_MODE=worker mix run --no-halt
```

## Projects

Kollywood now tracks onboarded projects in a SQLite control store.

No project is auto-seeded; onboard projects explicitly.

For newly added projects that do not yet have onboarding files, use the Chat page first and run onboarding to generate `.kollywood/WORKFLOW.md` and `.kollywood/AGENTS.md`.
`prd.json` for local tracker mode is created lazily when local story operations begin.

Deploys also install the latest global `kollywood` CLI from this repo (`tools/kollywood-cli`) into `$HOME/.local/bin` by default, so agents and skills can rely on `kollywood project resolve` and related commands.
The deploy script stamps CLI version as `0.1.0+<git_sha>` and verifies it matches the deployed app commit SHA.
Set `KOLLYWOOD_CLI_INSTALL_ROOT` to override the install root if needed.

Workflow schema is available over API/CLI for machine consumers:

```bash
curl -s http://127.0.0.1:4000/api/workflow/schema | jq
kollywood workflow schema --json
```

When ACP chat starts agent sessions, Kollywood injects `KOLLYWOOD_CLI` (pointing to `~/.local/bin/kollywood` when present) and prepends `~/.local/bin`/`~/.cargo/bin` to `PATH` so skills can reliably call the expected global CLI binary.

```bash
mix kollywood.projects list
mix kollywood.projects add-local --name "Kollywood" --path ~/projects/kollywood
mix kollywood.projects add-github --name "Backend" --repo org/backend
mix kollywood.projects add-gitlab --name "Payments" --repo group/payments
```

## Local Dogfood Tracker (`prd.json`)

Kollywood can run against a local PRD tracker file.

- Default tracker config is in `.kollywood/WORKFLOW.md` (`tracker.kind: prd_json`)
- Default tracker path is `prd.json`
- Stories use `status` values such as `draft`, `open`, `in_progress`, `done`, `failed`, `pending_merge`, `merged`, `cancelled`
- Manual UI/API transitions intentionally block setting `in_progress` directly (that status is orchestrator-managed)
- Default agent kind in `.kollywood/WORKFLOW.md` is `pi` (supported kinds: `amp`, `claude`, `codex`, `cursor`, `opencode`, `pi`)

CLI helpers:

```bash
mix kollywood.prd list
mix kollywood.prd add --title "Implement dogfood status page"
mix kollywood.prd set-status US-001 in_progress
mix kollywood.prd set-status US-001 done
mix kollywood.prd reset US-001
mix kollywood.prd rerun US-001 --clear-notes
mix kollywood.prd validate
mix kollywood.prd validate --path ./some/other/prd.json
```

`reset`/`rerun` always remove `<workspace-root>/<story-id>` before retrying.

`mix kollywood.prd validate` checks:
- top-level JSON object shape
- `userStories` array presence
- unique/non-empty story IDs
- status values (`open`, `in_progress`, `done`)
- dependency integrity (`dependsOn` must reference known IDs and cannot self-reference)

On success it prints a short summary with total and active story counts.
On invalid input it raises `Mix.Error` with clear, itemized validation failures.

### Local Story API

For local tracker projects, story CRUD is also available via JSON API:

```bash
GET    /api/projects/:project_slug/stories
POST   /api/projects/:project_slug/stories
PATCH  /api/projects/:project_slug/stories/:story_id
DELETE /api/projects/:project_slug/stories/:story_id
```

The dashboard Stories tab now uses the same local tracker rules for add/edit/delete and manual status transitions.

### Rust Story CLI

If you want to manage stories from any project directory, install the Rust CLI once:

```bash
cargo install --path tools/kollywood-cli
```

Usage examples:

```bash
# Defaults to KOLLYWOOD_API=http://127.0.0.1:4000
kollywood story list                          # auto-detect project from current directory
kollywood story list --project kollywood      # explicit project override
kollywood story add --project kollywood --title "Add retry metrics" --status draft
kollywood story edit --project kollywood US-012 --status done
kollywood story delete --project kollywood US-012
kollywood story export --project kollywood --output stories.json
kollywood story import --project kollywood --input stories.json --mode upsert
kollywood story import --project kollywood --input stories.json --mode upsert --delete-missing
```

`story import` accepts JSON in one of these shapes: `[{...}]`, `{ "stories": [{...}] }`, or a single story object.
Use `--delete-missing` for full sync; it requires `--mode update|upsert` and IDs for every imported story.

Manual transitions still block setting `in_progress` directly; that status is orchestrator-managed.

Orchestrator controls:

```bash
mix kollywood.orch.status
mix kollywood.orch.poll
mix kollywood.orch.stop US-001
mix kollywood.orch.logs US-001
mix kollywood.orch.logs US-001 --attempt 2
mix kollywood.orch.logs US-001 --follow
```

### Run terminal statuses and events

Run metadata (`run_logs/*/metadata.json`) stores a terminal `status` and event stream (`events.jsonl`).

- terminal statuses:
  - `ok`: run completed without an early stop condition
  - `completed`: agent output matched a configured completion signal
  - `max_turns_reached`: run stopped after reaching configured turn limit
  - `failed`: run ended on an error (agent, checks, review/testing, runtime, or publish)
- workspace lifecycle outcomes:
  - `workspace_cleanup_deleted`: workspace/worktree removed after terminal completion
  - `workspace_cleanup_preserved`: cleanup failed and workspace path was preserved for manual recovery
- key terminal events:
  - `completion_detected`: includes the matched `signal`
  - `idle_timeout_reached`: emitted when a turn exceeds `agent.idle_timeout_ms` without output
  - `run_finished`: final event; includes terminal `status`
- execution session lifecycle events (for observability):
  - `execution_session_started`, `execution_session_completed`, `execution_session_stopped`, `execution_session_stop_failed`
  - legacy `session_started`/`session_stopped` may also appear for backward compatibility

Dashboard run detail surfaces explicit terminal reasons for completion signal, max turns, and idle timeout.

Some workspace/publish/sync failures include structured `recovery_guidance` metadata in `events.jsonl` (summary + commands).
Dashboard run and step views render that guidance directly, and legacy string-based `Recovery commands:` errors remain supported for backward compatibility.

### Operator triage runbook

When a run fails, use this quick triage flow before re-running:

1. Confirm the terminal status and last phase in Dashboard run detail (or `mix kollywood.orch.logs STORY_ID --attempt N`).
2. If recovery guidance is present, run the listed commands exactly as shown first.
3. Only re-run after the root condition is verified fixed (for example: stale worktree removed, branch collision cleared, push auth fixed).

Common scenarios:

- **Idle timeout**
  - Symptom: status `failed`, terminal reason says agent output was idle too long.
  - Triage: inspect the attempt logs and find the last successful phase/turn.
  - Commands:
    - `mix kollywood.orch.logs STORY_ID --attempt N`
  - Resolution: adjust workflow prompt/steps or `agent.idle_timeout_ms` if the task legitimately needs longer silent execution.

- **Completion mismatch (expected signal not observed)**
  - Symptom: run reaches `max_turns_reached` or another terminal failure instead of `completed`.
  - Triage: verify the configured `agent.completion_signals` in `.kollywood/WORKFLOW.md` match actual agent output.
  - Commands:
    - `mix kollywood.orch.logs STORY_ID --attempt N`
    - `mix kollywood.orch.logs STORY_ID --attempt N --follow`
  - Resolution: align completion signals to deterministic output text (or remove overly strict signal requirements).

- **Workspace recovery (collision / stale path / cleanup preserved)**
  - Symptom: workspace/worktree provisioning or cleanup failure with recovery guidance.
  - Triage: use the exact `Recovery commands:` block from Dashboard or `mix kollywood.orch.logs`; those commands are generated for the failing path/branch.
  - Commands:
    - `mix kollywood.orch.logs STORY_ID --attempt N`
  - Resolution: prune stale worktree metadata, remove orphan directories only when confirmed stale, then re-run.

Quality gates are configured in `.kollywood/WORKFLOW.md`:

- `quality.max_cycles`: overall maximum quality loop cycles
- `quality.checks.required`: shell commands that must pass before a story can be marked done
- `quality.checks.fail_fast`: when true, stop checks at first failure; when false, run all checks and report every failure
- `quality.checks.max_cycles`: maximum cycles allowed for checks remediation
- `runtime.command`: runtime command used for process orchestration (defaults to `pitchfork`)
- `runtime.processes`: named pitchfork daemons started for testing/preview runtime
- `runtime.port_offset_mod`: offset pool size for concurrent runtime sessions (offsets are leased strictly; exhaustion fails fast)
- `quality.review.enabled`: when true, runs a reviewer agent round and requires a `review.json` verdict (`"pass"`/`"fail"`)
- `quality.review.max_cycles`: maximum cycles allowed for review remediation
- `quality.review.agent`: reviewer adapter settings (kind/command/args/env/timeout)
- `quality.testing.enabled`: when true, enables tester-agent validation after review
- `quality.testing.max_cycles`: maximum tester remediation cycles
- `quality.testing.agent`: optional tester-agent overrides (kind/command/args/env/timeout)
- when `kind: codex`, Kollywood defaults to `codex exec --ask-for-approval never --sandbox workspace-write` for non-interactive automation-safe runs
- testing agents are expected to validate only against runtime-injected URLs (no ad-hoc local port fallbacks)
- `preview.enabled`: enables per-story preview policy metadata for pending-merge flows
- `preview.ttl_minutes`: default preview time-to-live before automatic shutdown
- `preview.reuse_testing_runtime`: whether preview should prefer reusing testing runtime state
- `preview.allow_on_demand_from_pending_merge`: allows user-triggered preview spin-up in `pending_merge`
- default command timeouts are 30 minutes unless overridden in workflow config

Example testing + preview workflow config:

```yaml
quality:
  max_cycles: 2
  testing:
    enabled: true
    max_cycles: 2
    timeout_ms: 600000
    prompt_template: |
      Validate what was implemented and write testing artifacts.
    agent:
      kind: cursor
      timeout_ms: 600000

preview:
  enabled: true
  ttl_minutes: 120
  reuse_testing_runtime: true
  allow_on_demand_from_pending_merge: true
```

Per-story execution overrides can also enable testing/preview:

```json
{
  "settings": {
    "execution": {
      "testing_enabled": true,
      "preview_enabled": true,
      "testing_agent_kind": "cursor",
      "testing_max_cycles": 2
    }
  }
}
```

Example Codex-first workflow config:

```yaml
agent:
  kind: codex

quality:
  review:
    enabled: true
    agent:
      kind: codex
  testing:
    enabled: true
    agent:
      kind: codex
```

Codex execution is always configured for non-interactive behavior in adapter defaults,
including disabled approval prompts for unattended run/review/testing phases.

Repo-specific agent guidance can live in `.kollywood/AGENTS.md`.
The default `before_run` hook copies it to `AGENTS.md` in each workspace when present.

Publish policy controls whether successful runs can publish branches and open pull requests.
Defaults are conservative so nothing is pushed remotely unless explicitly enabled.

- `publish.provider`: `github` or `gitlab` (default: `github`)
- `publish.auto_push`: `never` or `on_pass` (default: `never`)
- `publish.auto_create_pr`: `never`, `draft`, or `ready` (default: `never`)
- `git.require_commit`: `true` or `false` (default: `true`)

Safe default policy (no push, no PR):

```yaml
publish:
  provider: github
  auto_push: never
  auto_create_pr: never

git:
  require_commit: true
```

Enable publish on successful runs with draft PRs:

```yaml
publish:
  provider: github
  auto_push: on_pass
  auto_create_pr: draft

git:
  require_commit: true
```

Minimal story shape:

```json
{
  "id": "US-001",
  "title": "Implement feature",
  "description": "What needs to be built",
  "priority": 1,
  "status": "open",
  "dependsOn": []
}
```

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
