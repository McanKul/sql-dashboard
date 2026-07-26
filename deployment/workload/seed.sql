\set ON_ERROR_STOP on
\pset pager off

-- Protect the secret-bearing validation and ALTER ROLE statements even when
-- the target enables verbose statement/error logging.
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_parameter_max_length_on_error = 0;

\getenv workload_db_password WORKLOAD_DB_PASSWORD
\if :{?workload_db_password}
\else
  DO $abort$ BEGIN
      RAISE EXCEPTION 'WORKLOAD_DB_PASSWORD environment variable is required';
  END $abort$;
\endif

SELECT length(:'workload_db_password') >= 16
   AND :'workload_db_password' <> 'advisor_dev_workload'
   AND :'workload_db_password' NOT LIKE 'change-me-%'
   AS workload_password_valid \gset
\if :workload_password_valid
\else
  DO $abort$ BEGIN
      RAISE EXCEPTION 'WORKLOAD_DB_PASSWORD must be strong and not use a known development value';
  END $abort$;
\endif

-- This file is intentionally not mounted as a docker-entrypoint bootstrap.
-- It grows only an explicitly selected, already-running source database.
SET application_name = 'advisor-realistic-seeder';
SET statement_timeout = 0;
SET lock_timeout = '5s';
SET idle_in_transaction_session_timeout = 0;
SET synchronous_commit = off;
SET client_min_messages = notice;

-- Bulk seed statements must not dominate the workload the advisor evaluates.
-- pg_wait_sampling has no per-session switch, but the three statement/predicate
-- collectors that support one are disabled for this privileged seed session.
SET pg_stat_statements.track = 'none';
SET pg_stat_kcache.track = 'none';
SET pg_qualstats.enabled = off;

-- Session-level lock: concurrent target-count seeders would otherwise read the
-- same starting counts and overshoot tables without a natural unique key.
SELECT pg_try_advisory_lock(
           hashtextextended(
               'postgresql-advisor-realistic-seed:' || current_database(),
               0
           )
       ) AS seed_lock_acquired
\gset
\if :seed_lock_acquired
\else
  DO $abort$ BEGIN
      RAISE EXCEPTION 'another realistic workload seed is already running for this database';
  END $abort$;
\endif

-- Older preparation scripts do not pass ERP knobs.  Preserve quick/normal/
-- stress behavior, while the explicit ERP profile receives the bounded target
-- requested by the catalog-scale workload.
\if :{?target_erp_tables}
\else
  SELECT CASE WHEN :'seed_profile' = 'erp' THEN 500 ELSE 0 END AS target_erp_tables
  \gset
\endif
\if :{?erp_rows_per_table}
\else
  SELECT CASE WHEN :'seed_profile' = 'erp' THEN 2000 ELSE 64 END AS erp_rows_per_table
  \gset
\endif

SELECT set_config('advisor.seed.profile', :'seed_profile', false);
SELECT set_config('advisor.seed.batch_size', :'batch_size', false);
SELECT set_config('advisor.seed.target_customers', :'target_customers', false);
SELECT set_config('advisor.seed.target_orders', :'target_orders', false);
SELECT set_config('advisor.seed.target_order_items', :'target_order_items', false);
SELECT set_config('advisor.seed.target_events', :'target_events', false);
SELECT set_config('advisor.seed.target_tenants', :'target_tenants', false);
SELECT set_config('advisor.seed.target_products', :'target_products', false);
SELECT set_config('advisor.seed.target_inventory', :'target_inventory', false);
SELECT set_config('advisor.seed.target_payments', :'target_payments', false);
SELECT set_config('advisor.seed.target_jobs', :'target_jobs', false);
SELECT set_config('advisor.seed.target_hotspots', :'target_hotspots', false);
SELECT set_config('advisor.seed.target_erp_tables', :'target_erp_tables', false);
SELECT set_config('advisor.seed.erp_rows_per_table', :'erp_rows_per_table', false);

DO $roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_reader') THEN
        CREATE ROLE advisor_workload_reader
          NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
          NOREPLICATION NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_writer') THEN
        CREATE ROLE advisor_workload_writer
          NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
          NOREPLICATION NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_reporter') THEN
        CREATE ROLE advisor_workload_reporter
          NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
          NOREPLICATION NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_login') THEN
        CREATE ROLE advisor_workload_login
          LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
          NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 70;
    END IF;
END
$roles$;

ALTER ROLE advisor_workload_reader
  NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS;
ALTER ROLE advisor_workload_writer
  NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS;
ALTER ROLE advisor_workload_reporter
  NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS;

SELECT format(
    'ALTER ROLE advisor_workload_login WITH LOGIN NOINHERIT NOSUPERUSER '
    'NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 70 PASSWORD %L VALID UNTIL ''infinity''',
    :'workload_db_password'
)
\gexec

CREATE TABLE IF NOT EXISTS workload_tenants (
    id bigint PRIMARY KEY,
    name text NOT NULL,
    region text NOT NULL,
    plan text NOT NULL,
    status text NOT NULL,
    created_at timestamptz NOT NULL,
    CONSTRAINT workload_tenants_status_check
      CHECK (status IN ('active', 'trial', 'past_due', 'suspended'))
);

CREATE TABLE IF NOT EXISTS workload_customer_tenants (
    customer_id bigint PRIMARY KEY REFERENCES customers(id),
    tenant_id bigint NOT NULL REFERENCES workload_tenants(id),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_workload_customer_tenants_tenant
  ON workload_customer_tenants(tenant_id);

CREATE TABLE IF NOT EXISTS workload_products (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id bigint NOT NULL REFERENCES workload_tenants(id),
    sku text NOT NULL UNIQUE,
    category text NOT NULL,
    price numeric(12,2) NOT NULL,
    active boolean NOT NULL DEFAULT true,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_workload_products_tenant
  ON workload_products(tenant_id);

CREATE TABLE IF NOT EXISTS workload_inventory (
    product_id bigint NOT NULL REFERENCES workload_products(id) ON DELETE CASCADE,
    warehouse_id smallint NOT NULL,
    tenant_id bigint NOT NULL REFERENCES workload_tenants(id),
    available integer NOT NULL,
    reserved integer NOT NULL DEFAULT 0,
    version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, warehouse_id),
    CONSTRAINT workload_inventory_warehouse_check CHECK (warehouse_id BETWEEN 1 AND 8),
    CONSTRAINT workload_inventory_available_check CHECK (available >= 0),
    CONSTRAINT workload_inventory_reserved_check CHECK (reserved >= 0)
);
CREATE INDEX IF NOT EXISTS idx_workload_inventory_tenant
  ON workload_inventory(tenant_id);

CREATE TABLE IF NOT EXISTS workload_payments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id bigint NOT NULL REFERENCES workload_tenants(id),
    order_id bigint NOT NULL REFERENCES orders(id),
    provider text NOT NULL,
    status text NOT NULL,
    amount numeric(12,2) NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workload_payments_status_check
      CHECK (status IN ('authorized', 'captured', 'failed', 'refunded'))
);
CREATE INDEX IF NOT EXISTS idx_workload_payments_order
  ON workload_payments(order_id);

CREATE TABLE IF NOT EXISTS workload_jobs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id bigint NOT NULL REFERENCES workload_tenants(id),
    queue text NOT NULL,
    status text NOT NULL,
    priority smallint NOT NULL DEFAULT 0,
    run_at timestamptz NOT NULL,
    locked_at timestamptz,
    attempts integer NOT NULL DEFAULT 0,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workload_jobs_status_check
      CHECK (status IN ('ready', 'running', 'done', 'failed'))
);
CREATE INDEX IF NOT EXISTS idx_workload_jobs_tenant
  ON workload_jobs(tenant_id);

CREATE TABLE IF NOT EXISTS advisor_workload_hotspots (
    id integer PRIMARY KEY,
    value bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE SCHEMA IF NOT EXISTS advisor_erp;
REVOKE ALL ON SCHEMA advisor_erp FROM PUBLIC;
CREATE TABLE IF NOT EXISTS advisor_erp.table_manifest (
    table_number integer PRIMARY KEY,
    table_name text NOT NULL UNIQUE,
    target_rows integer NOT NULL,
    actual_rows bigint NOT NULL,
    seeded_at timestamptz NOT NULL,
    CONSTRAINT advisor_erp_table_number_check
      CHECK (table_number BETWEEN 1 AND 500),
    CONSTRAINT advisor_erp_table_name_check
      CHECK (table_name ~ '^erp_entity_[0-9]{4}$'),
    CONSTRAINT advisor_erp_target_rows_check
      CHECK (target_rows BETWEEN 1 AND 5000),
    CONSTRAINT advisor_erp_actual_rows_check
      CHECK (actual_rows >= target_rows)
);

CREATE TABLE IF NOT EXISTS advisor_workload_seed_manifest (
    seed_key text PRIMARY KEY,
    schema_version integer NOT NULL,
    profile text NOT NULL,
    target_counts jsonb NOT NULL,
    actual_counts jsonb,
    status text NOT NULL,
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    CONSTRAINT advisor_workload_seed_key_check CHECK (seed_key = 'active'),
    CONSTRAINT advisor_workload_seed_profile_check CHECK (profile IN ('quick', 'normal', 'stress', 'erp')),
    CONSTRAINT advisor_workload_seed_status_check CHECK (status IN ('SEEDING', 'READY'))
);

-- Existing seed manifests retain the previous three-profile check because
-- CREATE TABLE IF NOT EXISTS does not reconcile constraints.
ALTER TABLE advisor_workload_seed_manifest
  DROP CONSTRAINT IF EXISTS advisor_workload_seed_profile_check;
ALTER TABLE advisor_workload_seed_manifest
  ADD CONSTRAINT advisor_workload_seed_profile_check
  CHECK (profile IN ('quick', 'normal', 'stress', 'erp'));

-- The bounded event writer keeps only the newest tagged fixture rows.  Without
-- this partial index every cleanup walks the multi-million-row ERP event table
-- while holding the shared retention lock, which turns fixture maintenance
-- into artificial lock pressure rather than representative application load.
DO $repair_event_cleanup_index$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_class AS index_relation
        JOIN pg_namespace AS namespace
          ON namespace.oid = index_relation.relnamespace
        LEFT JOIN pg_index AS index_record
          ON index_record.indexrelid = index_relation.oid
        LEFT JOIN pg_am AS access_method
          ON access_method.oid = index_relation.relam
        WHERE namespace.nspname = 'public'
          AND index_relation.relname = 'idx_events_advisor_realistic_id_desc'
          AND (
              index_record.indexrelid IS NULL
              OR index_record.indrelid <> 'public.events'::regclass
              OR NOT index_record.indisvalid
              OR NOT index_record.indisready
              OR NOT index_record.indislive
              OR index_record.indisunique
              OR index_record.indisprimary
              OR index_record.indisexclusion
              OR access_method.amname IS DISTINCT FROM 'btree'
              OR index_record.indnkeyatts <> 1
              OR index_record.indnatts <> 1
              OR pg_get_indexdef(index_record.indexrelid, 1, true) <> 'id'
              OR index_record.indoption::text <> '3'
              OR pg_get_expr(index_record.indpred, index_record.indrelid, true)
                   <> '(metadata ->> ''source''::text) = ''advisor-realistic''::text'
          )
    ) THEN
        DROP INDEX public.idx_events_advisor_realistic_id_desc;
    END IF;
END
$repair_event_cleanup_index$;

CREATE INDEX IF NOT EXISTS idx_events_advisor_realistic_id_desc
  ON events (id DESC)
  WHERE metadata ->> 'source' = 'advisor-realistic';

INSERT INTO advisor_workload_seed_manifest (
    seed_key, schema_version, profile, target_counts, actual_counts,
    status, started_at, completed_at
)
VALUES (
    'active',
    2,
    current_setting('advisor.seed.profile'),
    jsonb_build_object(
        'customers', current_setting('advisor.seed.target_customers')::bigint,
        'orders', current_setting('advisor.seed.target_orders')::bigint,
        'order_items', current_setting('advisor.seed.target_order_items')::bigint,
        'events', current_setting('advisor.seed.target_events')::bigint,
        'workload_tenants', current_setting('advisor.seed.target_tenants')::bigint,
        'workload_customer_tenants', current_setting('advisor.seed.target_customers')::bigint,
        'workload_products', current_setting('advisor.seed.target_products')::bigint,
        'workload_inventory', current_setting('advisor.seed.target_inventory')::bigint,
        'workload_payments', current_setting('advisor.seed.target_payments')::bigint,
        'workload_jobs', current_setting('advisor.seed.target_jobs')::bigint,
        'advisor_workload_hotspots', current_setting('advisor.seed.target_hotspots')::bigint,
        'advisor_erp_tables', current_setting('advisor.seed.target_erp_tables')::bigint,
        'advisor_erp_rows',
          current_setting('advisor.seed.target_erp_tables')::bigint
          * current_setting('advisor.seed.erp_rows_per_table')::bigint
    ),
    NULL,
    'SEEDING',
    clock_timestamp(),
    NULL
)
ON CONFLICT (seed_key) DO UPDATE
SET schema_version = EXCLUDED.schema_version,
    profile = EXCLUDED.profile,
    target_counts = EXCLUDED.target_counts,
    actual_counts = NULL,
    status = 'SEEDING',
    started_at = EXCLUDED.started_at,
    completed_at = NULL;

CREATE OR REPLACE PROCEDURE pg_temp.seed_advisor_realistic_workload()
LANGUAGE plpgsql
AS $seed$
DECLARE
    v_batch bigint := current_setting('advisor.seed.batch_size')::bigint;
    v_target_customers bigint := current_setting('advisor.seed.target_customers')::bigint;
    v_target_orders bigint := current_setting('advisor.seed.target_orders')::bigint;
    v_target_order_items bigint := current_setting('advisor.seed.target_order_items')::bigint;
    v_target_events bigint := current_setting('advisor.seed.target_events')::bigint;
    v_target_tenants bigint := current_setting('advisor.seed.target_tenants')::bigint;
    v_target_products bigint := current_setting('advisor.seed.target_products')::bigint;
    v_target_inventory bigint := current_setting('advisor.seed.target_inventory')::bigint;
    v_target_payments bigint := current_setting('advisor.seed.target_payments')::bigint;
    v_target_jobs bigint := current_setting('advisor.seed.target_jobs')::bigint;
    v_target_hotspots bigint := current_setting('advisor.seed.target_hotspots')::bigint;
    v_target_erp_tables integer := current_setting('advisor.seed.target_erp_tables')::integer;
    v_erp_rows_per_table integer := current_setting('advisor.seed.erp_rows_per_table')::integer;
    v_current bigint;
    v_add bigint;
    v_inserted bigint;
    v_customer_count bigint;
    v_order_count bigint;
    v_product_count bigint;
    v_erp_table_number integer;
    v_erp_table_name text;
    v_erp_index_name text;
    v_erp_actual_rows bigint;
BEGIN
    IF v_batch < 1000 OR v_batch > 500000 THEN
        RAISE EXCEPTION 'batch_size must be between 1000 and 500000';
    END IF;
    IF v_target_erp_tables < 0 OR v_target_erp_tables > 500 THEN
        RAISE EXCEPTION 'target_erp_tables must be between 0 and 500';
    END IF;
    IF v_erp_rows_per_table < 1 OR v_erp_rows_per_table > 5000 THEN
        RAISE EXCEPTION 'erp_rows_per_table must be between 1 and 5000';
    END IF;
    IF current_setting('advisor.seed.profile') = 'erp'
       AND v_target_erp_tables <> 500 THEN
        RAISE EXCEPTION 'ERP profile requires exactly 500 business tables';
    END IF;
    IF current_setting('advisor.seed.profile') = 'erp'
       AND v_erp_rows_per_table <> 2000 THEN
        RAISE EXCEPTION 'ERP profile requires exactly 2000 rows per table';
    END IF;
    IF current_setting('advisor.seed.profile') <> 'erp'
       AND v_target_erp_tables <> 0 THEN
        RAISE EXCEPTION 'ERP tables require the explicit ERP seed profile';
    END IF;

    INSERT INTO workload_tenants (id, name, region, plan, status, created_at)
    SELECT tenant_id,
           'Tenant ' || lpad(tenant_id::text, 6, '0'),
           (ARRAY['TR', 'EU', 'MENA', 'US'])[1 + mod(tenant_id, 4)::integer],
           (ARRAY['starter', 'growth', 'business', 'enterprise'])[1 + mod(tenant_id * 7, 4)::integer],
           CASE
             WHEN mod(tenant_id, 97) = 0 THEN 'suspended'
             WHEN mod(tenant_id, 31) = 0 THEN 'past_due'
             WHEN mod(tenant_id, 17) = 0 THEN 'trial'
             ELSE 'active'
           END,
           now() - (mod(tenant_id * 7919, 94608000)::text || ' seconds')::interval
    FROM generate_series(1, v_target_tenants) AS tenant_id
    ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    COMMIT;
    RAISE NOTICE 'workload_tenants: inserted %, target %', v_inserted, v_target_tenants;

    SELECT count(*) INTO v_current FROM customers;
    WHILE v_current < v_target_customers LOOP
        v_add := least(v_batch, v_target_customers - v_current);

        INSERT INTO customers (name, region, created_at)
        SELECT 'Scale Customer ' || lpad((v_current + g)::text, 10, '0'),
               (ARRAY['TR', 'EU', 'MENA', 'US'])[1 + mod((v_current + g) * 13, 4)::integer],
               now() - (mod((v_current + g) * 3571, 94608000)::text || ' seconds')::interval
        FROM generate_series(1, v_add) AS g;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'customers batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'customers: % / %', v_current, v_target_customers;
    END LOOP;

    CREATE TEMP TABLE seed_customer_ids ON COMMIT PRESERVE ROWS AS
    SELECT row_number() OVER (ORDER BY id)::bigint AS ordinal, id
    FROM customers;
    CREATE UNIQUE INDEX ON seed_customer_ids(ordinal);
    ANALYZE seed_customer_ids;
    SELECT count(*) INTO v_customer_count FROM seed_customer_ids;
    COMMIT;

    SELECT count(*) INTO v_current FROM workload_customer_tenants;
    WHILE v_current < v_target_customers LOOP

        WITH missing AS (
            SELECT c.id AS customer_id,
                   1 + mod(c.ordinal - 1, v_target_tenants) AS tenant_id
            FROM seed_customer_ids AS c
            LEFT JOIN workload_customer_tenants AS mapping
              ON mapping.customer_id = c.id
            WHERE mapping.customer_id IS NULL
            ORDER BY c.ordinal
            LIMIT v_batch
        )
        INSERT INTO workload_customer_tenants (customer_id, tenant_id, created_at)
        SELECT customer_id, tenant_id, now()
        FROM missing;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted = 0 THEN
            RAISE EXCEPTION 'customer tenant mapping stalled below target';
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'workload_customer_tenants: % / %',
          v_current, v_target_customers;
    END LOOP;

    SELECT count(*) INTO v_current FROM workload_products;
    WHILE v_current < v_target_products LOOP
        v_add := least(v_batch, v_target_products - v_current);

        INSERT INTO workload_products (
            tenant_id, sku, category, price, active, attributes, created_at
        )
        SELECT 1 + mod(v_current + g - 1, v_target_tenants),
               'SKU-' || lpad((v_current + g)::text, 10, '0'),
               (ARRAY['electronics', 'home', 'fashion', 'grocery', 'sports', 'books'])[
                 1 + mod((v_current + g) * 17, 6)::integer
               ],
               (499 + mod((v_current + g) * 104729, 250000))::numeric / 100,
               mod(v_current + g, 29) <> 0,
               jsonb_build_object(
                   'brand', 'brand-' || mod(v_current + g, 500),
                   'weightGrams', 100 + mod((v_current + g) * 37, 4900),
                   'seed', 'advisor-realistic-v1'
               ),
               now() - (mod((v_current + g) * 1237, 63072000)::text || ' seconds')::interval
        FROM generate_series(1, v_add) AS g;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'products batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'workload_products: % / %', v_current, v_target_products;
    END LOOP;

    CREATE TEMP TABLE seed_product_ids ON COMMIT PRESERVE ROWS AS
    SELECT row_number() OVER (ORDER BY id)::bigint AS ordinal,
           id, tenant_id, sku
    FROM workload_products;
    CREATE UNIQUE INDEX ON seed_product_ids(ordinal);
    ANALYZE seed_product_ids;
    SELECT count(*) INTO v_product_count FROM seed_product_ids;
    COMMIT;

    SELECT count(*) INTO v_current FROM orders;
    WHILE v_current < v_target_orders LOOP
        v_add := least(v_batch, v_target_orders - v_current);

        WITH positions AS (
            SELECT v_current + g AS position
            FROM generate_series(1, v_add) AS g
        )
        INSERT INTO orders (customer_id, status, total, created_at, payload)
        SELECT customer_row.id,
               (ARRAY['paid', 'paid', 'paid', 'paid', 'shipped', 'shipped', 'pending', 'cancelled'])[
                 1 + mod(position * 19, 8)::integer
               ],
               (1999 + mod(position * 15485863, 500000))::numeric / 100,
               now() - (mod(position * 1009, 31536000)::text || ' seconds')::interval,
               jsonb_build_object(
                   'channel', (ARRAY['web', 'mobile', 'marketplace', 'store'])[
                     1 + mod(position * 11, 4)::integer
                   ],
                   'campaign', CASE WHEN mod(position, 5) = 0 THEN 'seasonal' ELSE 'organic' END,
                   'seed', 'advisor-realistic-v1'
               )
        FROM positions
        JOIN seed_customer_ids AS customer_row
          ON customer_row.ordinal = 1 + mod(position * 8191, v_customer_count);
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'orders batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'orders: % / %', v_current, v_target_orders;
    END LOOP;

    CREATE TEMP TABLE seed_order_ids ON COMMIT PRESERVE ROWS AS
    SELECT row_number() OVER (ORDER BY id)::bigint AS ordinal,
           id, customer_id
    FROM orders;
    CREATE UNIQUE INDEX ON seed_order_ids(ordinal);
    ANALYZE seed_order_ids;
    SELECT count(*) INTO v_order_count FROM seed_order_ids;
    COMMIT;

    SELECT count(*) INTO v_current FROM order_items;
    WHILE v_current < v_target_order_items LOOP
        v_add := least(v_batch, v_target_order_items - v_current);

        WITH positions AS (
            SELECT v_current + g AS position
            FROM generate_series(1, v_add) AS g
        )
        INSERT INTO order_items (order_id, sku, quantity, unit_price)
        SELECT order_row.id,
               product_row.sku,
               1 + mod(position * 7, 5)::integer,
               (299 + mod(position * 32452843, 125000))::numeric / 100
        FROM positions
        JOIN seed_order_ids AS order_row
          ON order_row.ordinal = 1 + mod(position * 31, v_order_count)
        JOIN seed_product_ids AS product_row
          ON product_row.ordinal = 1 + mod(position * 101, v_product_count);
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'order_items batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'order_items: % / %', v_current, v_target_order_items;
    END LOOP;

    SELECT count(*) INTO v_current FROM events;
    WHILE v_current < v_target_events LOOP
        v_add := least(v_batch, v_target_events - v_current);

        WITH positions AS (
            SELECT v_current + g AS position
            FROM generate_series(1, v_add) AS g
        )
        INSERT INTO events (event_type, customer_id, metadata, created_at)
        SELECT (ARRAY['page_view', 'page_view', 'page_view', 'search', 'cart', 'checkout', 'login', 'support'])[
                 1 + mod(position * 23, 8)::integer
               ],
               customer_row.id,
               jsonb_build_object(
                   'session', 'scale-session-' || mod(position * 65537, 2000000),
                   'device', (ARRAY['mobile', 'desktop', 'tablet'])[
                     1 + mod(position * 29, 3)::integer
                   ],
                   'country', (ARRAY['TR', 'DE', 'GB', 'US', 'AE'])[
                     1 + mod(position * 43, 5)::integer
                   ],
                   'seed', 'advisor-realistic-v1'
               ),
               now() - (mod(position * 1291, 15552000)::text || ' seconds')::interval
        FROM positions
        JOIN seed_customer_ids AS customer_row
          ON customer_row.ordinal = 1 + mod(position * 4099, v_customer_count);
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'events batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'events: % / %', v_current, v_target_events;
    END LOOP;

    SELECT count(*) INTO v_current FROM workload_inventory;
    WHILE v_current < v_target_inventory LOOP
        v_add := least(v_batch, v_target_inventory - v_current);

        WITH missing AS (
            SELECT product_row.id AS product_id,
                   warehouse.warehouse_id::smallint,
                   product_row.tenant_id,
                   product_row.ordinal
            FROM generate_series(1, 8) AS warehouse(warehouse_id)
            CROSS JOIN seed_product_ids AS product_row
            LEFT JOIN workload_inventory AS inventory
              ON inventory.product_id = product_row.id
             AND inventory.warehouse_id = warehouse.warehouse_id
            WHERE inventory.product_id IS NULL
            ORDER BY warehouse.warehouse_id, product_row.ordinal
            LIMIT v_add
        )
        INSERT INTO workload_inventory (
            product_id, warehouse_id, tenant_id, available, reserved, version, updated_at
        )
        SELECT product_id,
               warehouse_id,
               tenant_id,
               CASE WHEN ordinal <= 64 THEN 20 ELSE 50 + mod(ordinal * 13, 500)::integer END,
               mod(ordinal * 5 + warehouse_id, 12)::integer,
               0,
               now()
        FROM missing;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted = 0 THEN
            RAISE EXCEPTION 'inventory seed stalled below target';
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'workload_inventory: % / %', v_current, v_target_inventory;
    END LOOP;

    SELECT count(*) INTO v_current FROM workload_payments;
    WHILE v_current < v_target_payments LOOP
        v_add := least(v_batch, v_target_payments - v_current);

        WITH positions AS (
            SELECT v_current + g AS position
            FROM generate_series(1, v_add) AS g
        )
        INSERT INTO workload_payments (
            tenant_id, order_id, provider, status, amount, payload, created_at
        )
        SELECT mapping.tenant_id,
               order_row.id,
               (ARRAY['stripe', 'adyen', 'iyzico', 'bank'])[
                 1 + mod(position * 17, 4)::integer
               ],
               (ARRAY['captured', 'captured', 'captured', 'authorized', 'failed', 'refunded'])[
                 1 + mod(position * 13, 6)::integer
               ],
               (1999 + mod(position * 15485863, 500000))::numeric / 100,
               jsonb_build_object(
                   'attempt', 1 + mod(position, 3),
                   'riskBand', (ARRAY['low', 'medium', 'high'])[1 + mod(position * 7, 3)::integer],
                   'seed', 'advisor-realistic-v1'
               ),
               now() - (mod(position * 1009, 31536000)::text || ' seconds')::interval
        FROM positions
        JOIN seed_order_ids AS order_row
          ON order_row.ordinal = 1 + mod(position * 53, v_order_count)
        JOIN workload_customer_tenants AS mapping
          ON mapping.customer_id = order_row.customer_id;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'payments batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'workload_payments: % / %', v_current, v_target_payments;
    END LOOP;

    SELECT count(*) INTO v_current FROM workload_jobs;
    WHILE v_current < v_target_jobs LOOP
        v_add := least(v_batch, v_target_jobs - v_current);

        INSERT INTO workload_jobs (
            tenant_id, queue, status, priority, run_at, locked_at,
            attempts, payload, created_at
        )
        SELECT 1 + mod(v_current + g - 1, v_target_tenants),
               (ARRAY['email', 'invoice', 'webhook', 'fulfillment'])[
                 1 + mod((v_current + g) * 11, 4)::integer
               ],
               (ARRAY['ready', 'ready', 'ready', 'running', 'done', 'failed'])[
                 1 + mod((v_current + g) * 19, 6)::integer
               ],
               mod((v_current + g) * 7, 10)::smallint,
               now() + ((mod((v_current + g) * 97, 172800) - 86400)::text || ' seconds')::interval,
               CASE WHEN mod(v_current + g, 6) = 3 THEN now() ELSE NULL END,
               mod(v_current + g, 5)::integer,
               jsonb_build_object(
                   'reference', 'job-' || (v_current + g),
                   'seed', 'advisor-realistic-v1'
               ),
               now() - (mod((v_current + g) * 193, 2592000)::text || ' seconds')::interval
        FROM generate_series(1, v_add) AS g;
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        IF v_inserted <> v_add THEN
            RAISE EXCEPTION 'jobs batch inserted %, expected %', v_inserted, v_add;
        END IF;
        v_current := v_current + v_inserted;
        COMMIT;
        RAISE NOTICE 'workload_jobs: % / %', v_current, v_target_jobs;
    END LOOP;

    INSERT INTO advisor_workload_hotspots (id, value, updated_at)
    SELECT hotspot_id, 0, now()
    FROM generate_series(1, v_target_hotspots) AS hotspot_id
    ON CONFLICT (id) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    COMMIT;
    RAISE NOTICE 'advisor_workload_hotspots: inserted %, target %',
      v_inserted, v_target_hotspots;

    -- ERP catalog DDL is finite, identifier-only and runs solely inside this
    -- explicitly confirmed seeder.  Commit every 25 tables so one million
    -- fixture rows never become one catalog-wide transaction or long lock.
    FOR v_erp_table_number IN 1..v_target_erp_tables LOOP
        v_erp_table_name := format(
            'erp_entity_%s', lpad(v_erp_table_number::text, 4, '0')
        );
        v_erp_index_name := format(
            'idx_erp_entity_%s_tenant_state_time',
            lpad(v_erp_table_number::text, 4, '0')
        );

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.%I ('
            'id bigint PRIMARY KEY, '
            'tenant_id bigint NOT NULL, '
            'parent_id bigint NOT NULL, '
            'status_code smallint NOT NULL CHECK (status_code BETWEEN 0 AND 7), '
            'amount numeric(14,2) NOT NULL, '
            'external_key text NOT NULL, '
            'payload jsonb NOT NULL, '
            'created_at timestamptz NOT NULL, '
            'updated_at timestamptz NOT NULL'
            ')',
            'advisor_erp', v_erp_table_name
        );
        IF EXISTS (
            SELECT 1
            FROM pg_class AS index_relation
            JOIN pg_namespace AS namespace
              ON namespace.oid = index_relation.relnamespace
            LEFT JOIN pg_index AS index_record
              ON index_record.indexrelid = index_relation.oid
            LEFT JOIN pg_am AS access_method
              ON access_method.oid = index_relation.relam
            WHERE namespace.nspname = 'advisor_erp'
              AND index_relation.relname = v_erp_index_name
              AND (
                  index_record.indexrelid IS NULL
                  OR index_record.indrelid <> format(
                      '%I.%I', 'advisor_erp', v_erp_table_name
                  )::regclass
                  OR NOT index_record.indisvalid
                  OR NOT index_record.indisready
                  OR NOT index_record.indislive
                  OR index_record.indisunique
                  OR index_record.indisprimary
                  OR index_record.indisexclusion
                  OR access_method.amname IS DISTINCT FROM 'btree'
                  OR index_record.indnkeyatts <> 3
                  OR index_record.indnatts <> 3
                  OR index_record.indpred IS NOT NULL
                  OR pg_get_indexdef(index_record.indexrelid, 1, true)
                       <> 'tenant_id'
                  OR pg_get_indexdef(index_record.indexrelid, 2, true)
                       <> 'status_code'
                  OR pg_get_indexdef(index_record.indexrelid, 3, true)
                       <> 'updated_at'
                  OR index_record.indoption::text <> '0 0 3'
              )
        ) THEN
            EXECUTE format(
                'DROP INDEX %I.%I', 'advisor_erp', v_erp_index_name
            );
        END IF;
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I.%I '
            '(tenant_id, status_code, updated_at DESC)',
            v_erp_index_name, 'advisor_erp', v_erp_table_name
        );

        EXECUTE format(
            'INSERT INTO %I.%I ('
            'id, tenant_id, parent_id, status_code, amount, external_key, '
            'payload, created_at, updated_at'
            ') '
            'SELECT row_number::bigint, '
            '       1 + mod(row_number + $2 - 2, $3), '
            '       1 + mod(row_number * 13 + $2 - 2, $1), '
            '       mod(row_number * 7 + $2, 8)::smallint, '
            '       (100 + mod(row_number * 104729 + $2 * 97, 500000))::numeric / 100, '
            '       %L || lpad(row_number::text, 6, ''0''), '
            '       jsonb_build_object('
            '           ''channel'', (ARRAY[''web'', ''mobile'', ''store'', ''partner''])['
            '             1 + mod(row_number * 11 + $2, 4)::integer'
            '           ], '
            '           ''module'', $2, '
            '           ''seed'', ''advisor-erp-v1'''
            '       ), '
            '       now() - (mod(row_number * 1223 + $2, 63072000)::text || '' seconds'')::interval, '
            '       now() - (mod(row_number * 97 + $2, 7776000)::text || '' seconds'')::interval '
            'FROM generate_series(1, $1) AS row_number '
            'ON CONFLICT (id) DO NOTHING',
            'advisor_erp', v_erp_table_name,
            format('ERP-%s-', lpad(v_erp_table_number::text, 4, '0'))
        )
        USING v_erp_rows_per_table, v_erp_table_number, v_target_tenants;

        EXECUTE format(
            'SELECT count(*) FROM %I.%I',
            'advisor_erp', v_erp_table_name
        ) INTO v_erp_actual_rows;
        IF v_erp_actual_rows <> v_erp_rows_per_table THEN
            RAISE EXCEPTION 'ERP table % has % rows, expected exactly %',
              v_erp_table_name, v_erp_actual_rows, v_erp_rows_per_table;
        END IF;

        INSERT INTO advisor_erp.table_manifest (
            table_number, table_name, target_rows, actual_rows, seeded_at
        )
        VALUES (
            v_erp_table_number, v_erp_table_name,
            v_erp_rows_per_table, v_erp_actual_rows, clock_timestamp()
        )
        ON CONFLICT (table_number) DO UPDATE
        SET table_name = EXCLUDED.table_name,
            target_rows = EXCLUDED.target_rows,
            actual_rows = EXCLUDED.actual_rows,
            seeded_at = EXCLUDED.seeded_at;

        EXECUTE format(
            'ANALYZE %I.%I', 'advisor_erp', v_erp_table_name
        );
        IF mod(v_erp_table_number, 25) = 0 THEN
            COMMIT;
            RAISE NOTICE 'advisor_erp tables: % / %',
              v_erp_table_number, v_target_erp_tables;
        END IF;
    END LOOP;
END
$seed$;

CALL pg_temp.seed_advisor_realistic_workload();

GRANT USAGE ON SCHEMA public
  TO advisor_workload_reader, advisor_workload_writer, advisor_workload_reporter;

REVOKE ALL PRIVILEGES ON SCHEMA advisor_erp
  FROM PUBLIC, advisor_workload_reader, advisor_workload_writer,
       advisor_workload_reporter, advisor_workload_login;
GRANT USAGE ON SCHEMA advisor_erp
  TO advisor_workload_reader, advisor_workload_reporter;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA advisor_erp
  FROM PUBLIC, advisor_workload_reader, advisor_workload_writer,
       advisor_workload_reporter, advisor_workload_login;
GRANT SELECT ON ALL TABLES IN SCHEMA advisor_erp
  TO advisor_workload_reader, advisor_workload_reporter;

-- Reconcile privilege drift on every idempotent seed before granting the exact
-- read envelope.  Reader/reporter roles never need DML or sequence access.
REVOKE ALL PRIVILEGES ON
  customers, orders, order_items, events, workload_mutations,
  workload_tenants, workload_customer_tenants, workload_products,
  workload_inventory, workload_payments, workload_jobs,
  advisor_workload_hotspots, advisor_workload_seed_manifest
FROM advisor_workload_reader, advisor_workload_reporter;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public
FROM advisor_workload_reader, advisor_workload_reporter;

GRANT SELECT ON
  customers, orders, order_items, events, workload_mutations,
  workload_tenants, workload_customer_tenants, workload_products,
  workload_inventory, workload_payments, workload_jobs,
  advisor_workload_hotspots, advisor_workload_seed_manifest
TO advisor_workload_reader, advisor_workload_reporter;

-- Reconcile an older broad writer grant before applying the exact permissions
-- used by workload.py.  The writer cannot create/delete customers, orders,
-- products or tenancy/payment records.
REVOKE ALL PRIVILEGES ON
  customers, orders, order_items, events, workload_mutations,
  workload_tenants, workload_customer_tenants, workload_products,
  workload_inventory, workload_payments, workload_jobs,
  advisor_workload_hotspots
FROM advisor_workload_writer;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public
FROM advisor_workload_writer;

GRANT SELECT, INSERT, DELETE ON events TO advisor_workload_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON workload_mutations TO advisor_workload_writer;
GRANT SELECT ON customers TO advisor_workload_writer;
GRANT SELECT, UPDATE ON
  orders, workload_inventory, workload_jobs, advisor_workload_hotspots
TO advisor_workload_writer;
GRANT SELECT ON advisor_workload_seed_manifest TO advisor_workload_writer;
GRANT USAGE, SELECT ON events_id_seq, workload_mutations_id_seq
  TO advisor_workload_writer;

SELECT format('REVOKE %I FROM postgres', target_role.rolname)
FROM pg_auth_members AS membership
JOIN pg_roles AS target_role ON target_role.oid = membership.roleid
JOIN pg_roles AS member_role ON member_role.oid = membership.member
WHERE member_role.rolname = 'postgres'
  AND target_role.rolname IN (
      'advisor_workload_reader',
      'advisor_workload_writer',
      'advisor_workload_reporter'
  )
\gexec
REVOKE ALL PRIVILEGES ON
  customers, orders, order_items, events, workload_mutations,
  workload_tenants, workload_customer_tenants, workload_products,
  workload_inventory, workload_payments, workload_jobs,
  advisor_workload_hotspots, advisor_workload_seed_manifest
FROM advisor_workload_login;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public
FROM advisor_workload_login;
GRANT advisor_workload_reader, advisor_workload_writer,
  advisor_workload_reporter TO advisor_workload_login
  WITH INHERIT FALSE, SET TRUE;
GRANT pg_read_all_stats TO advisor_workload_login
  WITH INHERIT TRUE, SET FALSE;

SELECT format(
    'GRANT CONNECT ON DATABASE %I TO advisor_workload_login',
    current_database()
)
\gexec
GRANT USAGE ON SCHEMA public TO advisor_workload_login;
-- Preflight resolves max IDs before choosing a SET ROLE identity.  Keep this
-- direct login envelope read-only and limited to those seven bound tables.
GRANT SELECT ON
  customers, orders, events, workload_tenants, workload_products,
  workload_inventory, advisor_workload_hotspots
TO advisor_workload_login;

ANALYZE customers;
ANALYZE orders;
ANALYZE order_items;
ANALYZE events;
ANALYZE workload_mutations;
ANALYZE workload_tenants;
ANALYZE workload_customer_tenants;
ANALYZE workload_products;
ANALYZE workload_inventory;
ANALYZE workload_payments;
ANALYZE workload_jobs;
ANALYZE advisor_workload_hotspots;
ANALYZE advisor_workload_seed_manifest;
ANALYZE advisor_erp.table_manifest;

DO $verify$
DECLARE
    v_targets jsonb;
    v_actual jsonb;
    v_name text;
BEGIN
    SELECT target_counts INTO STRICT v_targets
    FROM advisor_workload_seed_manifest
    WHERE seed_key = 'active';

    v_actual := jsonb_build_object(
        'customers', (SELECT count(*) FROM customers),
        'orders', (SELECT count(*) FROM orders),
        'order_items', (SELECT count(*) FROM order_items),
        'events', (SELECT count(*) FROM events),
        'workload_tenants', (SELECT count(*) FROM workload_tenants),
        'workload_customer_tenants', (SELECT count(*) FROM workload_customer_tenants),
        'workload_products', (SELECT count(*) FROM workload_products),
        'workload_inventory', (SELECT count(*) FROM workload_inventory),
        'workload_payments', (SELECT count(*) FROM workload_payments),
        'workload_jobs', (SELECT count(*) FROM workload_jobs),
        'advisor_workload_hotspots', (SELECT count(*) FROM advisor_workload_hotspots),
        'advisor_erp_tables', (
            SELECT count(*)
            FROM pg_class AS relation
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'advisor_erp'
              AND relation.relkind IN ('r', 'p')
              AND relation.relname ~ '^erp_entity_[0-9]{4}$'
        ),
        'advisor_erp_rows', (
            SELECT COALESCE(sum(actual_rows), 0)
            FROM advisor_erp.table_manifest
        )
    );

    IF current_setting('advisor.seed.profile') = 'erp'
       AND (v_actual ->> 'advisor_erp_tables')::integer <> 500 THEN
        RAISE EXCEPTION 'ERP catalog must contain exactly 500 managed business tables';
    END IF;

    FOR v_name IN SELECT jsonb_object_keys(v_targets)
    LOOP
        IF (v_actual ->> v_name)::bigint < (v_targets ->> v_name)::bigint THEN
            RAISE EXCEPTION 'target verification failed for %: actual %, target %',
              v_name, v_actual ->> v_name, v_targets ->> v_name;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname IN (
            'advisor_workload_reader',
            'advisor_workload_writer',
            'advisor_workload_reporter'
        )
          AND rolcanlogin
    ) THEN
        RAISE EXCEPTION 'workload SET ROLE principals must remain NOLOGIN';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'advisor_workload_login'
          AND rolcanlogin
          AND NOT rolsuper
          AND NOT rolinherit
          AND NOT rolcreatedb
          AND NOT rolcreaterole
          AND NOT rolreplication
          AND NOT rolbypassrls
    ) THEN
        RAISE EXCEPTION 'advisor_workload_login security attributes are invalid';
    END IF;

    IF NOT pg_has_role('advisor_workload_login', 'advisor_workload_reader', 'SET')
       OR NOT pg_has_role('advisor_workload_login', 'advisor_workload_writer', 'SET')
       OR NOT pg_has_role('advisor_workload_login', 'advisor_workload_reporter', 'SET') THEN
        RAISE EXCEPTION 'workload login does not have SET OPTION on every workload role';
    END IF;

    IF NOT pg_has_role('advisor_workload_login', 'pg_read_all_stats', 'USAGE') THEN
        RAISE EXCEPTION 'workload login does not inherit pg_read_all_stats';
    END IF;

    IF NOT has_table_privilege('advisor_workload_writer', 'events', 'SELECT')
       OR NOT has_table_privilege('advisor_workload_writer', 'events', 'INSERT')
       OR NOT has_table_privilege('advisor_workload_writer', 'events', 'DELETE')
       OR NOT has_table_privilege('advisor_workload_writer', 'customers', 'SELECT')
       OR NOT has_table_privilege('advisor_workload_writer', 'workload_mutations', 'INSERT')
       OR NOT has_table_privilege('advisor_workload_writer', 'workload_mutations', 'UPDATE')
       OR NOT has_table_privilege('advisor_workload_writer', 'workload_mutations', 'DELETE')
       OR NOT has_table_privilege('advisor_workload_writer', 'orders', 'UPDATE')
       OR NOT has_table_privilege('advisor_workload_writer', 'workload_inventory', 'UPDATE')
       OR NOT has_table_privilege('advisor_workload_writer', 'workload_jobs', 'UPDATE')
       OR NOT has_table_privilege('advisor_workload_writer', 'advisor_workload_hotspots', 'UPDATE')
       OR NOT has_sequence_privilege('advisor_workload_writer', 'events_id_seq', 'USAGE')
       OR NOT has_sequence_privilege('advisor_workload_writer', 'workload_mutations_id_seq', 'USAGE') THEN
        RAISE EXCEPTION 'workload writer is missing a required narrow privilege';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(ARRAY[
            'advisor_workload_reader', 'advisor_workload_reporter'
        ]) AS role_name
        CROSS JOIN unnest(ARRAY[
            'customers', 'orders', 'order_items', 'events',
            'workload_mutations', 'workload_tenants',
            'workload_customer_tenants', 'workload_products',
            'workload_inventory', 'workload_payments', 'workload_jobs',
            'advisor_workload_hotspots', 'advisor_workload_seed_manifest'
        ]) AS relation_name
        WHERE has_table_privilege(role_name, relation_name, 'INSERT')
           OR has_table_privilege(role_name, relation_name, 'UPDATE')
           OR has_table_privilege(role_name, relation_name, 'DELETE')
    ) THEN
        RAISE EXCEPTION 'workload reader/reporter retains a forbidden DML privilege';
    END IF;

    IF NOT has_schema_privilege('advisor_workload_reader', 'advisor_erp', 'USAGE')
       OR NOT has_schema_privilege('advisor_workload_reporter', 'advisor_erp', 'USAGE')
       OR has_schema_privilege('advisor_workload_writer', 'advisor_erp', 'USAGE') THEN
        RAISE EXCEPTION 'ERP schema role envelope is invalid';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'advisor_erp'
          AND relation.relkind IN ('r', 'p')
          AND (
              NOT has_table_privilege(
                  'advisor_workload_reader', relation.oid, 'SELECT'
              )
              OR NOT has_table_privilege(
                  'advisor_workload_reporter', relation.oid, 'SELECT'
              )
          )
    ) THEN
        RAISE EXCEPTION 'ERP reader/reporter is missing SELECT privilege';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(ARRAY[
            'advisor_workload_reader', 'advisor_workload_reporter',
            'advisor_workload_writer'
        ]) AS role_name
        CROSS JOIN LATERAL (
            SELECT relation.oid
            FROM pg_class AS relation
            JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'advisor_erp'
              AND relation.relkind IN ('r', 'p')
        ) AS erp_relation
        WHERE has_table_privilege(role_name, erp_relation.oid, 'INSERT')
           OR has_table_privilege(role_name, erp_relation.oid, 'UPDATE')
           OR has_table_privilege(role_name, erp_relation.oid, 'DELETE')
           OR (
               role_name = 'advisor_workload_writer'
               AND has_table_privilege(role_name, erp_relation.oid, 'SELECT')
           )
    ) THEN
        RAISE EXCEPTION 'ERP workload roles retain a forbidden privilege';
    END IF;

    IF has_table_privilege('advisor_workload_writer', 'events', 'UPDATE')
       OR has_table_privilege('advisor_workload_writer', 'customers', 'INSERT')
       OR has_table_privilege('advisor_workload_writer', 'customers', 'UPDATE')
       OR has_table_privilege('advisor_workload_writer', 'customers', 'DELETE')
       OR has_table_privilege('advisor_workload_writer', 'orders', 'INSERT')
       OR has_table_privilege('advisor_workload_writer', 'orders', 'DELETE')
       OR has_table_privilege('advisor_workload_writer', 'order_items', 'INSERT')
       OR has_table_privilege('advisor_workload_writer', 'order_items', 'UPDATE')
       OR has_table_privilege('advisor_workload_writer', 'order_items', 'DELETE')
       OR has_table_privilege('advisor_workload_writer', 'workload_products', 'INSERT')
       OR has_table_privilege('advisor_workload_writer', 'workload_products', 'UPDATE')
       OR has_table_privilege('advisor_workload_writer', 'workload_products', 'DELETE')
       OR has_table_privilege('advisor_workload_writer', 'workload_tenants', 'INSERT')
       OR has_table_privilege('advisor_workload_writer', 'workload_tenants', 'UPDATE')
       OR has_table_privilege('advisor_workload_writer', 'workload_tenants', 'DELETE')
       OR has_table_privilege('advisor_workload_writer', 'workload_payments', 'INSERT')
       OR has_table_privilege('advisor_workload_writer', 'workload_payments', 'UPDATE')
       OR has_table_privilege('advisor_workload_writer', 'workload_payments', 'DELETE') THEN
        RAISE EXCEPTION 'workload writer retains a forbidden broad DML privilege';
    END IF;

    UPDATE advisor_workload_seed_manifest
    SET actual_counts = v_actual,
        status = 'READY',
        completed_at = clock_timestamp()
    WHERE seed_key = 'active';
END
$verify$;

SELECT profile,
       status,
       target_counts,
       actual_counts,
       started_at,
       completed_at
FROM advisor_workload_seed_manifest
WHERE seed_key = 'active';

SELECT pg_advisory_unlock(
           hashtextextended(
               'postgresql-advisor-realistic-seed:' || current_database(),
               0
           )
       ) AS seed_lock_released
\gset
\if :seed_lock_released
\else
  DO $abort$ BEGIN
      RAISE EXCEPTION 'realistic workload seed advisory lock release failed';
  END $abort$;
\endif
