# Server Config Reference

Kollywood server/runtime behavior is configured primarily through environment variables.

There is currently no generic `~/.kollywood/config.toml` (or YAML/JSON) parser for
server runtime settings.

## Where To Configure On A Deployed Host

- The systemd service uses an env file as the main configuration surface.
- Default path from `bin/install-user-service` is:
  - `~/.kollywood/server.env`
- `~/.kollywood` remains the default data/workspace directory (`KOLLYWOOD_HOME`).
- `bin/deploy` prefers `~/.kollywood/server.env`, and falls back to
  `~/.config/kollywood-server/kollywood-server.env` for legacy setups.

You can still point the unit at any custom env file path via:

```bash
bin/install-user-service --env-file "$HOME/.kollywood/server.env"
```

## Configuration Layers

1. Compile-time config in `config/*.exs` (defaults and build-time behavior).
2. Runtime env vars in `config/runtime.exs` (deployment-specific behavior).
3. Per-project workflow config in `.kollywood/WORKFLOW.md` (agent/runtime policy,
   quality gates, publish behavior, etc).

## Runtime Environment Variables

### Core server/network

| Variable | Default | Notes |
| --- | --- | --- |
| `PHX_SERVER` | disabled unless explicitly enabled | Enable HTTP endpoint in release runs. |
| `PORT` | `4000` | Endpoint port. |
| `PHX_HOST` | `example.com` (prod fallback) | Public host for URL generation/check-origin. |
| `SECRET_KEY_BASE` | none | Required in prod. |
| `DNS_CLUSTER_QUERY` | none | Optional DNS clustering query. |

### Database/ecto

| Variable | Default | Notes |
| --- | --- | --- |
| `DATABASE_URL` | none (`dev` postgres fallback exists) | Primary Postgres URL. Required in prod Postgres builds. |
| `KOLLYWOOD_DATABASE_URL` | none | Alias fallback for `DATABASE_URL`. |
| `POOL_SIZE` | `10` (Postgres), `5` (SQLite) | Repo pool size. |
| `ECTO_SSL` | `false` | Truthy enables SSL for Postgres. |
| `ECTO_IPV6` | `false` | Truthy enables IPv6 socket options. |
| `KOLLYWOOD_DB_PATH` | `~/.kollywood/kollywood.db` | SQLite DB path when SQLite adapter is active. |

### Runtime role/topology

| Variable | Default | Notes |
| --- | --- | --- |
| `KOLLYWOOD_APP_MODE` | `all` | `all`, `web`, `orchestrator`, `worker`. |
| `KOLLYWOOD_WORKER_TRANSPORT` | `local_queue` | `local_queue` or `remote`. |
| `KOLLYWOOD_CONTROL_PLANE_URL` | none | Base URL used by remote workers. |
| `KOLLYWOOD_INTERNAL_API_TOKEN` | none | Internal worker API bearer token. Set for remote worker deployments. |
| `KOLLYWOOD_HOME` | `~/.kollywood` | Data/workspace root for this node. |

### Local pool controls (per node)

| Variable | Default | Notes |
| --- | --- | --- |
| `KOLLYWOOD_WORKER_CONSUMER_ENABLED` | `true` | Start/skip embedded local workers in this node. |
| `KOLLYWOOD_WORKER_CONSUMER_COUNT` | `2` | Number of embedded local worker processes to start. |
| `KOLLYWOOD_WORKER_CONSUMER_CONCURRENCY` | `1` | Max concurrent jobs per embedded worker process. |
| `KOLLYWOOD_WORKER_ID` | derived from `KOLLYWOOD_WORKER_ID` / `HOSTNAME` / PID | Worker identity for remote-worker nodes. |

### Orchestrator controls

| Variable | Default | Notes |
| --- | --- | --- |
| `KOLLYWOOD_GLOBAL_MAX_CONCURRENT_AGENTS` | workflow/app default | Global upper bound for concurrent agent runs. |
| `KOLLYWOOD_ORCHESTRATOR_LEADER_ELECTION` | enabled in prod, disabled in dev by default | Use DB lease election when multiple orchestrator-capable nodes may run. |
| `KOLLYWOOD_CONTROL_STATE_BACKEND` | `db` in prod, `auto` otherwise | `db` or `file`. `db` is recommended with Postgres. |
| `KOLLYWOOD_SCHEDULER_ID` | auto-derived | Optional explicit scheduler owner ID used in leader/lease ownership metadata. |

### Build/version metadata (optional)

| Variable | Default | Notes |
| --- | --- | --- |
| `KOLLYWOOD_GIT_SHA` | inferred from git/release | Reported app git SHA. |
| `KOLLYWOOD_BUILD_TIME` | inferred from release/build | Reported build timestamp. |

## Dev-Only Compile-Time Switch

| Variable | Notes |
| --- | --- |
| `KOLLYWOOD_DB_ADAPTER` | Dev compile-time adapter switch (`postgres` to select Postgres in `config/dev.exs`). |

When switching adapter mode in dev, run `mix clean` before recompiling.
