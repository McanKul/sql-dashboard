#!/usr/bin/env bash
set -Eeuo pipefail

: "${POWA_COLLECTOR_PASSWORD:?POWA_COLLECTOR_PASSWORD tanimli olmali}"

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=collector_password="$POWA_COLLECTOR_PASSWORD" \
  --set=source_database="$POSTGRES_DB" <<'SQL'
CREATE ROLE powa_collector LOGIN PASSWORD :'collector_password';
GRANT CONNECT ON DATABASE :"source_database" TO powa_collector;
GRANT pg_read_all_stats TO powa_collector;

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
SQL

createdb --username "$POSTGRES_USER" powa

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname powa <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS "PoWA";
CREATE EXTENSION IF NOT EXISTS powa WITH SCHEMA "PoWA";

GRANT CONNECT ON DATABASE powa TO powa_collector;
GRANT USAGE ON SCHEMA "PoWA" TO powa_collector;
GRANT pg_read_all_stats TO powa_collector;
GRANT powa_snapshot TO powa_collector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA "PoWA" TO powa_collector;
SQL
