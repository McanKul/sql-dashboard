#!/usr/bin/env bash
set -Eeuo pipefail

migrations_dir="${MIGRATIONS_DIR:-/opt/advisor/sql}"
manifest_path="${MIGRATIONS_MANIFEST:-${migrations_dir}/repository-migrations.manifest}"
psql_bin="${MIGRATION_PSQL_BIN:-psql}"
lock_timeout_seconds="${MIGRATION_LOCK_TIMEOUT_SECONDS:-60}"

fail() {
  printf 'Repository migration error: %s\n' "$1" >&2
  exit 1
}

[[ "$lock_timeout_seconds" =~ ^[1-9][0-9]{0,3}$ ]] \
  || fail "MIGRATION_LOCK_TIMEOUT_SECONDS must be an integer between 1 and 9999"
[[ "$migrations_dir" != *$'\n'* && "$migrations_dir" != *"'"* ]] \
  || fail "MIGRATIONS_DIR contains characters that cannot be safely passed to psql"
[[ -r "$manifest_path" ]] || fail "manifest is not readable: ${manifest_path}"
command -v "$psql_bin" >/dev/null 2>&1 || fail "psql executable is unavailable: ${psql_bin}"

if command -v sha256sum >/dev/null 2>&1; then
  checksum_command=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  checksum_command=(shasum -a 256)
else
  fail "sha256sum or shasum is required"
fi

versions=()
names=()
scripts=()
checksums=()
previous_version=""
line_number=0

while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
  line_number=$((line_number + 1))
  [[ -z "$manifest_line" || "$manifest_line" == \#* ]] && continue

  IFS='|' read -r version migration_name relative_script expected_checksum extra <<< "$manifest_line"
  [[ -z "${extra:-}" ]] \
    || fail "manifest line ${line_number} has more than four fields"
  [[ "$version" =~ ^[0-9]{4}$ ]] \
    || fail "manifest line ${line_number} has an invalid four-digit version"
  [[ "$migration_name" =~ ^[a-z][a-z0-9_]*$ ]] \
    || fail "manifest line ${line_number} has an invalid migration name"
  [[ "$relative_script" != */../* && "$relative_script" != ../* && "$relative_script" != */.. ]] \
    || fail "manifest line ${line_number} escapes the migration directory"
  [[ "$relative_script" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || fail "manifest line ${line_number} has an invalid script path"
  [[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] \
    || fail "manifest line ${line_number} has an invalid SHA-256 checksum"
  if [[ -n "$previous_version" && "$version" < "$previous_version" ]]; then
    fail "manifest versions are not ordered at line ${line_number}"
  fi
  if [[ "$version" == "$previous_version" ]]; then
    fail "manifest contains duplicate version ${version}"
  fi
  if [[ -n "${names[0]-}" ]]; then
    for existing_name in "${names[@]}"; do
      [[ "$migration_name" != "$existing_name" ]] \
        || fail "manifest contains duplicate migration name ${migration_name}"
    done
    for existing_script in "${scripts[@]}"; do
      [[ "${migrations_dir}/${relative_script}" != "$existing_script" ]] \
        || fail "manifest contains duplicate script ${relative_script}"
    done
  fi

  script_path="${migrations_dir}/${relative_script}"
  [[ -f "$script_path" && -r "$script_path" ]] \
    || fail "migration ${version} is not readable: ${script_path}"
  actual_checksum="$("${checksum_command[@]}" "$script_path")"
  actual_checksum="${actual_checksum%%[[:space:]]*}"
  [[ "$actual_checksum" == "$expected_checksum" ]] \
    || fail "migration ${version} checksum mismatch (expected ${expected_checksum}, got ${actual_checksum})"

  versions+=("$version")
  names+=("$migration_name")
  scripts+=("$script_path")
  checksums+=("$expected_checksum")
  previous_version="$version"
done < "$manifest_path"

(( ${#versions[@]} > 0 )) || fail "manifest contains no migrations"

: "${PGDATABASE:=${POSTGRES_DB:-powa_repository}}"
: "${PGUSER:=${POSTGRES_USER:-postgres}}"
: "${JOIN_SOURCE_ALIAS:=}"
export PGDATABASE PGUSER JOIN_SOURCE_ALIAS

emit_migration_plan() {
  local known_versions=""
  local index version migration_name script_path expected_checksum

  for version in "${versions[@]}"; do
    if [[ -n "$known_versions" ]]; then
      known_versions+=", "
    fi
    known_versions+="'${version}'"
  done

  printf '%s\n' '\set ON_ERROR_STOP on'
  printf '%s\n' 'BEGIN;'
  printf "SET LOCAL lock_timeout = '%ss';\n" "$lock_timeout_seconds"
  printf '%s\n' 'SET LOCAL search_path = pg_catalog;'
  printf '%s\n' "SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('postgresql-advisor:repository-migrations:' || pg_catalog.current_database(), 0));"
  printf '%s\n' 'CREATE SCHEMA IF NOT EXISTS advisor_migrations AUTHORIZATION CURRENT_USER;'
  printf '%s\n' 'REVOKE ALL ON SCHEMA advisor_migrations FROM PUBLIC;'
  printf '%s\n' 'CREATE TABLE IF NOT EXISTS advisor_migrations.schema_migrations ('
  printf '%s\n' '    version text PRIMARY KEY CHECK (version ~ '\''^[0-9]{4}$'\''),'
  printf '%s\n' '    name text NOT NULL UNIQUE,'
  printf '%s\n' '    script text NOT NULL UNIQUE,'
  printf '%s\n' '    checksum text NOT NULL CHECK (checksum ~ '\''^[0-9a-f]{64}$'\''),'
  printf '%s\n' '    installed_at timestamptz NOT NULL DEFAULT clock_timestamp(),'
  printf '%s\n' '    installed_by text NOT NULL DEFAULT session_user'
  printf '%s\n' ');'
  printf '%s\n' 'REVOKE ALL ON advisor_migrations.schema_migrations FROM PUBLIC;'
  printf '%s\n' "DO \$manifest_guard\$"
  printf '%s\n' 'DECLARE'
  printf '%s\n' '    unknown_version text;'
  printf '%s\n' 'BEGIN'
  printf '%s\n' '    SELECT version INTO unknown_version'
  printf '%s\n' '      FROM advisor_migrations.schema_migrations'
  printf '     WHERE version NOT IN (%s)\n' "$known_versions"
  printf '%s\n' '     ORDER BY version'
  printf '%s\n' '     LIMIT 1;'
  printf '%s\n' '    IF unknown_version IS NOT NULL THEN'
  printf '%s\n' "        RAISE EXCEPTION 'Database has migration version % which is unknown to this release', unknown_version;"
  printf '%s\n' '    END IF;'
  printf '%s\n' 'END'
  # Literal PostgreSQL dollar-quote delimiters, not shell variables.
  # shellcheck disable=SC2016
  printf '%s\n' '$manifest_guard$;'

  for ((index = 0; index < ${#versions[@]}; index++)); do
    version="${versions[$index]}"
    migration_name="${names[$index]}"
    script_path="${scripts[$index]}"
    expected_checksum="${checksums[$index]}"

    # shellcheck disable=SC2016
    printf 'DO $verify_%s$\n' "$version"
    printf '%s\n' 'DECLARE'
    printf '%s\n' '    applied advisor_migrations.schema_migrations%ROWTYPE;'
    printf '%s\n' 'BEGIN'
    printf "    SELECT * INTO applied FROM advisor_migrations.schema_migrations WHERE version = '%s';\n" "$version"
    printf '%s\n' '    IF FOUND AND ('
    printf "        applied.name IS DISTINCT FROM '%s'\n" "$migration_name"
    printf "        OR applied.script IS DISTINCT FROM '%s'\n" "${script_path#"${migrations_dir}"/}"
    printf "        OR applied.checksum IS DISTINCT FROM '%s'\n" "$expected_checksum"
    printf '%s\n' '    ) THEN'
    printf '%s\n' "        RAISE EXCEPTION 'Applied migration % metadata/checksum differs from this release', applied.version;"
    printf '%s\n' '    END IF;'
    printf '%s\n' 'END'
    # shellcheck disable=SC2016
    printf '$verify_%s$;\n' "$version"
    printf "SELECT NOT EXISTS (SELECT 1 FROM advisor_migrations.schema_migrations WHERE version = '%s') AS migration_pending \\gset\n" "$version"
    printf '%s\n' '\if :migration_pending'
    printf '%s Applying repository migration %s (%s)\n' '\echo' "$version" "$migration_name"
    printf "\\ir '%s'\n" "$script_path"
    printf '%s\n' 'INSERT INTO advisor_migrations.schema_migrations (version, name, script, checksum)'
    printf "VALUES ('%s', '%s', '%s', '%s');\n" \
      "$version" "$migration_name" "${script_path#"${migrations_dir}"/}" "$expected_checksum"
    printf '%s\n' '\else'
    printf '%s Repository migration %s already applied\n' '\echo' "$version"
    printf '%s\n' '\endif'
  done

  printf '%s\n' 'COMMIT;'
  printf '%s\n' '\echo Repository migrations are current'
}

emit_migration_plan | "$psql_bin" -X --set=ON_ERROR_STOP=1 --username "$PGUSER" --dbname "$PGDATABASE"
