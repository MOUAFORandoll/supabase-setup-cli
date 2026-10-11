# supabase-setup-cli

> Initialisez facilement une stack Supabase locale complète, alimentée par Docker.

[![npm version](https://img.shields.io/npm/v/supabase-setup-cli.svg)](https://www.npmjs.com/package/supabase-setup-cli)

## Présentation

`s‍upabase-setup-cli` est un CLI global qui génère et lance une instance Supabase locale (PostgreSQL, Storage API, proxy Kong) via Docker Compose. Il crée tous les fichiers de config, secrets et variables d’environnement nécessaires, et prend en charge les installations projet-par-projet.

## Prérequis

- [Docker](https://www.docker.com/get-started) & Docker Compose
- Bash (Linux/macOS/WSL – non compatible avec les shells Windows natifs)

## Installation

```sh
npm install -g supabase-setup-cli
```

## Utilisation du CLI

Exécutez le CLI depuis le dossier de votre choix :

```sh
supabase-setup-cli name=<nom_projet> port=<port_postgres> storage-port=<port_storage> [kong-port=<port_kong>] [no-start]
```

### Paramètres

| Option            | Description                                                                 | Exemple  |
|-------------------|-----------------------------------------------------------------------------|----------|
| `name`            | Nom du projet (dossier créé, tous les fichiers générés à l’intérieur)        | `myapp`  |
| `port`            | Port exposé pour PostgreSQL                                                  | `15432`  |
| `storage-port`    | Port exposé pour l’API Storage                                               | `5040`   |
| `kong-port`       | (Optionnel) Port exposé pour Kong (défaut : `3030`)                          | `5555`   |
| `no-start`        | (Optionnel) Générer uniquement les fichiers, _sans_ démarrer les containers  |          |

### Exemples

```sh
# Générer et lancer Postgres (15432), Storage API (5040), Kong (3030)
supabase-setup-cli name=myapp port=15432 storage-port=5040

# Spécifier un port Kong personnalisé et générer les fichiers sans démarrer les services
supabase-setup-cli name=myapp port=15432 storage-port=5040 kong-port=5555 no-start
```

## Arborescence du projet

Le CLI crée un dossier `<nom>` contenant :

- `docker-compose.yml` — La config Compose (DB, Storage, Kong)
- `.env` — Les credentials et JWTs générés dynamiquement
- `kong/` — Config déclarative pour Kong
- `migrations/init/` — Placez ici vos fichiers de migration SQL
  - `01_custom_schema.sql` — Exemple de fichier de schéma custom

## Après l’initialisation

- **PostgreSQL** : `localhost:<port>` (`postgres`/`<mot_de_passe_admin_généré>`, base : `postgres`)
- **Connection string** : `postgres://postgres:<motdepasse>@localhost:<port>/postgres`
- **Storage API (direct)** : `http://localhost:<storage-port>`
- **Storage API (via Kong)** : `http://localhost:<kong-port>/storage/v1`
- **SERVICE_KEY** : Affichée à la fin du script et présente dans `.env`
- **Secrets JWT** : `PGRST_JWT_SECRET`, `ANON_KEY`, `SERVICE_KEY` sont générés pour chaque projet, stockés dans `.env`.

## Gestion des services

Depuis le dossier projet :

```sh
# Lancer les containers s’ils ne tournent pas déjà
docker compose up -d

# Arrêter les containers
docker compose down

# Consulter les logs
docker compose logs -f
```

Le CLI fournit aussi des raccourcis :

```sh
supabase-setup-cli down     # Arrêter et supprimer tous les containers du projet
supabase-setup-cli logs     # Suivre les logs des containers
```

## Migrations

Tous les fichiers SQL présents dans `migrations/init/*.sql` sont appliqués par ordre alphabétique après le démarrage de la base de données.
Modifiez `migrations/init/01_custom_schema.sql` ou ajoutez vos propres fichiers `.sql` pour vos schémas, tables etc.

## Environnement & Secrets

- Le script crée `.env` s’il n’existe pas, contenant tous les secrets et JWT nécessaires.
- Pour régénérer des secrets : supprimez `.env` et relancez le CLI.
- **Ne commitez JAMAIS `.env` dans votre VCS** (le fichier est ajouté par défaut dans `.gitignore`).

## Exemple : Créer un bucket Storage

Utilisez la `SERVICE_KEY` générée pour créer un bucket public via Kong :

```sh
SERVICE_KEY="<clé affichée à l'init>"

curl -X POST "http://localhost:<kong-port>/storage/v1/bucket" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"name": "avatars", "public": true, "allowedMimeTypes": ["image/*"], "fileSizeLimit": "1048576"}'
```

Vous pouvez aussi appeler l’API storage directement sur `http://localhost:<storage-port>/bucket`.

## Sécurité

- Gardez `.env` secret et ne le commitez pas.
- En production, révisez les credentials ; adaptez pour des usages distants.
- Voir la [documentation Supabase self-hosting](https://supabase.com/docs/guides/self-hosting/docker) pour plus de consignes et choix de configuration.
