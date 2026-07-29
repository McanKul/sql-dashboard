#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$project_dir"

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

umask 077

random_hex() {
  openssl rand -hex 32
}

basic_auth_user="trades"
basic_auth_password="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-')"
admin_token="$(openssl rand -base64 32 | tr -d '\n' | tr '/+' '_-')"
admin_token_sha256="$(printf '%s' "$admin_token" | openssl dgst -sha256 -r | awk '{print $1}')"
basic_auth_hash="$(
  printf '%s\n' "$basic_auth_password" |
    docker run --rm -i caddy:2.10.2-alpine \
      caddy hash-password
)"
principal_json="$(
  printf '[{"credential_id":"prod-admin","subject":"trades-engineer-admin","token_sha256":"%s","roles":["analyst","annotator","admin"]}]' \
    "$admin_token_sha256"
)"

{
  printf 'COMPOSE_PROJECT_NAME=trades-engineer\n'
  printf 'COMPOSE_FILE=compose.yaml:compose.production.yaml\n'
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
  printf 'WORKLOAD_PROFILE=erp\n'
  printf 'WORKLOAD_DURATION_SECONDS=7200\n'
  printf 'WORKLOAD_WORKERS=3\n'
  printf 'WORKLOAD_INTERVAL_SECONDS=0.20\n'
  printf 'WORKLOAD_INTERVAL_JITTER_RATIO=0.30\n'
  printf 'WORKLOAD_TRAFFIC_PHASE_SECONDS=45\n'
  printf 'WORKLOAD_TRAFFIC_MIN_INTERVAL_MULTIPLIER=0.90\n'
  printf 'WORKLOAD_TRAFFIC_MAX_INTERVAL_MULTIPLIER=3.00\n'
  printf 'WORKLOAD_STATEMENT_TIMEOUT_MS=30000\n'
  printf 'WORKLOAD_LOCK_TIMEOUT_MS=1000\n'
  printf 'WORKLOAD_LOCK_HOLD_MS=30\n'
  printf 'WORKLOAD_ERP_TABLE_COUNT=500\n'
  printf 'WORKLOAD_ERP_QUERY_VARIANTS_PER_TABLE=8\n'
  printf 'WORKLOAD_ERP_ROWS_PER_TABLE=2000\n'
  printf 'REGISTER_DEMO_SOURCE=true\n'
  printf 'DEMO_SOURCE_FREQUENCY=60\n'
  printf 'POWA_SOURCE_SSLMODE=prefer\n'
  printf 'DASHBOARD_BASIC_AUTH_USER=%s\n' "$basic_auth_user"
  printf "DASHBOARD_BASIC_AUTH_HASH='%s'\n" "$basic_auth_hash"
} > .env
chmod 0600 .env

credentials_path="${1:-/home/deploy/.trades-engineer-credentials}"
{
  printf 'Dashboard URL: https://trades.engineer\n'
  printf 'Dashboard basic-auth user: %s\n' "$basic_auth_user"
  printf 'Dashboard basic-auth password: %s\n' "$basic_auth_password"
  printf 'Advisor API admin bearer token: %s\n' "$admin_token"
} > "$credentials_path"
chmod 0600 "$credentials_path"

docker compose --profile realistic-load config --quiet
printf 'Created %s/.env and %s\n' "$project_dir" "$credentials_path"
