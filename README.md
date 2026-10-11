# supabase-setup-cli

> Easily initialize a complete local Supabase stack powered by Docker.

[![npm version](https://img.shields.io/npm/v/supabase-setup-cli.svg)](https://www.npmjs.com/package/supabase-setup-cli)

## Overview

`s‍upabase-setup-cli` is a global CLI that generates and launches a local Supabase instance (PostgreSQL, Storage API, Kong proxy) using Docker Compose. It creates all necessary config files, secrets, and environment variables, and supports project-per-project installations.

## Prerequisites

- [Docker](https://www.docker.com/get-started) & Docker Compose
- Bash (Linux/macOS/WSL – not compatible with native Windows shells)

## Installation

```sh
npm install -g supabase-setup-cli
```

## CLI Usage

Run the CLI from any folder you want:

```sh
supabase-setup-cli name=<project_name> port=<postgres_port> storage-port=<storage_port> [kong-port=<kong_port>] [no-start]
```

### Parameters

| Option           | Description                                                              | Example  |
|------------------|--------------------------------------------------------------------------|----------|
| `name`           | Project name (creates a folder, all config is generated inside)          | `myapp`  |
| `port`           | Exposed port for PostgreSQL                                              | `15432`  |
| `storage-port`   | Exposed port for the Storage API                                         | `5040`   |
| `kong-port`      | (Optional) Exposed port for Kong (default: `3030`)                       | `5555`   |
| `no-start`       | (Optional) Generate the files _without_ starting containers              |          |

### Examples

```sh
# Generate and launch Postgres (15432), Storage API (5040), Kong (3030)
supabase-setup-cli name=myapp port=15432 storage-port=5040

# Use a custom Kong port and only generate files without starting the services
supabase-setup-cli name=myapp port=15432 storage-port=5040 kong-port=5555 no-start
```

## Project Structure

The CLI creates a `<name>` folder containing:

- `docker-compose.yml` — The Compose config (DB, Storage, Kong)
- `.env` — Dynamically generated credentials and JWTs
- `kong/` — Declarative config for Kong
- `migrations/init/` — Place your SQL migration files here
  - `01_custom_schema.sql` — Example custom schema file

## After Initialization

- **PostgreSQL**: `localhost:<port>` (`postgres`/`<generated_admin_password>`, database: `postgres`)
- **Connection string**: `postgres://postgres:<password>@localhost:<port>/postgres`
- **Storage API (direct)**: `http://localhost:<storage-port>`
- **Storage API (via Kong)**: `http://localhost:<kong-port>/storage/v1`
- **SERVICE_KEY**: Shown at the end of the script and present in `.env`
- **JWT Secrets**: `PGRST_JWT_SECRET`, `ANON_KEY`, and `SERVICE_KEY` are generated per project and stored in `.env`.

## Service Management

From within the project folder:

```sh
# Start containers if they aren't already running
docker compose up -d

# Stop containers
docker compose down

# View logs
docker compose logs -f
```

The CLI also provides shortcuts:

```sh
supabase-setup-cli down     # Stop and remove all project containers
supabase-setup-cli logs     # Tail the logs for the containers
```

## Migrations

All SQL files in `migrations/init/*.sql` are applied in alphabetical order after the database starts.
Edit `migrations/init/01_custom_schema.sql` or add your own `.sql` files for your schemas, tables, etc.

## Environment & Secrets

- The script creates `.env` if it doesn't exist, containing all required secrets and JWTs.
- To regenerate secrets: delete `.env` and rerun the CLI.
- **NEVER commit `.env` to your VCS** (the file is included by default in `.gitignore`).

## Example: Create a Storage Bucket

Use the generated `SERVICE_KEY` to create a public bucket via Kong:

```sh
SERVICE_KEY="<key shown at init>"

curl -X POST "http://localhost:<kong-port>/storage/v1/bucket" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "avatars", "public": true, "allowedMimeTypes": ["image/*"], "fileSizeLimit": "1048576"}'
```

You can also call the Storage API directly at `http://localhost:<storage-port>/bucket`.

## Security

- Keep `.env` secret and do not commit it.
- In production, review credentials and adapt them for remote use.
- See the [Supabase self-hosting documentation](https://supabase.com/docs/guides/self-hosting/docker) for more guidance and configuration options.
