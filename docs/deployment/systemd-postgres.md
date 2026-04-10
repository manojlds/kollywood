# Systemd + Postgres Setup

This is the recommended production-style setup for Kollywood on Linux.

## Linux Server

1. Install host dependencies.

```bash
sudo apt update
sudo apt install -y build-essential curl git unzip postgresql postgresql-contrib
curl https://mise.run | sh
curl https://sh.rustup.rs -sSf | sh
```

2. Clone the app.

```bash
mkdir -p ~/projects
git clone <your-repo-url> ~/projects/kollywood
git clone <your-repo-url> ~/projects/kollywood-server
```

3. Create the Postgres role and database.

```bash
sudo -u postgres createuser --pwprompt kollywood
sudo -u postgres createdb --owner=kollywood kollywood_prod
```

4. Install the user service and env file.

```bash
cd ~/projects/kollywood
bin/install-user-service \
  --repo-dir "$HOME/projects/kollywood-server" \
  --phx-host "your-hostname-or-tailnet-name" \
  --database-url "ecto://kollywood:YOUR_DB_PASSWORD@127.0.0.1:5432/kollywood_prod"
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

## Existing SQLite Host to Postgres

1. Install and start Postgres.
2. Create `kollywood_prod` and a dedicated role.
3. Update `~/.config/kollywood-server/kollywood-server.env` to include `DATABASE_URL`.
4. Set `KOLLYWOOD_CONTROL_STATE_BACKEND=db` and `KOLLYWOOD_ORCHESTRATOR_LEADER_ELECTION=true`.
5. Run `mise x -- bash bin/deploy` from the dev repo.

## macOS Laptop

Use Postgres locally, but do not use systemd.

1. Install tooling.

```bash
brew install postgresql@16 mise rustup-init
brew services start postgresql@16
```

2. Create the local database.

```bash
createdb kollywood_dev
```

3. Run the app with Postgres.

```bash
cd ~/projects/kollywood
mix clean
KOLLYWOOD_DB_ADAPTER=postgres DATABASE_URL=ecto://127.0.0.1/kollywood_dev pitchfork start server_postgres
```

For a prod-like local release instead of pitchfork:

```bash
MIX_ENV=prod mix release
PHX_SERVER=true DATABASE_URL=ecto://127.0.0.1/kollywood_prod SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')" _build/prod/rel/kollywood/bin/kollywood start
```
