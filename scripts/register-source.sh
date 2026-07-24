#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Kullanim:
  scripts/register-source.sh --env-file /secure/source.env
  scripts/register-source.sh --alias prod --host db.internal --password-file /secure/collector.pass [secenekler]

Zorunlu:
  --alias NAME                 Dashboard/PoWA icindeki benzersiz kaynak adi
  --host HOST                 Collector container'inin erisebildigi DNS/IP

Baglanti:
  --port PORT                 Varsayilan: 5432
  --database DB               Dedicated PoWA monitoring DB; varsayilan: powa
  --user USER                 Collector rolu; varsayilan: powa_collector
  --password-file FILE        Onerilen parola girisi (dosya 0600 olmali)
  --password-stdin            Collector parolasini stdin'in ilk satirindan oku

PoWA:
  --frequency SECONDS         Snapshot araligi; varsayilan: 60, minimum: 5
  --coalesce COUNT            Arsiv birlestirme araligi; varsayilan: 100, minimum: 5
  --retention INTERVAL        PostgreSQL interval; varsayilan: "90 days"
  pg_qualstats               Iterasyon 2.1-B'de tum kayitlarda zorunlu datasource

Kaynak hazirlama (opsiyonel):
  --prepare                   Monitoring DB, rol, extension ve grant'lari uygula
  --admin-user USER           Varsayilan: postgres
  --admin-database DB         Varsayilan: postgres
  --admin-password-file FILE  Kaynak DBA parola dosyasi

Diger:
  --env-file FILE             config/source.env.example biciminde config
  --skip-snapshot-wait        Kaydi yap/restart et ama ilk snapshot'i bekleme
  -h, --help                  Bu yardim

Oncelik: CLI bayragi > mevcut environment > --env-file > varsayilan.
Parolalar repository'deki PoWA.powa_servers tablosuna yazilmaz.
EOF
}

fail() {
  printf '[HATA] %s\n' "$1" >&2
  exit 1
}

info() {
  printf '[OK] %s\n' "$1"
}

warn() {
  printf '[UYARI] %s\n' "$1" >&2
}

config_file=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--env-file" ]]; then
    ((i + 1 < ${#args[@]})) || fail "--env-file bir dosya bekliyor"
    config_file="${args[$((i + 1))]}"
  fi
done

if [[ -n "$config_file" ]]; then
  [[ -r "$config_file" ]] || fail "Config okunamiyor: ${config_file}"
  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_line="${config_line%$'\r'}"
    [[ -z "$config_line" || "$config_line" == \#* ]] && continue
    [[ "$config_line" == *=* ]] || fail "Gecersiz config satiri: ${config_line}"
    config_key="${config_line%%=*}"
    config_value="${config_line#*=}"
    case "$config_key" in
      SOURCE_ALIAS|SOURCE_HOST|SOURCE_PORT|SOURCE_MONITORING_DB|SOURCE_COLLECTOR_USER|SOURCE_PASSWORD_FILE|SOURCE_FREQUENCY|SOURCE_COALESCE|SOURCE_RETENTION|PREPARE_SOURCE|SOURCE_ADMIN_USER|SOURCE_ADMIN_DB|SOURCE_ADMIN_PASSWORD_FILE)
        if [[ -z "${!config_key+x}" ]]; then
          printf -v "$config_key" '%s' "$config_value"
        fi
        ;;
      *) fail "Config'de bilinmeyen anahtar: ${config_key}" ;;
    esac
  done < "$config_file"
fi

source_alias="${SOURCE_ALIAS:-}"
source_host="${SOURCE_HOST:-}"
source_port="${SOURCE_PORT:-5432}"
monitoring_db="${SOURCE_MONITORING_DB:-powa}"
collector_user="${SOURCE_COLLECTOR_USER:-powa_collector}"
password_file="${SOURCE_PASSWORD_FILE:-}"
source_password="${SOURCE_PASSWORD:-}"
frequency="${SOURCE_FREQUENCY:-60}"
coalesce="${SOURCE_COALESCE:-100}"
retention="${SOURCE_RETENTION:-90 days}"
prepare_source="${PREPARE_SOURCE:-false}"
admin_user="${SOURCE_ADMIN_USER:-postgres}"
admin_db="${SOURCE_ADMIN_DB:-postgres}"
admin_password_file="${SOURCE_ADMIN_PASSWORD_FILE:-}"
admin_password="${SOURCE_ADMIN_PASSWORD:-}"
password_stdin=false
skip_snapshot_wait=false

while (($#)); do
  case "$1" in
    --env-file) shift 2 ;;
    --alias) source_alias="${2:?--alias degeri eksik}"; shift 2 ;;
    --host) source_host="${2:?--host degeri eksik}"; shift 2 ;;
    --port) source_port="${2:?--port degeri eksik}"; shift 2 ;;
    --database) monitoring_db="${2:?--database degeri eksik}"; shift 2 ;;
    --user) collector_user="${2:?--user degeri eksik}"; shift 2 ;;
    --password-file) password_file="${2:?--password-file degeri eksik}"; shift 2 ;;
    --password-stdin) password_stdin=true; shift ;;
    --frequency) frequency="${2:?--frequency degeri eksik}"; shift 2 ;;
    --coalesce) coalesce="${2:?--coalesce degeri eksik}"; shift 2 ;;
    --retention) retention="${2:?--retention degeri eksik}"; shift 2 ;;
    --prepare) prepare_source=true; shift ;;
    --admin-user) admin_user="${2:?--admin-user degeri eksik}"; shift 2 ;;
    --admin-database) admin_db="${2:?--admin-database degeri eksik}"; shift 2 ;;
    --admin-password-file) admin_password_file="${2:?--admin-password-file degeri eksik}"; shift 2 ;;
    --skip-snapshot-wait) skip_snapshot_wait=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Bilinmeyen arguman: $1" ;;
  esac
done

[[ -n "$source_alias" ]] || fail "--alias veya SOURCE_ALIAS zorunlu"
[[ -n "$source_host" ]] || fail "--host veya SOURCE_HOST zorunlu"
[[ "$source_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Alias yalniz harf, rakam, nokta, _ ve - icerebilir"
[[ ! "$source_host" =~ [$'\r\n'] ]] || fail "Host satir sonu iceremez"
[[ "$source_port" =~ ^[0-9]+$ ]] && ((source_port >= 1 && source_port <= 65535)) || fail "Port 1-65535 olmali"
[[ "$frequency" =~ ^[0-9]+$ ]] && ((frequency >= 5)) || fail "Frequency en az 5 saniye olmali"
[[ "$coalesce" =~ ^[0-9]+$ ]] && ((coalesce >= 5)) || fail "Coalesce en az 5 olmali"
[[ "$monitoring_db" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Monitoring DB guvenli PostgreSQL identifier biciminde olmali"
[[ "$collector_user" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Collector user guvenli PostgreSQL identifier biciminde olmali"
[[ "$admin_user" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Admin user guvenli PostgreSQL identifier biciminde olmali"
[[ "$admin_db" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Admin DB guvenli PostgreSQL identifier biciminde olmali"

case "$prepare_source" in
  true|TRUE|1|yes|YES) prepare_source=true ;;
  false|FALSE|0|no|NO) prepare_source=false ;;
  *) fail "PREPARE_SOURCE true/false olmali" ;;
esac

if [[ "$password_stdin" == true ]]; then
  IFS= read -r source_password || fail "Collector parolasi stdin'den okunamadi"
elif [[ -n "$password_file" ]]; then
  [[ -f "$password_file" && -r "$password_file" ]] || fail "Collector parola dosyasi okunamiyor: ${password_file}"
  IFS= read -r source_password < "$password_file" || true
elif [[ -z "$source_password" ]]; then
  [[ -r /dev/tty ]] || fail "--password-file, --password-stdin veya SOURCE_PASSWORD gerekli"
  IFS= read -r -s -p "${source_alias} collector parolasi: " source_password < /dev/tty
  printf '\n' >&2
fi

[[ -n "$source_password" ]] || fail "Collector parolasi bos olamaz"
[[ "$source_password" != *$'\n'* && "$source_password" != *$'\r'* ]] || fail "Parola satir sonu iceremez"

if [[ "$prepare_source" == true ]]; then
  if [[ -n "$admin_password_file" ]]; then
    [[ -f "$admin_password_file" && -r "$admin_password_file" ]] || fail "Admin parola dosyasi okunamiyor: ${admin_password_file}"
    IFS= read -r admin_password < "$admin_password_file" || true
  elif [[ -z "$admin_password" ]]; then
    [[ -r /dev/tty ]] || fail "--prepare icin --admin-password-file veya SOURCE_ADMIN_PASSWORD gerekli"
    IFS= read -r -s -p "${source_host} PostgreSQL admin parolasi: " admin_password < /dev/tty
    printf '\n' >&2
  fi
  [[ -n "$admin_password" ]] || fail "Admin parolasi bos olamaz"
  [[ "$admin_password" != *$'\n'* && "$admin_password" != *$'\r'* ]] || fail "Admin parolasi satir sonu iceremez"
fi

case "$source_host" in
  localhost|127.0.0.1|::1)
    fail "Collector container'i icin ${source_host} kendi container'idir. Host DB icin host.docker.internal veya erisilebilir DNS/IP kullanin."
    ;;
esac

docker compose config --quiet
docker compose ps --services --status running | grep -qx repository-db || fail "repository-db calismiyor; once docker compose up -d repository-db collector calistirin"
docker compose ps --services --status running | grep -qx collector || fail "collector calismiyor; once docker compose up -d collector calistirin"

escape_pgpass() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//:/\\:}"
  printf '%s' "$value"
}

secret_dir="runtime/collector/sources"
secret_path="${secret_dir}/${source_alias}.pgpass"
mkdir -p "$secret_dir"
chmod 0700 runtime/collector "$secret_dir" 2>/dev/null || true
tmp_secret="$(mktemp "${secret_path}.tmp.XXXXXX")"
trap 'rm -f "$tmp_secret"' EXIT
printf '%s:%s:*:%s:%s\n' \
  "$(escape_pgpass "$source_host")" \
  "$(escape_pgpass "$source_port")" \
  "$(escape_pgpass "$collector_user")" \
  "$(escape_pgpass "$source_password")" > "$tmp_secret"
chmod 0600 "$tmp_secret"
mv -f "$tmp_secret" "$secret_path"
trap - EXIT
info "Collector credential Git-disindaki 0600 dosyaya yazildi: ${secret_path}"

if [[ "$prepare_source" == true ]]; then
  # Iki parola stdin ile container'a gider; docker argumanlarina veya repository'ye yazilmaz.
  {
    printf '%s\n' "$admin_password"
    printf '%s\n' "$source_password"
  } | docker compose exec -T repository-db bash -c '
    set -Eeuo pipefail
    IFS= read -r admin_password
    IFS= read -r collector_password
    umask 077
    pgpass="$(mktemp /tmp/advisor-source-admin.XXXXXX)"
    trap '\''rm -f "$pgpass"'\'' EXIT
    escape_pgpass() { local v="$1"; v="${v//\\/\\\\}"; v="${v//:/\\:}"; printf "%s" "$v"; }
    printf "%s:%s:%s:%s:%s\n" \
      "$(escape_pgpass "$1")" "$(escape_pgpass "$2")" "*" \
      "$(escape_pgpass "$3")" "$(escape_pgpass "$admin_password")" > "$pgpass"
    export PGPASSFILE="$pgpass"
    export PGSSLMODE="${POWA_SOURCE_SSLMODE:-prefer}"
    export ADVISOR_SOURCE_COLLECTOR_PASSWORD="$collector_password"
    psql -X --set=ON_ERROR_STOP=1 \
      --host "$1" --port "$2" --username "$3" --dbname "$4" \
      --set=monitoring_db="$5" --set=collector_user="$6" \
      --file /opt/advisor/sql/002_prepare_remote_source.sql
  ' _ "$source_host" "$source_port" "$admin_user" "$admin_db" "$monitoring_db" "$collector_user"
  unset admin_password
  info "Kaynak monitoring DB, collector rolu, extension ve grant'lar hazir"
fi

probe="$({ printf '%s\n' "$source_password"; } | docker compose exec -T repository-db bash -c '
  set -Eeuo pipefail
  IFS= read -r source_password
  umask 077
  pgpass="$(mktemp /tmp/advisor-source-probe.XXXXXX)"
  trap '\''rm -f "$pgpass"'\'' EXIT
  escape_pgpass() { local v="$1"; v="${v//\\/\\\\}"; v="${v//:/\\:}"; printf "%s" "$v"; }
  printf "%s:%s:%s:%s:%s\n" \
    "$(escape_pgpass "$1")" "$(escape_pgpass "$2")" "$(escape_pgpass "$3")" \
    "$(escape_pgpass "$4")" "$(escape_pgpass "$source_password")" > "$pgpass"
  PGPASSFILE="$pgpass" PGSSLMODE="${POWA_SOURCE_SSLMODE:-prefer}" \
    psql -X --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --host "$1" --port "$2" --username "$4" --dbname "$3" --command \
    "SELECT (SELECT extversion FROM pg_extension WHERE extname = '\''powa'\''),
            EXISTS (SELECT 1 FROM pg_extension WHERE extname = '\''pg_stat_statements'\''),
            (SELECT extversion FROM pg_extension WHERE extname = '\''pg_qualstats'\''),
            pg_has_role(current_user, '\''pg_read_all_stats'\'', '\''member'\''),
            pg_has_role(current_user, '\''powa_snapshot'\'', '\''member'\''),
            (SELECT count(*) >= 0 FROM pg_stat_statements),
            (SELECT count(*) >= 0 FROM \"PoWA\".powa_qualstats_src(0)),
            COALESCE((
              SELECT has_function_privilege(
                       current_user,
                       format('\''%I.pg_qualstats_reset()'\'', n.nspname),
                       '\''EXECUTE'\''
                     )
                FROM pg_extension e
                JOIN pg_namespace n ON n.oid = e.extnamespace
               WHERE e.extname = '\''pg_qualstats'\''
            ), false);"
' _ "$source_host" "$source_port" "$monitoring_db" "$collector_user")" || fail "Collector roluyle kaynak preflight basarisiz. --prepare kullanin veya docs/INSTALLATION.md adimlarini uygulayin."

IFS='|' read -r powa_version pgss_ready pgqs_version read_stats snapshot_role pgss_callable pgqs_source_ready pgqs_reset_ready <<< "$probe"
[[ "$powa_version" =~ ^([4-9]|[1-9][0-9]+)\. ]] || fail "Kaynak PoWA 4+ olmali; bulunan: ${powa_version:-yok}"
[[ "$pgss_ready" == t && "$pgqs_version" =~ ^2\.1\. && "$read_stats" == t && "$snapshot_role" == t && "$pgss_callable" == t && "$pgqs_source_ready" == t && "$pgqs_reset_ready" == t ]] \
  || fail "Kaynak preflight eksik: pgss=${pgss_ready}, pg_qualstats=${pgqs_version:-yok}, read_stats=${read_stats}, powa_snapshot=${snapshot_role}, pgss_callable=${pgss_callable}, pgqs_source=${pgqs_source_ready}, pgqs_reset=${pgqs_reset_ready}"
info "Kaynak preflight gecti (PoWA ${powa_version}, pg_qualstats ${pgqs_version})"

repo_psql=(docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 --dbname powa_repository --tuples-only --no-align)
repo_query() {
  local sql="$1"
  shift
  printf '%s\n' "$sql" | "${repo_psql[@]}" "$@"
}

# psql, -c/--command metninde :variable genisletmez; sorgular stdin'den verilir.
alias_id="$(repo_query 'SELECT id FROM "PoWA".powa_servers WHERE alias = :'"'"'source_alias'"'"';' --set=source_alias="$source_alias")"
endpoint_id="$(repo_query 'SELECT id FROM "PoWA".powa_servers WHERE hostname = :'"'"'source_host'"'"' AND port = :'"'"'source_port'"'"'::integer;' --set=source_host="$source_host" --set=source_port="$source_port")"

if [[ -n "$endpoint_id" && -z "$alias_id" ]]; then
  fail "${source_host}:${source_port} baska bir alias ile kayitli (server id ${endpoint_id}); mevcut alias'i kullanin"
fi
if [[ -n "$alias_id" && -n "$endpoint_id" && "$alias_id" != "$endpoint_id" ]]; then
  fail "Alias ve host:port farkli PoWA kayitlarina ait; otomatik birlestirme yapilmadi"
fi

if [[ -n "$alias_id" ]]; then
  previous_snap="$(repo_query 'SELECT snapts FROM "PoWA".powa_snapshot_metas WHERE srvid = :'"'"'server_id'"'"'::integer;' --set=server_id="$alias_id")"
  repo_query 'UPDATE "PoWA".powa_servers
                 SET hostname = :'"'"'source_host'"'"', port = :'"'"'source_port'"'"'::integer,
                     alias = :'"'"'source_alias'"'"', username = :'"'"'collector_user'"'"', password = NULL,
                     dbname = :'"'"'monitoring_db'"'"', frequency = :'"'"'frequency'"'"'::integer,
                     powa_coalesce = :'"'"'coalesce'"'"'::integer, retention = :'"'"'retention'"'"'::interval,
                     allow_ui_connection = false
               WHERE id = :'"'"'server_id'"'"'::integer;' \
    --set=server_id="$alias_id" --set=source_host="$source_host" --set=source_port="$source_port" \
    --set=source_alias="$source_alias" --set=collector_user="$collector_user" --set=monitoring_db="$monitoring_db" \
    --set=frequency="$frequency" --set=coalesce="$coalesce" --set=retention="$retention"
  activation_ok="$(repo_query 'SELECT "PoWA".powa_activate_extension(:'"'"'server_id'"'"'::integer, '"'"'pg_qualstats'"'"');' --set=server_id="$alias_id")"
  [[ "$activation_ok" == t ]] || fail "Mevcut PoWA kaydinda pg_qualstats etkinlestirilemedi"
  server_id="$alias_id"
  info "Mevcut PoWA server id ${server_id} idempotent olarak guncellendi"
else
  previous_snap="-infinity"
  repo_query 'SELECT "PoWA".powa_register_server(
        hostname => :'"'"'source_host'"'"', port => :'"'"'source_port'"'"'::integer,
        alias => :'"'"'source_alias'"'"', username => :'"'"'collector_user'"'"', password => NULL,
        dbname => :'"'"'monitoring_db'"'"', frequency => :'"'"'frequency'"'"'::integer,
        powa_coalesce => :'"'"'coalesce'"'"'::integer, retention => :'"'"'retention'"'"'::interval,
        allow_ui_connection => false, extensions => ARRAY['"'"'pg_qualstats'"'"']::text[]);' \
    --set=source_host="$source_host" --set=source_port="$source_port" --set=source_alias="$source_alias" \
    --set=collector_user="$collector_user" --set=monitoring_db="$monitoring_db" --set=frequency="$frequency" \
    --set=coalesce="$coalesce" --set=retention="$retention"
  server_id="$(repo_query 'SELECT id FROM "PoWA".powa_servers WHERE alias = :'"'"'source_alias'"'"';' --set=source_alias="$source_alias")"
  info "Yeni PoWA server id ${server_id} kaydedildi"
fi

password_is_null="$(repo_query 'SELECT password IS NULL FROM "PoWA".powa_servers WHERE id = :'"'"'server_id'"'"'::integer;' --set=server_id="$server_id")"
[[ "$password_is_null" == t ]] || fail "Guvenlik kontrolu: repository kaynak parolasi NULL degil"
info "Repository parola saklamiyor (password IS NULL)"

docker compose up -d --force-recreate --no-deps collector >/dev/null
info "Collector yeni pgpass, TLS modu ve server listesiyle yeniden olusturuldu"

if [[ "$skip_snapshot_wait" == true ]]; then
  printf '\nKaynak hazir: alias=%s, server_id=%s, endpoint=%s:%s/%s\n' \
    "$source_alias" "$server_id" "$source_host" "$source_port" "$monitoring_db"
  exit 0
fi

snapshot_ok=false
last_errors=""
for attempt in $(seq 1 20); do
  if ((attempt % 3 == 1)); then
    repo_query "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${server_id}';" >/dev/null || true
  fi
  snapshot_row="$(repo_query \
    'SELECT (snapts > :'"'"'previous_snap'"'"'::timestamptz), coalesce(array_to_string(errors, E'"'"'\\n'"'"'), '"'"''"'"')
       FROM "PoWA".powa_snapshot_metas WHERE srvid = :'"'"'server_id'"'"'::integer;' \
    --set=server_id="$server_id" --set=previous_snap="$previous_snap")"
  IFS='|' read -r snap_advanced last_errors <<< "$snapshot_row"
  if [[ "$snap_advanced" == t && -z "$last_errors" ]]; then
    snapshot_ok=true
    break
  fi
  sleep 2
done

if [[ "$snapshot_ok" != true ]]; then
  docker compose logs --tail=40 collector >&2
  fail "Ilk snapshot 40 saniye icinde dogrulanamadi${last_errors:+: ${last_errors}}"
fi

info "Collector ilk snapshot'i repository'ye yazdi"
printf '\nKaynak entegrasyonu tamam: alias=%s, server_id=%s, endpoint=%s:%s/%s\n' \
  "$source_alias" "$server_id" "$source_host" "$source_port" "$monitoring_db"
