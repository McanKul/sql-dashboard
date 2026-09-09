#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$project_dir"

dashboard_domain="${DASHBOARD_DOMAIN:-}"
acme_email="${ACME_EMAIL:-}"
basic_auth_user="${DASHBOARD_BASIC_AUTH_USER:-admin}"
compose_project_name="${COMPOSE_PROJECT_NAME:-postgresql-advisor}"
credentials_path="${CREDENTIALS_PATH:-${HOME}/.postgresql-advisor-credentials}"

if [[ -z "$dashboard_domain" || -z "$acme_email" ]]; then
  printf 'DASHBOARD_DOMAIN and ACME_EMAIL are required\n' >&2
  printf 'usage: DASHBOARD_DOMAIN=dashboard.example.com ACME_EMAIL=ops@example.com %s\n' \
    "${BASH_SOURCE[0]}" >&2
  printf 'optional: DASHBOARD_BASIC_AUTH_USER, COMPOSE_PROJECT_NAME, CREDENTIALS_PATH\n' >&2
  exit 1
fi

if [[ -e .env ]]; then
  printf 'Refusing to overwrite existing %s/.env\n' "$project_dir" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required\n' >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required\n' >&2
  exit 1
}

# Checked before .env is written: failing later would leave an .env that the
# guard above refuses to regenerate, losing the admin token permanently.
credentials_dir="$(dirname -- "$credentials_path")"
if [[ ! -d "$credentials_dir" || ! -w "$credentials_dir" ]]; then
  printf 'credentials directory %s must exist and be writable\n' "$credentials_dir" >&2
  exit 1
fi

umask 077

random_hex() {
  openssl rand -hex 32
}

basic_auth_password="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-')"
# Must satisfy BEARER_TOKEN_PATTERN in backend/app/security.py, which is
# fullmatched before any hash comparison.
admin_token="adv_pat_v1_$(openssl rand -base64 32 | tr -d '\n=' | tr '/+' '_-' | cut -c1-43)"
if [[ ! "$admin_token" =~ ^adv_pat_v1_[A-Za-z0-9_-]{43}$ ]]; then
  printf 'generated admin token does not match the API bearer format\n' >&2
  exit 1
fi
admin_token_sha256="$(printf '%s' "$admin_token" | openssl dgst -sha256 -r | awk '{print $1}')"
basic_auth_hash="$(
  printf '%s\n' "$basic_auth_password" |
    docker run --rm -i caddy:2.10.2-alpine \
      caddy hash-password
)"
principal_json="$(
  printf '[{"credential_id":"prod-admin","subject":"production-admin","token_sha256":"%s","roles":["analyst","annotator","admin"]}]' \
    "$admin_token_sha256"
)"

{
  printf 'COMPOSE_PROJECT_NAME=%s\n' "$compose_project_name"
  printf 'COMPOSE_FILE=compose.yaml:compose.production.yaml\n'
  printf 'DASHBOARD_DOMAIN=%s\n' "$dashboard_domain"
  printf 'ACME_EMAIL=%s\n' "$acme_email"
  printf 'POSTGRES_ADMIN_PASSWORD=%s\n' "$(random_hex)"
  printf 'POWA_COLLECTOR_PASSWORD=%s\n' "$(random_hex)"
  printf 'ADVISOR_API_PASSWORD=%s\n' "$(random_hex)"
  printf 'ADVISOR_EVALUATOR_PASSWORD=%s\n' "$(random_hex)"
  printf 'ADVISOR_EVALUATOR_READ_SCHEMAS=public\n'
  printf 'EVALUATOR_TOKEN=%s\n' "$(random_hex)"
  printf 'ADVISOR_JOIN_SOURCE_PASSWORD=%s\n' "$(random_hex)"
  printf 'ADVISOR_JOIN_REPOSITORY_PASSWORD=%s\n' "$(random_hex)"
  printf 'WORKLOAD_DB_PASSWORD=%s\n' "$(random_hex)"
  printf 'CLONE_ADMIN_PASSWORD=%s\n' "$(random_hex)"
  printf 'CLONE_RUNNER_PASSWORD=%s\n' "$(random_hex)"
  printf 'CLONE_EVALUATOR_TOKEN=%s\n' "$(random_hex)"
  printf "ADVISOR_AUTH_PRINCIPALS='%s'\n" "$principal_json"
  printf 'SOURCE_DB_BIND=127.0.0.1\n'
  printf 'SOURCE_DB_PORT=15432\n'
  printf 'REPOSITORY_DB_BIND=127.0.0.1\n'
  printf 'REPOSITORY_DB_PORT=15433\n'
  printf 'API_BIND=127.0.0.1\n'
  printf 'API_PORT=8000\n'
  printf 'WEB_BIND=127.0.0.1\n'
  printf 'WEB_PORT=5173\n'
  printf 'DEFAULT_WINDOW=24h\n'
  printf 'RETENTION_DAYS=90\n'
  printf 'LOG_LEVEL=INFO\n'
  printf 'API_MEMORY_LIMIT=1g\n'
  printf 'QUERY_METRICS_SNAPSHOT_POLL_SECONDS=15\n'
  printf 'QUERY_METRICS_SNAPSHOT_1H_REFRESH_SECONDS=900\n'
  printf 'QUERY_METRICS_SNAPSHOT_24H_REFRESH_SECONDS=3600\n'
  printf 'QUERY_METRICS_SNAPSHOT_7D_REFRESH_SECONDS=21600\n'
  printf 'QUERY_METRICS_SNAPSHOT_30D_REFRESH_SECONDS=43200\n'
  printf 'QUERY_METRICS_SNAPSHOT_STATEMENT_TIMEOUT_SECONDS=1800\n'
  printf 'QUERY_METRICS_SNAPSHOT_RETRY_SECONDS=60\n'
  printf 'QUERY_METRICS_SNAPSHOT_WORKER_MEMORY_LIMIT=256m\n'
  printf 'SOURCE_DB_SHM_SIZE=512mb\n'
  printf 'REPOSITORY_DB_SHM_SIZE=256mb\n'
  printf 'REGISTER_DEMO_SOURCE=false\n'
  printf 'POWA_SOURCE_SSLMODE=prefer\n'
  printf 'DASHBOARD_BASIC_AUTH_USER=%s\n' "$basic_auth_user"
  printf "DASHBOARD_BASIC_AUTH_HASH='%s'\n" "$basic_auth_hash"
} > .env
chmod 0600 .env

{
  printf 'Dashboard URL: https://%s\n' "$dashboard_domain"
  printf 'Dashboard basic-auth user: %s\n' "$basic_auth_user"
  printf 'Dashboard basic-auth password: %s\n' "$basic_auth_password"
  printf 'Advisor API admin bearer token: %s\n' "$admin_token"
} > "$credentials_path"
chmod 0600 "$credentials_path"

docker compose config --quiet
printf 'Created %s/.env and %s\n' "$project_dir" "$credentials_path"
