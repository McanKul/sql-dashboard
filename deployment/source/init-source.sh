#!/usr/bin/env bash
set -Eeuo pipefail

: "${POWA_COLLECTOR_PASSWORD:?POWA_COLLECTOR_PASSWORD tanimli olmali}"
: "${ADVISOR_EVALUATOR_PASSWORD:?ADVISOR_EVALUATOR_PASSWORD tanimli olmali}"
: "${ADVISOR_JOIN_SOURCE_PASSWORD:?ADVISOR_JOIN_SOURCE_PASSWORD tanimli olmali}"

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=collector_password="$POWA_COLLECTOR_PASSWORD" \
  --set=evaluator_password="$ADVISOR_EVALUATOR_PASSWORD" \
  --set=join_snapshotter_password="$ADVISOR_JOIN_SOURCE_PASSWORD" \
  --set=source_database="$POSTGRES_DB" <<'SQL'
CREATE ROLE powa_collector LOGIN PASSWORD :'collector_password';
CREATE ROLE advisor_evaluator LOGIN PASSWORD :'evaluator_password'
  NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 2;
CREATE ROLE advisor_join_reader LOGIN PASSWORD :'join_snapshotter_password'
  NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 2;
ALTER ROLE advisor_evaluator SET default_transaction_read_only = on;
ALTER ROLE advisor_evaluator SET statement_timeout = '2s';
ALTER ROLE advisor_evaluator SET lock_timeout = '250ms';
ALTER ROLE advisor_evaluator SET idle_in_transaction_session_timeout = '3s';

GRANT CONNECT ON DATABASE :"source_database" TO powa_collector;
GRANT pg_read_all_stats TO powa_collector;
GRANT CONNECT ON DATABASE :"source_database" TO advisor_evaluator;

CREATE SCHEMA advisor_hypopg;
CREATE EXTENSION hypopg WITH SCHEMA advisor_hypopg;
REVOKE ALL ON SCHEMA advisor_hypopg FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA advisor_hypopg FROM PUBLIC;
GRANT USAGE ON SCHEMA advisor_hypopg TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_reset() TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_create_index(text) TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_relation_size(oid) TO advisor_evaluator;

CREATE TABLE customers (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    region text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers(id),
    status text NOT NULL,
    total numeric(12,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE order_items (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES orders(id),
    sku text NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2) NOT NULL
);

CREATE TABLE events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type text NOT NULL,
    customer_id bigint,
    metadata jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE workload_mutations (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    worker_pid integer NOT NULL,
    mutation_value integer NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO customers (name, region)
SELECT 'Musteri ' || g, (ARRAY['TR','EU','MENA','US'])[1 + (g % 4)]
FROM generate_series(1, 1200) AS g;

INSERT INTO orders (customer_id, status, total, created_at, payload)
SELECT 1 + (g % 1200),
       (ARRAY['pending','paid','shipped','cancelled'])[1 + (g % 4)],
       (20 + (g % 8000))::numeric / 3,
       now() - ((g % 45) || ' days')::interval,
       jsonb_build_object('channel', (ARRAY['web','mobile','store'])[1 + (g % 3)])
FROM generate_series(1, 18000) AS g;

INSERT INTO order_items (order_id, sku, quantity, unit_price)
SELECT 1 + (g % 18000), 'SKU-' || lpad((g % 900)::text, 4, '0'), 1 + (g % 5), (5 + (g % 300))::numeric
FROM generate_series(1, 42000) AS g;

INSERT INTO events (event_type, customer_id, metadata, created_at)
SELECT (ARRAY['page_view','checkout','search','login'])[1 + (g % 4)],
       1 + (g % 1200),
       jsonb_build_object('session', 's-' || g, 'device', (ARRAY['desktop','mobile'])[1 + (g % 2)]),
       now() - ((g % 604800) || ' seconds')::interval
FROM generate_series(1, 26000) AS g;

CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_order_items_order ON order_items(order_id);

-- Kullanici istegindeki tek fonksiyon: gercek ve tekrarlanabilir test yuku uretir.
CREATE OR REPLACE FUNCTION run_advisor_test_workload(iterations integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    i integer;
    mutation_id bigint;
    row_count bigint := 0;
    started_at timestamptz := clock_timestamp();
BEGIN
    IF iterations < 1 OR iterations > 1000 THEN
        RAISE EXCEPTION 'iterations 1 ile 1000 arasinda olmali';
    END IF;

    FOR i IN 1..iterations LOOP
        PERFORM count(*) FROM orders WHERE status = (ARRAY['pending','paid','shipped'])[1 + (i % 3)];
        PERFORM sum(total) FROM orders WHERE created_at > now() - ((1 + i % 30) || ' days')::interval;
        PERFORM c.region, count(*), avg(o.total)
          FROM customers c JOIN orders o ON o.customer_id = c.id
         WHERE o.status <> 'cancelled'
         GROUP BY c.region;
        PERFORM count(*) FROM events WHERE metadata ->> 'device' = CASE WHEN i % 2 = 0 THEN 'mobile' ELSE 'desktop' END;
        row_count := row_count + 4;
    END LOOP;

    -- Her fonksiyon cagrisi bir INSERT / UPDATE / DELETE deseni uretir.
    -- Eklenen satir ayni cagri icinde silindigi icin test tablosu sinirsiz buyumez.
    INSERT INTO workload_mutations (worker_pid, mutation_value, payload)
    VALUES (
        pg_backend_pid(),
        iterations,
        jsonb_build_object('source', 'run_advisor_test_workload')
    )
    RETURNING id INTO mutation_id;

    UPDATE workload_mutations
       SET mutation_value = mutation_value + 1,
           payload = payload || jsonb_build_object('updated', true),
           updated_at = clock_timestamp()
     WHERE id = mutation_id;

    DELETE FROM workload_mutations
     WHERE id = mutation_id;

    row_count := row_count + 3;

    RETURN jsonb_build_object(
        'ok', true,
        'iterations', iterations,
        'statementsExecuted', row_count,
        'durationMs', round(extract(epoch FROM clock_timestamp() - started_at) * 1000, 2)
    );
END;
$$;

COMMENT ON FUNCTION run_advisor_test_workload(integer) IS
'PoWA/pg_stat_statements entegrasyonunu dogrulamak icin kontrollu sorgu yuku uretir.';

GRANT USAGE ON SCHEMA public TO advisor_evaluator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO advisor_evaluator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO advisor_evaluator;
SQL

createdb --username "$POSTGRES_USER" powa

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname powa <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_qualstats;
CREATE EXTENSION IF NOT EXISTS pg_stat_kcache;
CREATE EXTENSION IF NOT EXISTS pg_wait_sampling;
CREATE SCHEMA IF NOT EXISTS "PoWA";
CREATE EXTENSION IF NOT EXISTS powa WITH SCHEMA "PoWA";
-- Normal fresh installs already populate powa_roles.  A dump/restore can leave
-- those mappings empty, in which case reuse the restored cluster roles and
-- rebuild the ACLs without trying to recreate them.
SELECT "PoWA".setup_powa_roles(true)
WHERE NOT EXISTS (
    SELECT 1 FROM "PoWA".powa_roles WHERE rolname IS NOT NULL
);

-- PoWA 5.2 kurulum sonunda mevcut destekli extension'lari etkinlestirir.
-- Acik cagri, tekrar calistirilan bootstrap/upgrade akisini da guvenli tutar.
SELECT "PoWA".powa_activate_extension(0, 'pg_qualstats');
SELECT "PoWA".powa_activate_extension(0, 'pg_stat_kcache');
SELECT "PoWA".powa_activate_extension(0, 'pg_wait_sampling');

GRANT CONNECT ON DATABASE powa TO powa_collector, advisor_join_reader;
GRANT USAGE ON SCHEMA "PoWA" TO powa_collector;
GRANT pg_read_all_stats TO powa_collector;
GRANT powa_snapshot TO powa_collector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA "PoWA" TO powa_collector;

-- Collector her remote snapshot sonrasinda sayaclari sifirlar. Reset fonksiyonu
-- PUBLIC'ten revoke edildigi icin extension semasinda acik yetki verilir.
SELECT format(
    'GRANT EXECUTE ON FUNCTION %I.pg_qualstats(), %I.pg_qualstats_reset() TO powa_collector',
    n.nspname,
    n.nspname
)
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_qualstats'
\gexec
SQL

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname powa \
  --file /opt/advisor/sql/003_join_snapshot_source.sql
