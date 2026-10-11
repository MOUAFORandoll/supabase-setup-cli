#!/usr/bin/env bash
set -euo pipefail

# Le dossier de base où l'utilisateur exécute la commande
BASE_DIR="$(pwd)"

usage() {
  echo "Usage: supabase-init-cli --name <name> --port <port> --storage-port <port> [--kong-port <port>] [--no-start]"
  echo ""
  echo "Options:"
  echo "  --name         Nom du projet (crée un dossier du même nom et initialise les fichiers dedans)"
  echo "  --port         Port exposé pour PostgreSQL (ex: 5432)"
  echo "  --storage-port Port exposé pour l'API Storage (ex: 5000)"
  echo "  --kong-port    Port exposé pour Kong (ex: 3030)"
  echo "  --no-start     Génère uniquement le docker-compose sans lancer les containers"
  exit 1
}

# --- ÉTAPE : Vérification de Docker & Docker Compose ---
check_docker_dependencies() {
  local missing=false

  if ! command -v docker &> /dev/null; then
    missing=true
  fi

  if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
    missing=true
  fi

  if [[ "$missing" == true ]]; then
    echo "⚠️  Attention : Docker ou Docker Compose ne semble pas être installé sur votre système."
    echo ""
    read -rp "Voulez-vous continuer quand même (génération des fichiers sans démarrage) ? (y/N) " response
    case "$response" in
      [yY][eE][sS]|[yY])
        echo "Poursuite de la génération des fichiers (option --no-start activée implicitement)..."
        NO_START=true
        ;;
      *)
        echo "Abandon. Veuillez installer Docker et Docker Compose pour lancer Supabase."
        exit 1
        ;;
    esac
  fi
}

NAME=""
PORT=""
STORAGE_PORT=""
KONG_PORT="3030"
NO_START=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --storage-port) STORAGE_PORT="$2"; shift 2 ;;
    --kong-port) KONG_PORT="$2"; shift 2 ;;
    --no-start) NO_START=true; shift ;;
    -h|--help) usage ;;
    *) echo "Option inconnue: $1"; usage ;;
  esac
done

if [[ -z "$NAME" ]] || [[ -z "$PORT" ]] || [[ -z "$STORAGE_PORT" ]]; then
  echo "Erreur: --name, --port et --storage-port sont requis."
  usage
fi

check_docker_dependencies

if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Erreur: le nom doit contenir uniquement lettres, chiffres, tirets et underscores."
  exit 1
fi

PROJECT_DIR="${BASE_DIR}/${NAME}"
echo "Création du dossier du projet : ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

TARGET_DIR="$(pwd)"
COMPOSE_FILE="${TARGET_DIR}/docker-compose.yml"
ENV_FILE="${TARGET_DIR}/.env"
KONG_DIR="${TARGET_DIR}/kong"

CONTAINER_NAME="${NAME}_superbase"
SERVICE_DB="${NAME}-db"
SERVICE_STORAGE="${NAME}-storage"
VOLUME_DB="${NAME}_db_data"
VOLUME_STORAGE="${NAME}_storage_data"
STORAGE_CONTAINER="${NAME}_superbase_storage"
KONG_CONTAINER="${NAME}_superbase_kong"

jwt_sign() {
  local payload="$1"
  local secret="$2"
  local header='{"alg":"HS256","typ":"JWT"}'
  base64_url() { base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
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
ADMIN_PASSWORD_VALUE=""

generate_jwt_env() {
  local secret
  secret=$(openssl rand -base64 48 | tr -d '\n')
  local exp="2147483646"
  local anon_payload="{\"iss\":\"supabase\",\"role\":\"anon\",\"exp\":${exp}}"
  local service_payload="{\"iss\":\"supabase\",\"role\":\"service_role\",\"exp\":${exp}}"
  local anon_key service_key
  anon_key=$(jwt_sign "$anon_payload" "$secret")
  service_key=$(jwt_sign "$service_payload" "$secret")

  local admin_pwd
  admin_pwd=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 24)

  PGRST_JWT_SECRET_VALUE="$secret"
  ANON_KEY_VALUE="$anon_key"
  SERVICE_KEY_VALUE="$service_key"
  ADMIN_PASSWORD_VALUE="$admin_pwd"

  cat > "${ENV_FILE}" << ENVEOF
PGRST_JWT_SECRET=${secret}
ANON_KEY=${anon_key}
SERVICE_KEY=${service_key}
ADMIN_PASSWORD=${admin_pwd}
ENVEOF
  echo "Secrets générés et écrits dans: ${ENV_FILE}"
}

# Nettoyage des anciens conteneurs liés au projet
if [[ -f "${COMPOSE_FILE}" ]]; then
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${STORAGE_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${KONG_CONTAINER}" >/dev/null 2>&1 || true
fi
rm -f "${COMPOSE_FILE}"

generate_kong_config() {
  mkdir -p "${KONG_DIR}"
  cat > "${KONG_DIR}/kong.yml" << EOF
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
  cat << EOF
services:
  ${SERVICE_DB}:
    image: supabase/postgres:15.14.1.096
    container_name: ${CONTAINER_NAME}
    restart: always
    environment:
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
    container_name: ${NAME}_superbase_storage
    depends_on:
      ${SERVICE_DB}:
        condition: service_healthy
    environment:
      PGRST_JWT_SECRET: \${PGRST_JWT_SECRET}
      ANON_KEY: \${ANON_KEY}
      SERVICE_KEY: \${SERVICE_KEY}
      DATABASE_URL: postgres://supabase_admin:\${ADMIN_PASSWORD}@${SERVICE_DB}:5432/postgres
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
    container_name: ${NAME}_superbase_kong
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

# Génération des secrets dynamiques uniques à chaque exécution
generate_jwt_env

generate_kong_config

if [[ ! -f "${TARGET_DIR}/migrations/init/01_custom_schema.sql" ]]; then
  cat > "${TARGET_DIR}/migrations/init/01_custom_schema.sql" << 'SQLEOF'
SELECT 1;
SQLEOF
fi

generate_compose > "${COMPOSE_FILE}"
echo "Fichier écrit: ${COMPOSE_FILE}"

if [[ "$NO_START" == true ]]; then
  echo "Mode sans démarrage activé. Fichiers générés dans ${PROJECT_DIR}."
  echo ""
  echo "Voici vos clés dynamiques générées pour ce projet :"
  echo "  PGRST_JWT_SECRET : $PGRST_JWT_SECRET_VALUE"
  echo "  ANON_KEY         : $ANON_KEY_VALUE"
  echo "  SERVICE_KEY      : $SERVICE_KEY_VALUE"
  echo "  ADMIN_PASSWORD   : $ADMIN_PASSWORD_VALUE"
  exit 0
fi

echo "Démarrage de PostgreSQL..."
docker compose -p "${NAME}" -f "${COMPOSE_FILE}" up -d --remove-orphans "${SERVICE_DB}"

echo "Attente du démarrage de PostgreSQL..."
for i in {1..30}; do
  if docker exec "${CONTAINER_NAME}" pg_isready -U postgres -q 2>/dev/null; then
    break
  fi
  sleep 1
done

if [[ -d "${TARGET_DIR}/migrations/init" ]]; then
  for f in "${TARGET_DIR}"/migrations/init/*.sql; do
    [[ -f "$f" ]] || continue
    docker exec -i "${CONTAINER_NAME}" psql -q -U postgres -d postgres -f - < "$f" >/dev/null 2>&1 || true
  done
fi

echo "Démarrage complet des services..."
docker compose -p "${NAME}" -f "${COMPOSE_FILE}" up -d --remove-orphans

echo ""
echo "Supabase initialisé avec succès dans le dossier : ${PROJECT_DIR}"
echo "  Postgres       : localhost:${PORT}"
echo "  Storage        : http://localhost:${STORAGE_PORT}"
echo "  Kong           : http://localhost:${KONG_PORT}"
echo ""
echo "Voici vos clés dynamiques générées pour ce projet :"
echo "  PGRST_JWT_SECRET : $PGRST_JWT_SECRET_VALUE"
echo "  ANON_KEY         : $ANON_KEY_VALUE"
echo "  SERVICE_KEY      : $SERVICE_KEY_VALUE"
echo "  ADMIN_PASSWORD   : $ADMIN_PASSWORD_VALUE"
