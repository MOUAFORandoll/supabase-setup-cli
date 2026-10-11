# supabase-setup-cli

> Easily initialize a complete local Supabase stack powered by Docker.

[![npm version](https://img.shields.io/npm/v/supabase-setup-cli.svg)](https://www.npmjs.com/package/supabase-setup-cli)

## Overview

`s‍upabase-setup-cli` is a global CLI tool that sets up and runs a local Supabase stack (PostgreSQL, Storage API, Kong proxy) using Docker Compose. It generates all necessary config files, secrets, and environment variables, isolating each project in its own directory.

## Requirements

- [Docker](https://www.docker.com/get-started) & Docker Compose
- Bash (Linux/macOS/WSL – not compatible with native Windows)

## Installation

```sh
npm install -g supabase-setup-cli
```

## CLI Usage

Run the CLI from any directory:

```sh
supabase-setup-cli init name=<project_name> port=<postgres_port> storage-port=<storage_port> [kong-port=<kong_port>] [no-start]
```

### Parameters

| Option         | Description                                                       | Example |
| -------------- | ----------------------------------------------------------------- | ------- |
| `name`         | Project name (creates a folder with all generated configs inside) | `myapp` |
| `port`         | Exposed port for PostgreSQL                                       | `5432`  |
| `storage-port` | Exposed port for the Storage API                                  | `5000`  |
| `kong-port`    | (Optional) Exposed port for Kong (default: `3030`)                | `5555`  |
| `no-start`     | (Optional) Generates files _without_ starting containers          |         |

### Examples

```sh
# Generate and launch Postgres (5432), Storage API (5000), Kong (3030)
supabase-setup-cli init name=myapp port=5432 storage-port=5000

# Use a custom Kong port and generate files without starting services
supabase-setup-cli init name=myapp port=5432 storage-port=5000 kong-port=5555 no-start
```

## Project Structure

The CLI will create a `<name>` directory containing:

- `docker-compose.yml` — Compose config (DB, Storage, Kong)
- `.env` — Dynamically generated credentials and JWTs
- `kong/` — Declarative Kong config
- `migrations/init/` — Place your migration SQL files here
  - `01_custom_schema.sql` — Example schema file

## After Initialization

- **PostgreSQL**: `localhost:<port>` (`postgres`/`<generated ADMIN_PASSWORD>`, database: `postgres`)
- **Connection string:** `postgres://postgres:<password>@localhost:<port>/postgres`
- **Storage API (direct):** `http://localhost:<storage-port>`
- **Storage API (via Kong):** `http://localhost:<kong-port>/storage/v1`
- **SERVICE_KEY:** Displayed at the end of the script and saved in `.env`
- **JWT Secrets:** `PGRST_JWT_SECRET`, `ANON_KEY`, and `SERVICE_KEY` are generated per project and stored in `.env`.

## Service Management

From within the project directory:

```sh
# Start containers if not already running
docker compose up -d

# Stop containers
docker compose down

# View logs
docker compose logs -f
```

You can also use CLI shortcuts:

```sh
# From within the project directory:
supabase-setup-cli down        # Stop and remove all project containers
supabase-setup-cli logs        # Stream real-time container logs

# From anywhere, target a specific project by name:
supabase-setup-cli down myapp  # Stop and remove containers for "myapp"
supabase-setup-cli logs myapp  # Stream logs for "myapp"
```

# End of Selection

````

## Migrations

All SQL files in `migrations/init/*.sql` are run in alphabetical order after the database starts.
Modify `migrations/init/01_custom_schema.sql` or add your own `.sql` files to define your schemas, tables, etc.

## Environment & Secrets

- The script creates `.env` if it doesn’t already exist, containing all generated secrets and JWTs.
- To re-generate secrets: delete `.env` and re-run the CLI.
- **NEVER commit `.env` to your version control** (it is git-ignored by default).

## Example: Creating a Storage Bucket

Use the generated `SERVICE_KEY` to create a public bucket via Kong:

```sh
SERVICE_KEY="<key displayed during init>"

curl -X POST "http://localhost:<kong-port>/storage/v1/bucket" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "avatars", "public": true, "allowedMimeTypes": ["image/*"], "fileSizeLimit": "1048576"}'
````

You can also call the Storage API directly at: `http://localhost:<storage-port>/bucket`.

## Security

- Keep `.env` secret and never commit it.
- For production, verify credentials and adapt as needed for remote usage.
- See the [Supabase self-hosting documentation](https://supabase.com/docs/guides/self-hosting/docker) for more options and guidance.
