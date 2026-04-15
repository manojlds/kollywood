# Deployment Topology Guide

This guide documents which Kollywood runtime shapes are currently supported,
and how to choose between SQLite/Postgres plus single-node or multi-node layouts.
For a complete runtime env variable reference, see `docs/deployment/config-reference.md`.

## Quick Matrix

| Control store | Topology | Status | Recommended use |
| --- | --- | --- | --- |
| SQLite | Single server/process on one host | Supported | Local development and testing |
| SQLite | Multi-process on one host | Not supported | Use Postgres instead |
| SQLite | Multi-host / distributed | Not supported | Use Postgres instead |
| Postgres | Single server/process on one host | Supported | Baseline production and local prod-like runs |
| Postgres | One control-plane + multiple workers (same host) | Supported | Scale worker capacity on one machine |
| Postgres | One control-plane + multiple workers (multi-host) | Supported | Horizontal worker scaling across machines |
| Postgres | Multiple control-plane servers | Advanced (not default runbook) | HA/failover experiments with careful validation |

## Terms

- `control-plane node`: runs API/UI + orchestrator scheduling logic.
- `worker node`: executes run attempts and reports results back to control plane.

Runtime roles are controlled by `KOLLYWOOD_APP_MODE`:

- `all` = web UI + orchestrator + agent pool
- `web` = web UI only
- `orchestrator` = orchestrator + agent pool
- `worker` = agent pool only

## 1) SQLite Single-Node (Default Dev)

Use this for laptop development when you only need one Kollywood process.

```bash
mise run server
# or
pitchfork start server
```

Notes:

- SQLite is single-control-plane only.
- Do not run multiple Kollywood server instances against the same SQLite control store.

## 2) Postgres Single-Node

Use this for baseline production-style deployments and local Postgres-backed testing.

- Linux/macOS setup steps are in `docs/deployment/systemd-postgres.md`.
- In dev, you can run:

```bash
mix clean
DATABASE_URL="ecto://kollywood:kollywood-dev@127.0.0.1:5432/kollywood_dev" pitchfork start server_postgres
```

## 3) Postgres Multi-Process, Same Host

Recommended pattern: one control-plane process plus one or more worker-only processes.

Control-plane env:

```bash
KOLLYWOOD_APP_MODE=all
DATABASE_URL=ecto://...
KOLLYWOOD_INTERNAL_API_TOKEN=<shared-secret>
KOLLYWOOD_WORKER_TRANSPORT=remote
KOLLYWOOD_WORKER_CONSUMER_ENABLED=false
```

Worker env (per worker process):

```bash
KOLLYWOOD_APP_MODE=worker
KOLLYWOOD_WORKER_TRANSPORT=remote
KOLLYWOOD_CONTROL_PLANE_URL=http://127.0.0.1:4000
KOLLYWOOD_INTERNAL_API_TOKEN=<same-shared-secret>
DATABASE_URL=ecto://...
KOLLYWOOD_HOME=$HOME/.kollywood-worker-1
KOLLYWOOD_WORKER_CONSUMER_COUNT=1
KOLLYWOOD_WORKER_CONSUMER_CONCURRENCY=1
```

Notes:

- Keep a unique `KOLLYWOOD_HOME` per worker process when multiple workers run on one host.
- `KOLLYWOOD_CONTROL_PLANE_URL` must target a node with the web endpoint enabled.
- Keep all nodes on the same app version/build.

## 4) Postgres Multi-Host (Distributed Workers)

Use one control-plane node and run worker-only nodes on other machines.

Worker requirements:

- `KOLLYWOOD_APP_MODE=worker`
- `KOLLYWOOD_WORKER_TRANSPORT=remote`
- `KOLLYWOOD_CONTROL_PLANE_URL=https://<control-plane-host>`
- same `KOLLYWOOD_INTERNAL_API_TOKEN` as control plane
- valid `DATABASE_URL`

Operational checklist:

- Ensure network reachability from workers to control-plane internal API.
- Ensure worker hosts have required tooling (agent CLIs, ffmpeg, git, etc.).
- Ensure repository/workspace assumptions in workflow config are valid on worker hosts.
- Prefer TLS/auth at the network edge for control-plane access.

## 5) Multiple Control-Plane Nodes (Advanced)

This is not the default runbook today. If you run more than one orchestrator-capable node,
use Postgres and explicit leader-election settings.

Required settings:

```bash
KOLLYWOOD_ORCHESTRATOR_LEADER_ELECTION=true
KOLLYWOOD_CONTROL_STATE_BACKEND=db
DATABASE_URL=ecto://...
```

Recommendation:

- Start with a single control-plane node and scale workers first.
- Move to multi-control-plane only after validating your failover/runbook behavior.

## Environment Variable Reference

| Variable | Meaning |
| --- | --- |
| `KOLLYWOOD_DB_ADAPTER` | Dev-only adapter switch (`postgres` to enable Postgres in `dev`) |
| `DATABASE_URL` / `KOLLYWOOD_DATABASE_URL` | Postgres connection string |
| `KOLLYWOOD_APP_MODE` | Role selection: `all`, `web`, `orchestrator`, `worker` |
| `KOLLYWOOD_WORKER_TRANSPORT` | Worker transport: `local_queue` or `remote` |
| `KOLLYWOOD_WORKER_CONSUMER_ENABLED` | Enables/disables local worker processes in this node |
| `KOLLYWOOD_WORKER_CONSUMER_COUNT` | Number of local worker processes started in this node |
| `KOLLYWOOD_WORKER_CONSUMER_CONCURRENCY` | Local concurrency per worker process |
| `KOLLYWOOD_CONTROL_PLANE_URL` | Control-plane base URL used by remote workers |
| `KOLLYWOOD_INTERNAL_API_TOKEN` | Bearer token for internal worker API auth |
| `KOLLYWOOD_ORCHESTRATOR_LEADER_ELECTION` | Enables orchestrator lease election |
| `KOLLYWOOD_CONTROL_STATE_BACKEND` | Control state backend (`db` recommended for Postgres) |
| `KOLLYWOOD_HOME` | Local Kollywood data/workspace root on each node |

## Adapter Switching Reminder (Dev)

Adapter choice in development is compile-time. When switching SQLite <-> Postgres in dev,
run `mix clean` before recompiling/restarting.
