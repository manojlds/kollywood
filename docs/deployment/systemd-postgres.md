# Systemd + Postgres Setup

This is the recommended production-style setup for Kollywood on Linux.

## Linux Server

1. Install host dependencies.

```bash
sudo apt update
sudo apt install -y build-essential curl git unzip docker.io docker-compose-v2
curl https://mise.run | sh
curl https://sh.rustup.rs -sSf | sh
```

If you prefer distro Postgres instead of Docker, the earlier host-Postgres path still works,
but the managed Docker service below is the recommended no-sudo runtime path.

2. Clone the app.

```bash
mkdir -p ~/projects
git clone <your-repo-url> ~/projects/kollywood
```

3. Install the Docker Postgres user service.

```bash
cd ~/projects/kollywood
bin/install-postgres-docker-service --start
```

4. Install the Kollywood app user service and point it at the Docker Postgres URL.

```bash
cd ~/projects/kollywood
bin/install-user-service \
  --phx-host "your-hostname-or-tailnet-name" \
  --database-url "$(bin/postgres-docker-service connection-url)"
```

5. Build and deploy.

```bash
git -C ~/projects/kollywood push origin main
mise x -- bash ~/projects/kollywood/bin/deploy
```

6. Verify.

```bash
systemctl --user status kollywood-server.service
curl http://127.0.0.1:4000/api/health
```

## Existing SQLite Host to Docker Postgres

1. Install Docker Engine and the Compose plugin.
2. Run `bin/install-postgres-docker-service --start`.
3. Update `~/.config/kollywood-server/kollywood-server.env` to include `DATABASE_URL=$(~/projects/kollywood/bin/postgres-docker-service connection-url)`.
4. Ensure `KOLLYWOOD_CONTROL_STATE_BACKEND=db` and `KOLLYWOOD_ORCHESTRATOR_LEADER_ELECTION=true` are set.
5. Run `mise x -- bash bin/deploy` from the dev repo.

## macOS Laptop

Use Docker Postgres locally, but do not use systemd.

1. Install tooling.

```bash
brew install mise rustup-init docker
```

2. Start local Docker Postgres.

```bash
cd ~/projects/kollywood
KOLLYWOOD_POSTGRES_DB=kollywood_dev \
KOLLYWOOD_POSTGRES_USER=kollywood \
KOLLYWOOD_POSTGRES_PASSWORD=kollywood-dev \
KOLLYWOOD_POSTGRES_DATA_DIR="$HOME/.local/share/kollywood/postgres-dev" \
bin/postgres-docker-service start
```

3. Run the app with Postgres.

```bash
cd ~/projects/kollywood
mix clean
DATABASE_URL="ecto://kollywood:kollywood-dev@127.0.0.1:5432/kollywood_dev" pitchfork start server_postgres
```

For a prod-like local release instead of pitchfork:

```bash
MIX_ENV=prod mix release
PHX_SERVER=true DATABASE_URL=ecto://127.0.0.1/kollywood_prod SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')" _build/prod/rel/kollywood/bin/kollywood start
```
