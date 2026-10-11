# supabase-setup-cli

> Easily initialize and run a local Supabase stack powered by Docker.

[![npm version](https://img.shields.io/npm/v/supabase-setup-cli.svg)](https://www.npmjs.com/package/supabase-setup-cli)

## Overview

`s‍upabase-init-cli` is a global CLI that scaffolds and launches a local Supabase instance (PostgreSQL, Storage API, Kong HTTP proxy) using Docker Compose. It generates all config/env/secrets needed and supports per-project setup.

## Prerequisites

- [Docker](https://www.docker.com/get-started) & Docker Compose
- Bash (Linux/macOS/WSL; not supported on Windows native shells)

## Installation

```sh
npm install -g supabase-setup-cli
```

## CLI Usage

You can use this CLI from anywhere:

```sh
supabase-setup-cli --name <project_name> --port <postgres_port> --storage-port <storage_port> [--kong-port <kong_port>] [--no-start]
```

### Parameters

| Option           | Description                                               | Example |
| ---------------- | --------------------------------------------------------- | ------- |
| `--name`         | Project name (creates a folder, all files inside)         | `myapp` |
| `--port`         | Exposed port for PostgreSQL                               | `15432` |
| `--storage-port` | Exposed port for the Storage API                          | `5040`  |
| `--kong-port`    | (Optional) Exposed port for Kong (default: `3030`)        | `5555`  |
| `--no-start`     | (Optional) Only generate files, _do not_ start containers |         |

### Example

```sh
# Generate and launch containers for Postgres (on 15432), Storage API (5040), Kong (3030)
supabase-setup-cli --name myapp --port 15432 --storage-port 5040

# Generate a custom Kong port and skip container launch (just generate files)
supabase-setup-cli --name myapp --port 15432 --storage-port 5040 --kong-port 5555 --no-start
```

## Project Layout

A new directory `<name>` is created with:

- `docker-compose.yml` — Compose config for DB, Storage, Kong
- `.env` — Secure, auto-generated credentials & JWTs
- `kong/` — Kong declarative config
- `migrations/init/` — Place your SQL migrations here
  - `01_custom_schema.sql` — Example custom schema file

## After Initialization

- **PostgreSQL**: `localhost:<port>` (`postgres`/`<admin password generated>`, db: `postgres`)
- **Connection string**: `postgres://postgres:<password>@localhost:<port>/postgres`
- **Storage API (direct)**: `http://localhost:<storage-port>`
- **Storage API (via Kong)**: `http://localhost:<kong-port>/storage/v1`
- **SERVICE_KEY**: Shown at end of script & written to `.env`
- **JWT Secrets**: `PGRST_JWT_SECRET`, `ANON_KEY`, and `SERVICE_KEY` are generated per project and stored in `.env`.

## Running & Managing

In your project folder:

```sh
# Start containers (if not already running)
docker compose up -d

# Stop containers
docker compose down

# View logs
docker compose logs -f
```

Or use the CLI wrappers:

```sh
supabase-setup-cli down     # Stop & remove all containers
supabase-setup-cli logs     # Follow container logs
```

## Migrations

All SQL files in `migrations/init/*.sql` are executed (alphabetically) after the database starts.  
You can edit `migrations/init/01_custom_schema.sql` or add additional `.sql` files for your schema/tables/etc.

## Environment & Secrets

- The script creates `.env` if missing, containing all necessary secrets and JWT keys.
- To regenerate secrets: delete `.env` and rerun the CLI.
- **Do not commit `.env` to version control.** (Add to `.gitignore` by default.)

## Example: Create a Storage Bucket

Use the generated `SERVICE_KEY` to create a public storage bucket through Kong:

```sh
SERVICE_KEY="<value printed at initialization>"

curl -X POST "http://localhost:<kong-port>/storage/v1/bucket" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "avatars", "public": true, "allowedMimeTypes": ["image/*"], "fileSizeLimit": "1048576"}'
```

You may also call the storage API directly at `http://localhost:<storage-port>/bucket`.

## Security Advice

- Keep `.env` secure and never commit secrets.
- In production, review and set more restrictive credentials as needed.
- See [Supabase self-hosting documentation](https://supabase.com/docs/guides/self-hosting/docker) for full security/configuration guidelines.
