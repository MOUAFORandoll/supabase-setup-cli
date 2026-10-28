#!/usr/bin/env bash
set -euo pipefail

CALLER_DIR="$(pwd)"
BASE_DIR="${CALLER_DIR}"

usage() {
  echo "Usage: supabase-setup-cli init name=<name> port=<port> storage-port=<port> [kong-port=<port>] [no-start]"
  echo ""
  echo "Commands:"
  echo "  init                   Initialize a new Supabase project in the current directory"
  echo ""
  echo "Options:"
  echo "  name=<name>            Project name (creates a <name>_supabase directory)"
  echo "  port=<port>            Exposed port for PostgreSQL (e.g., 5432)"
  echo "  storage-port=<port>    Exposed port for the Storage API (e.g., 5000)"
  echo "  kong-port=<port>       Exposed port for Kong (e.g., 3030, default)"
  echo "  no-start               Only generate the docker-compose file, do not start containers"
  exit 1
}

check_docker_dependencies() {
  local missing=false

  if ! command -v docker &> /dev/null; then
    missing=true
  fi

  if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
    missing=true
  fi

  if [[ "$missing" == true ]]; then
    echo "⚠️  Warning: Docker or Docker Compose does not appear to be installed on your system."
    echo ""
    read -rp "Do you want to continue anyway (will generate files without starting services)? (y/N) " response
    case "$response" in
      [yY][eE][sS]|[yY])
        echo "Continuing file generation (option no-start is implicitly enabled)..."
        NO_START=true
        ;;
      *)
        echo "Aborted. Please install Docker and Docker Compose to launch Supabase."
        exit 1
        ;;
    esac
  fi
}

# ---------- MAIN ----------

if [[ $# -lt 1 ]]; then
  usage
fi

SUBCOMMAND="$1"
shift

NAME=""
PORT=""
STORAGE_PORT=""
KONG_PORT="3030"
NO_START=false

if [[ "$SUBCOMMAND" == "init" ]]; then
  # Parse arguments securely using a while loop and shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      name=*)
        NAME="${1#name=}"
        ;;
      port=*)
        PORT="${1#port=}"
        ;;
      storage-port=*)
        STORAGE_PORT="${1#storage-port=}"
        ;;
      kong-port=*)
        KONG_PORT="${1#kong-port=}"
        ;;
      no-start)
        NO_START=true
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        echo "Unknown option or command: $1"
        usage
        ;;
    esac
    shift
  done

  if [[ -z "$NAME" ]] || [[ -z "$PORT" ]] || [[ -z "$STORAGE_PORT" ]]; then
    echo "Error: name=, port=, and storage-port= are required."
    usage
  fi

  check_docker_dependencies

  if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Project name must contain only letters, numbers, dashes, and underscores."
    exit 1
  fi

  # Re-initializing from the generated project folder must target that
  # folder, not create <name>_supabase/<name>_supabase. If already nested
  # by an older CLI run, prefer the parent project folder when it exists.
  if [[ "$(basename "${CALLER_DIR}")" == "${NAME}_supabase" ]] && \
    [[ "$(basename "$(dirname "${CALLER_DIR}")")" == "${NAME}_supabase" ]] && \
    [[ -f "$(dirname "${CALLER_DIR}")/docker-compose.yml" ]]; then
    PROJECT_DIR="$(dirname "${CALLER_DIR}")"
  elif [[ "$(basename "${CALLER_DIR}")" == "${NAME}_supabase" ]] && \
    [[ -f "${CALLER_DIR}/docker-compose.yml" ]]; then
    PROJECT_DIR="${CALLER_DIR}"
  else
    PROJECT_DIR="${CALLER_DIR}/${NAME}_supabase"
  fi
  BASE_DIR="$(dirname "${PROJECT_DIR}")"
  echo "Creating project directory: ${PROJECT_DIR}"
  mkdir -p "${PROJECT_DIR}"
  cd "${PROJECT_DIR}"

  TARGET_DIR="$(pwd)"
  COMPOSE_FILE="${TARGET_DIR}/docker-compose.yml"
  ENV_FILE="${TARGET_DIR}/.env"
  KONG_DIR="${TARGET_DIR}/kong"

  CONTAINER_NAME="${NAME}_supabase"
  SERVICE_DB="${NAME}-db"
  SERVICE_STORAGE="${NAME}-storage"
  VOLUME_DB="${NAME}_db_data"
  VOLUME_STORAGE="${NAME}_storage_data"
  STORAGE_CONTAINER="${NAME}_supabase_storage"
  KONG_CONTAINER="${NAME}_supabase_kong"

  jwt_sign() {
    local payload="$1"
    local secret="$2"
    local header='{"alg":"HS256","typ":"JWT"}'
    base64_url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
    local header_b64 payload_b64 msg sig
    header_b64=$(echo -n "$header" | base64_url)
    payload_b64=$(echo -n "$payload" | base64_url)
    msg="${header_b64}.${payload_b64}"
    sig=$(echo -n "$msg" | openssl dgst -sha256 -hmac "$secret" -binary | base64_url)
    echo "${msg}.${sig}"
  }

  PGRST_JWT_SECRET_VALUE=""
  ANON_KEY_VALUE=""
  SERVICE_KEY_VALUE=""
  ADMIN_PASSWORD_VALUE="SupabaseLocal2026"
  LEGACY_ADMIN_PASSWORD_VALUE=""

  # Keep a previous bootstrap password long enough to authenticate to an
  # existing volume before switching both database roles to the fixed value.
  for legacy_env in "${BASE_DIR}/.env" "${BASE_DIR}/${NAME}/.env" "${ENV_FILE}"; do
    if [[ -f "${legacy_env}" ]]; then
      LEGACY_ADMIN_PASSWORD_VALUE="$(sed -n 's/^ADMIN_PASSWORD=//p' "${legacy_env}" | head -n 1)"
      if [[ -n "${LEGACY_ADMIN_PASSWORD_VALUE}" && "${LEGACY_ADMIN_PASSWORD_VALUE}" != "${ADMIN_PASSWORD_VALUE}" ]]; then
        break
      fi
      LEGACY_ADMIN_PASSWORD_VALUE=""
    fi
  done
  if [[ -z "${LEGACY_ADMIN_PASSWORD_VALUE}" ]] && docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    LEGACY_ADMIN_PASSWORD_VALUE="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER_NAME}" | sed -n 's/^POSTGRES_PASSWORD=//p' | head -n 1)"
    [[ "${LEGACY_ADMIN_PASSWORD_VALUE}" == "${ADMIN_PASSWORD_VALUE}" ]] && LEGACY_ADMIN_PASSWORD_VALUE=""
  fi

  generate_jwt_env() {
    # Keep the project's signing secret and anon key stable. The service key
    # is intentionally rotated on each init; the database password is fixed.
    if [[ -f "${ENV_FILE}" ]]; then
      PGRST_JWT_SECRET_VALUE="$(sed -n 's/^PGRST_JWT_SECRET=//p' "${ENV_FILE}" | head -n 1)"
      ANON_KEY_VALUE="$(sed -n 's/^ANON_KEY=//p' "${ENV_FILE}" | head -n 1)"
    fi

    local exp="2147483646"
    if [[ -z "${PGRST_JWT_SECRET_VALUE}" || -z "${ANON_KEY_VALUE}" ]]; then
      PGRST_JWT_SECRET_VALUE="$(openssl rand -base64 48 | tr -d '\n')"
      local anon_payload="{\"iss\":\"supabase\",\"role\":\"anon\",\"exp\":${exp}}"
      ANON_KEY_VALUE="$(jwt_sign "$anon_payload" "$PGRST_JWT_SECRET_VALUE")"
    fi

    local service_jti service_payload
    service_jti="$(openssl rand -hex 16)"
    service_payload="{\"iss\":\"supabase\",\"role\":\"service_role\",\"exp\":${exp},\"jti\":\"${service_jti}\"}"
    SERVICE_KEY_VALUE="$(jwt_sign "$service_payload" "$PGRST_JWT_SECRET_VALUE")"

    cat > "${ENV_FILE}" <<ENVEOF
PGRST_JWT_SECRET=${PGRST_JWT_SECRET_VALUE}
ANON_KEY=${ANON_KEY_VALUE}
SERVICE_KEY=${SERVICE_KEY_VALUE}
ADMIN_PASSWORD=${ADMIN_PASSWORD_VALUE}
ENVEOF
    chmod 600 "${ENV_FILE}"
    echo "Secrets generated and written to: ${ENV_FILE}"
  }

  # Container names are stable across the legacy `<name>` and current
  # `<name>_supabase` project directories. Stop old containers now; the
  # project's named volumes are removed below before PostgreSQL starts so
  # the fixed bootstrap password is applied to a fresh database every init.
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${STORAGE_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${KONG_CONTAINER}" >/dev/null 2>&1 || true
  rm -f "${COMPOSE_FILE}"

  generate_kong_config() {
    mkdir -p "${KONG_DIR}"
    cat > "${KONG_DIR}/kong.yml" <<EOF
_format_version: "3.0"
services:
  - name: storage-service
    url: http://${SERVICE_STORAGE}:5000
    routes:
      - name: storage-route
        paths:
          - /storage/v1
          - /storage/v1/
        strip_path: true
EOF
  }

  generate_compose() {
    cat <<EOF
services:
  ${SERVICE_DB}:
    image: supabase/postgres:15.14.1.096
    container_name: ${CONTAINER_NAME}
    restart: always
    environment:
      POSTGRES_USER: supabase_admin
      POSTGRES_PASSWORD: \${ADMIN_PASSWORD}
      POSTGRES_DB: postgres
    ports:
      - "${PORT}:5432"
    volumes:
      - ${VOLUME_DB}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  ${SERVICE_STORAGE}:
    image: supabase/storage-api:latest
    container_name: ${NAME}_supabase_storage
    depends_on:
      ${SERVICE_DB}:
        condition: service_healthy
    environment:
      PGRST_JWT_SECRET: \${PGRST_JWT_SECRET}
      ANON_KEY: \${ANON_KEY}
      SERVICE_KEY: \${SERVICE_KEY}
      DATABASE_URL: postgres://supabase_storage_admin:\${ADMIN_PASSWORD}@${SERVICE_DB}:5432/postgres
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: ${NAME}
      REGION: local
      GLOBAL_S3_BUCKET: storage
    volumes:
      - ${VOLUME_STORAGE}:/var/lib/storage
    ports:
      - "${STORAGE_PORT}:5000"

  kong:
    image: kong:3.7
    container_name: ${NAME}_supabase_kong
    restart: always
    environment:
      KONG_DATABASE: off
      KONG_DECLARATIVE_CONFIG: /usr/local/kong/declarative/kong.yml
      KONG_PROXY_LISTEN: 0.0.0.0:${KONG_PORT}
    depends_on:
      ${SERVICE_STORAGE}:
        condition: service_started
    ports:
      - "${KONG_PORT}:${KONG_PORT}"
    volumes:
      - ./kong:/usr/local/kong/declarative:ro

volumes:
  ${VOLUME_DB}:
  ${VOLUME_STORAGE}:
EOF
  }

  mkdir -p "${TARGET_DIR}/migrations/init"

  generate_jwt_env
  # Docker Compose gives exported shell variables precedence over .env. Set
  # this explicitly so every interpolated password comes from our validated
  # project credential, even if the invoking shell had a stale value.
  export ADMIN_PASSWORD="${ADMIN_PASSWORD_VALUE}"
  generate_kong_config

  if [[ ! -f "${TARGET_DIR}/migrations/init/01_custom_schema.sql" ]]; then
    cat > "${TARGET_DIR}/migrations/init/01_custom_schema.sql" <<'SQLEOF'
SELECT 1;
SQLEOF
  fi

  generate_compose > "${COMPOSE_FILE}"
  echo "docker-compose file written: ${COMPOSE_FILE}"

  if [[ "$NO_START" != true ]]; then
    echo "Removing previous project containers and database/storage volumes..."
    if command -v docker compose &> /dev/null; then
      docker compose -p "${NAME}" -f "${COMPOSE_FILE}" down --volumes --remove-orphans
    else
      docker-compose -p "${NAME}" -f "${COMPOSE_FILE}" down --volumes --remove-orphans
    fi
  fi

  if [[ "$NO_START" == true ]]; then
    echo "No-start mode enabled. Files generated in ${PROJECT_DIR}."
    echo ""
    echo "SERVICE_KEY (Kong): ${SERVICE_KEY_VALUE}"
    exit 0
  fi

  echo "Starting PostgreSQL..."
  if command -v docker compose &> /dev/null; then
    docker compose -p "${NAME}" -f "${COMPOSE_FILE}" up -d --remove-orphans "${SERVICE_DB}"
  else
    docker-compose -p "${NAME}" -f "${COMPOSE_FILE}" up -d --remove-orphans "${SERVICE_DB}"
  fi

  echo "Waiting for PostgreSQL to be ready..."
  POSTGRES_READY=false
  for i in {1..30}; do
    if docker exec "${CONTAINER_NAME}" pg_isready -U postgres -q 2>/dev/null; then
      POSTGRES_READY=true
      break
    fi
    sleep 1
  done

  if [[ "${POSTGRES_READY}" != true ]]; then
    echo "Error: PostgreSQL did not become ready. Check its logs with: docker logs ${CONTAINER_NAME}"
    exit 1
  fi

  # POSTGRES_USER is the bootstrap superuser in supabase/postgres. The
  # application role `postgres` is intentionally not a superuser, so use
  # supabase_admin to synchronize its password on both new and existing data.
  if ! [[ "${ADMIN_PASSWORD_VALUE}" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "Error: ADMIN_PASSWORD in ${ENV_FILE} contains unsupported characters. Use a newly generated alphanumeric password."
    exit 1
  fi
  echo "Synchronizing PostgreSQL password with ${ENV_FILE}..."
  sync_database_password() {
    local current_admin_password="$1"
    docker exec -e "PGPASSWORD=${current_admin_password}" "${CONTAINER_NAME}" \
      psql -w -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
      -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN CREATE ROLE supabase_storage_admin WITH LOGIN NOINHERIT CREATEROLE; END IF; IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS; END IF; END \$\$; ALTER ROLE postgres WITH PASSWORD '${ADMIN_PASSWORD_VALUE}'; ALTER ROLE supabase_admin WITH PASSWORD '${ADMIN_PASSWORD_VALUE}'; ALTER ROLE supabase_storage_admin WITH PASSWORD '${ADMIN_PASSWORD_VALUE}'; ALTER ROLE service_role WITH BYPASSRLS; GRANT CREATE ON DATABASE postgres TO supabase_storage_admin; DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'storage') THEN CREATE SCHEMA storage AUTHORIZATION supabase_admin; END IF; GRANT ALL ON SCHEMA storage TO supabase_storage_admin WITH GRANT OPTION; GRANT USAGE ON SCHEMA storage TO postgres, anon, authenticated, service_role; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storage TO postgres, anon, authenticated, service_role; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA storage TO postgres, anon, authenticated, service_role; GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA storage TO postgres, anon, authenticated, service_role; END \$\$; ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role; ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role; ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;" >/dev/null
  }
  sync_database_password_with_local_recovery() {
    docker exec -i -u postgres -e "NEW_ADMIN_PASSWORD=${ADMIN_PASSWORD_VALUE}" "${CONTAINER_NAME}" sh -s <<'RECOVERY_EOF'
set -eu
case "${NEW_ADMIN_PASSWORD}" in
  ''|*[!a-zA-Z0-9]*) echo "Invalid recovery password" >&2; exit 2 ;;
esac

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
HBA_FILE="$(postgres -D "${PGDATA}" -C hba_file)"
BACKUP_FILE="$(mktemp)"
cp -p "${HBA_FILE}" "${BACKUP_FILE}"

restore_hba() {
  if [ -f "${BACKUP_FILE}" ]; then
    cat "${BACKUP_FILE}" > "${HBA_FILE}"
    rm -f "${BACKUP_FILE}"
    pg_ctl -D "${PGDATA}" reload >/dev/null 2>&1 || true
  fi
}
trap restore_hba EXIT HUP INT TERM

TEMP_HBA="${HBA_FILE}.tmp.$$"
{ printf '%s\n' 'local all all trust'; cat "${BACKUP_FILE}"; } > "${TEMP_HBA}"
cat "${TEMP_HBA}" > "${HBA_FILE}"
rm -f "${TEMP_HBA}"
pg_ctl -D "${PGDATA}" reload >/dev/null
psql -w -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN CREATE ROLE supabase_storage_admin WITH LOGIN NOINHERIT CREATEROLE; END IF; IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS; END IF; END \$\$; ALTER ROLE postgres WITH PASSWORD '${NEW_ADMIN_PASSWORD}'; ALTER ROLE supabase_admin WITH PASSWORD '${NEW_ADMIN_PASSWORD}'; ALTER ROLE supabase_storage_admin WITH PASSWORD '${NEW_ADMIN_PASSWORD}'; ALTER ROLE service_role WITH BYPASSRLS; GRANT CREATE ON DATABASE postgres TO supabase_storage_admin; DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'storage') THEN CREATE SCHEMA storage AUTHORIZATION supabase_admin; END IF; GRANT ALL ON SCHEMA storage TO supabase_storage_admin WITH GRANT OPTION; GRANT USAGE ON SCHEMA storage TO postgres, anon, authenticated, service_role; GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storage TO postgres, anon, authenticated, service_role; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA storage TO postgres, anon, authenticated, service_role; GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA storage TO postgres, anon, authenticated, service_role; END \$\$; ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role; ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role; ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;" >/dev/null
RECOVERY_EOF
  }
  if ! sync_database_password "${ADMIN_PASSWORD_VALUE}"; then
    if [[ -n "${LEGACY_ADMIN_PASSWORD_VALUE}" && "${LEGACY_ADMIN_PASSWORD_VALUE}" =~ ^[a-zA-Z0-9]+$ ]] && \
      sync_database_password "${LEGACY_ADMIN_PASSWORD_VALUE}"; then
      echo "Existing database administrator password migrated to the fixed password."
    elif sync_database_password_with_local_recovery; then
      echo "Database passwords recovered locally and set to the fixed password."
    else
      echo "Error: Could not recover PostgreSQL administrator access. Check the postgres container logs and data directory permissions."
      exit 1
    fi
  fi

  if [[ -d "${TARGET_DIR}/migrations/init" ]]; then
    for f in "${TARGET_DIR}"/migrations/init/*.sql; do
      [[ -f "$f" ]] || continue
      docker exec -i "${CONTAINER_NAME}" psql -q -U postgres -d postgres -f - < "$f" >/dev/null 2>&1 || true
    done
  fi

  echo "Starting all services..."
  if command -v docker compose &> /dev/null; then
    docker compose -p "${NAME}" -f "${COMPOSE_FILE}" up -d --remove-orphans
  else
    docker-compose -p "${NAME}" -f "${COMPOSE_FILE}" up -d --remove-orphans
  fi

  echo ""
  echo "Supabase successfully initialized in directory: ${PROJECT_DIR}"
  echo "  Postgres       : localhost:${PORT}"
  echo "  Storage        : http://localhost:${STORAGE_PORT}"
  echo "  Kong           : http://localhost:${KONG_PORT}"
  echo ""
  echo "SERVICE_KEY (Kong): ${SERVICE_KEY_VALUE}"
  exit 0
else
  echo "Unknown or missing command: $SUBCOMMAND"
  usage
fi
