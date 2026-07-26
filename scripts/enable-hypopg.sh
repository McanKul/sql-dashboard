#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose ps --services --status running | grep -qx source-db \
  || fail "source-db calismiyor"

evaluator_read_schemas="${ADVISOR_EVALUATOR_READ_SCHEMAS:-}"
if [[ -z "$evaluator_read_schemas" ]]; then
  while IFS='=' read -r variable_name variable_value; do
    if [[ "$variable_name" == "ADVISOR_EVALUATOR_READ_SCHEMAS" ]]; then
      evaluator_read_schemas="$variable_value"
      break
    fi
  done < <(docker compose config --environment)
fi
evaluator_read_schemas="${evaluator_read_schemas:-public}"

available_version="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SELECT default_version FROM pg_available_extensions WHERE name='hypopg'")"
[[ "$available_version" == "1.4.3" ]] \
  || fail "Image icinde HypoPG 1.4.3 bulunamadi: ${available_version:-yok}"

docker compose exec -T \
  -e ADVISOR_EVALUATOR_READ_SCHEMAS="$evaluator_read_schemas" \
  source-db psql -X --set=ON_ERROR_STOP=1 -U postgres -d appdb <<'SQL'
\getenv evaluator_password ADVISOR_EVALUATOR_PASSWORD
\getenv evaluator_read_schemas ADVISOR_EVALUATOR_READ_SCHEMAS

SELECT format(
    'CREATE ROLE advisor_evaluator LOGIN PASSWORD %L NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2',
    :'evaluator_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='advisor_evaluator')
\gexec

SELECT format('ALTER ROLE advisor_evaluator LOGIN PASSWORD %L', :'evaluator_password')
\gexec
ALTER ROLE advisor_evaluator NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2;
ALTER ROLE advisor_evaluator SET default_transaction_read_only = on;
ALTER ROLE advisor_evaluator SET statement_timeout = '2s';
ALTER ROLE advisor_evaluator SET lock_timeout = '250ms';
ALTER ROLE advisor_evaluator SET idle_in_transaction_session_timeout = '3s';

CREATE SCHEMA IF NOT EXISTS advisor_hypopg;
CREATE EXTENSION IF NOT EXISTS hypopg WITH SCHEMA advisor_hypopg;
REVOKE ALL ON SCHEMA advisor_hypopg FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA advisor_hypopg FROM PUBLIC;
GRANT USAGE ON SCHEMA advisor_hypopg TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_reset() TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_create_index(text) TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_relation_size(oid) TO advisor_evaluator;

GRANT CONNECT ON DATABASE appdb TO advisor_evaluator;

CREATE TEMP TABLE advisor_evaluator_read_schemas (
    schema_name text PRIMARY KEY
);

SELECT set_config(
    'advisor.evaluator_read_schemas', :'evaluator_read_schemas', false
);

DO $configure_read_envelope$
DECLARE
    configured_schema text;
    default_acl record;
    object_owner name;
    schema_part text;
BEGIN
    FOR schema_part IN
        SELECT btrim(value)
        FROM regexp_split_to_table(
            current_setting('advisor.evaluator_read_schemas'), ','
        ) AS value
    LOOP
        IF schema_part = '' THEN
            RAISE EXCEPTION
              'ADVISOR_EVALUATOR_READ_SCHEMAS contains an empty schema name';
        END IF;
        IF schema_part !~ '^[A-Za-z_][A-Za-z0-9_$]*$'
           OR octet_length(schema_part) > 63 THEN
            RAISE EXCEPTION
              'invalid evaluator read schema name: %', schema_part;
        END IF;
        IF schema_part = 'information_schema'
           OR schema_part LIKE 'pg\_%' ESCAPE '\' THEN
            RAISE EXCEPTION
              'system schema cannot be an evaluator read schema: %', schema_part;
        END IF;
        IF schema_part = 'advisor_hypopg' THEN
            RAISE EXCEPTION
              'advisor_hypopg is managed separately from evaluator read schemas';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_namespace WHERE nspname = schema_part
        ) THEN
            RAISE EXCEPTION
              'configured evaluator read schema does not exist: %', schema_part;
        END IF;

        INSERT INTO advisor_evaluator_read_schemas (schema_name)
        VALUES (schema_part)
        ON CONFLICT DO NOTHING;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM advisor_evaluator_read_schemas) THEN
        RAISE EXCEPTION 'at least one evaluator read schema is required';
    END IF;

    -- Remove default table grants left behind by an older configuration.  This
    -- keeps a removed schema from silently granting access to future tables.
    FOR default_acl IN
        SELECT DISTINCT owner_role.rolname AS owner_name,
                        namespace.nspname AS schema_name
        FROM pg_default_acl AS defaults
        JOIN pg_roles AS owner_role ON owner_role.oid = defaults.defaclrole
        JOIN pg_namespace AS namespace ON namespace.oid = defaults.defaclnamespace
        CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS privilege
        WHERE defaults.defaclobjtype = 'r'
          AND privilege.grantee = 'advisor_evaluator'::regrole
          AND namespace.nspname <> 'advisor_hypopg'
          AND namespace.nspname <> 'information_schema'
          AND namespace.nspname NOT LIKE 'pg\_%' ESCAPE '\'
    LOOP
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I '
            'REVOKE ALL ON TABLES FROM advisor_evaluator',
            default_acl.owner_name, default_acl.schema_name
        );
    END LOOP;

    -- Reconcile direct ACL drift across application schemas, then apply the
    -- exact USAGE + table SELECT envelope only to the configured set.
    FOR configured_schema IN
        SELECT namespace.nspname
        FROM pg_namespace AS namespace
        WHERE namespace.nspname <> 'advisor_hypopg'
          AND namespace.nspname <> 'information_schema'
          AND namespace.nspname NOT LIKE 'pg\_%' ESCAPE '\'
    LOOP
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I '
            'FROM advisor_evaluator', configured_schema
        );
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I '
            'FROM advisor_evaluator', configured_schema
        );
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON SCHEMA %I FROM advisor_evaluator',
            configured_schema
        );

        IF EXISTS (
            SELECT 1
            FROM advisor_evaluator_read_schemas
            WHERE schema_name = configured_schema
        ) THEN
            EXECUTE format(
                'GRANT USAGE ON SCHEMA %I TO advisor_evaluator',
                configured_schema
            );
            EXECUTE format(
                'GRANT SELECT ON ALL TABLES IN SCHEMA %I TO advisor_evaluator',
                configured_schema
            );

            -- Default privileges are owner-specific. Cover the schema owner,
            -- current table/view owners and this provisioning role; a later
            -- object creator must be added by rerunning the script or by its DBA.
            FOR object_owner IN
                SELECT DISTINCT owner_name
                FROM (
                    SELECT schema_owner.rolname AS owner_name
                    FROM pg_namespace AS namespace
                    JOIN pg_roles AS schema_owner
                      ON schema_owner.oid = namespace.nspowner
                    WHERE namespace.nspname = configured_schema
                    UNION
                    SELECT relation_owner.rolname
                    FROM pg_class AS relation
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = relation.relnamespace
                    JOIN pg_roles AS relation_owner
                      ON relation_owner.oid = relation.relowner
                    WHERE namespace.nspname = configured_schema
                      AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
                    UNION
                    SELECT current_user::name
                ) AS owners
            LOOP
                EXECUTE format(
                    'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I '
                    'REVOKE ALL ON TABLES FROM advisor_evaluator',
                    object_owner, configured_schema
                );
                EXECUTE format(
                    'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I '
                    'GRANT SELECT ON TABLES TO advisor_evaluator',
                    object_owner, configured_schema
                );
            END LOOP;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM advisor_evaluator_read_schemas AS configured
        JOIN pg_namespace AS namespace
          ON namespace.nspname = configured.schema_name
        WHERE NOT has_schema_privilege(
                  'advisor_evaluator', namespace.oid, 'USAGE'
              )
           OR has_schema_privilege(
                  'advisor_evaluator', namespace.oid, 'CREATE'
              )
    ) THEN
        RAISE EXCEPTION 'evaluator schema envelope validation failed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM advisor_evaluator_read_schemas AS configured
        JOIN pg_namespace AS namespace
          ON namespace.nspname = configured.schema_name
        JOIN pg_class AS relation ON relation.relnamespace = namespace.oid
        WHERE relation.relkind IN ('r', 'p', 'v', 'm', 'f')
          AND (
              NOT has_table_privilege(
                  'advisor_evaluator', relation.oid, 'SELECT'
              )
              OR has_table_privilege(
                  'advisor_evaluator', relation.oid,
                  'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
              )
          )
    ) THEN
        RAISE EXCEPTION 'evaluator table envelope validation failed';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname <> 'advisor_hypopg'
          AND namespace.nspname <> 'information_schema'
          AND namespace.nspname NOT LIKE 'pg\_%' ESCAPE '\'
          AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
          AND NOT EXISTS (
              SELECT 1
              FROM advisor_evaluator_read_schemas AS configured
              WHERE configured.schema_name = namespace.nspname
          )
          AND has_table_privilege(
              'advisor_evaluator', relation.oid,
              'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
          )
    ) THEN
        RAISE EXCEPTION
          'evaluator retains table access outside configured read schemas';
    END IF;
END
$configure_read_envelope$;
SQL

capability="$(docker compose exec -T source-db psql -U postgres -d appdb -AtF '|' -qc \
  "SELECT
      (SELECT extversion FROM pg_extension WHERE extname='hypopg'),
      (SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
              AND NOT rolreplication AND NOT rolbypassrls AND rolconnlimit = 2
         FROM pg_roles WHERE rolname='advisor_evaluator'),
      has_function_privilege('advisor_evaluator', 'advisor_hypopg.hypopg_create_index(text)', 'EXECUTE')")"
[[ "$capability" == "1.4.3|t|t" ]] \
  || fail "HypoPG/evaluator capability dogrulanamadi: ${capability:-bos}"

pass "HypoPG 1.4.3 ve salt-okunur advisor_evaluator rolu hazir (semalar: $evaluator_read_schemas)"
