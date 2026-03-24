# Kollywood

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

### devenv flow

This project includes a `devenv.nix` with a `server` process.

```bash
devenv processes up server
```

For background mode:

```bash
devenv processes up --detach server
```

On first start (or when `mix.lock` changes), the devenv server process
automatically runs:

```bash
mix local.hex --force
mix local.rebar --force
mix setup
```

So `vaibhav dev start kollywood server` can bootstrap and run without a
separate manual setup step.

`vaibhav` auto-discovers process ports from devenv task scripts and live
process checks, so no per-project metadata file is required.

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Local Dogfood Tracker (`prd.json`)

Kollywood can run against a local PRD tracker file.

- Default tracker config is in `WORKFLOW.md` (`tracker.kind: prd_json`)
- Default tracker path is `prd.json`
- Stories use `status` values: `open`, `in_progress`, `done`
- Default agent kind in `WORKFLOW.md` is `pi`

CLI helpers:

```bash
mix kollywood.prd list
mix kollywood.prd add --title "Implement dogfood status page"
mix kollywood.prd set-status US-001 in_progress
mix kollywood.prd set-status US-001 done
mix kollywood.prd validate
mix kollywood.prd validate --path ./some/other/prd.json
```

`mix kollywood.prd validate` checks:
- top-level JSON object shape
- `userStories` array presence
- unique/non-empty story IDs
- status values (`open`, `in_progress`, `done`)
- dependency integrity (`dependsOn` must reference known IDs and cannot self-reference)

On success it prints a short summary with total and active story counts.
On invalid input it raises `Mix.Error` with clear, itemized validation failures.

Orchestrator controls:

```bash
mix kollywood.orch.status
mix kollywood.orch.poll
mix kollywood.orch.stop US-001
```

Quality gates are configured in `WORKFLOW.md`:

- `checks.required`: shell commands that must pass before a story can be marked done
- `review.enabled`: when true, runs a reviewer agent round and requires verdict tokens
- `review.max_cycles`: maximum worker/reviewer feedback cycles before failing the run
- `review.agent`: reviewer adapter settings (kind/command/args/env/timeout)

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
