\set ON_ERROR_STOP on

-- Overview trend aggregation is also expensive at ERP cardinalities. Compute
-- database-level trends once, then derive server and fleet totals from those
-- small bucket sets. This avoids rescanning the same query histories for every
-- dashboard scope.

CREATE MATERIALIZED VIEW advisor.global_trend_snapshot_1h AS
WITH database_trends AS MATERIALIZED (
    SELECT
        database.srvid AS server_id,
        database.oid AS database_id,
        trend.bucket_at AS timestamp,
        trend.total_exec_time_ms,
        trend.calls
    FROM "PoWA".powa_databases AS database
    CROSS JOIN LATERAL advisor.query_trend(
        now() - interval '1 hour',
        interval '5 minutes',
        database.srvid,
        database.oid
    ) AS trend
    WHERE database.datname <> 'powa'
), all_scopes AS (
    SELECT * FROM database_trends
    UNION ALL
    SELECT
        server_id,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY server_id, timestamp
    UNION ALL
    SELECT
        NULL::integer,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY timestamp
)
SELECT * FROM all_scopes
WITH NO DATA;

CREATE MATERIALIZED VIEW advisor.global_trend_snapshot_24h AS
WITH database_trends AS MATERIALIZED (
    SELECT
        database.srvid AS server_id,
        database.oid AS database_id,
        trend.bucket_at AS timestamp,
        trend.total_exec_time_ms,
        trend.calls
    FROM "PoWA".powa_databases AS database
    CROSS JOIN LATERAL advisor.query_trend(
        now() - interval '24 hours',
        interval '1 hour',
        database.srvid,
        database.oid
    ) AS trend
    WHERE database.datname <> 'powa'
), all_scopes AS (
    SELECT * FROM database_trends
    UNION ALL
    SELECT
        server_id,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY server_id, timestamp
    UNION ALL
    SELECT
        NULL::integer,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY timestamp
)
SELECT * FROM all_scopes
WITH NO DATA;

CREATE MATERIALIZED VIEW advisor.global_trend_snapshot_7d AS
WITH database_trends AS MATERIALIZED (
    SELECT
        database.srvid AS server_id,
        database.oid AS database_id,
        trend.bucket_at AS timestamp,
        trend.total_exec_time_ms,
        trend.calls
    FROM "PoWA".powa_databases AS database
    CROSS JOIN LATERAL advisor.query_trend(
        now() - interval '7 days',
        interval '6 hours',
        database.srvid,
        database.oid
    ) AS trend
    WHERE database.datname <> 'powa'
), all_scopes AS (
    SELECT * FROM database_trends
    UNION ALL
    SELECT
        server_id,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY server_id, timestamp
    UNION ALL
    SELECT
        NULL::integer,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY timestamp
)
SELECT * FROM all_scopes
WITH NO DATA;

CREATE MATERIALIZED VIEW advisor.global_trend_snapshot_30d AS
WITH database_trends AS MATERIALIZED (
    SELECT
        database.srvid AS server_id,
        database.oid AS database_id,
        trend.bucket_at AS timestamp,
        trend.total_exec_time_ms,
        trend.calls
    FROM "PoWA".powa_databases AS database
    CROSS JOIN LATERAL advisor.query_trend(
        now() - interval '30 days',
        interval '1 day',
        database.srvid,
        database.oid
    ) AS trend
    WHERE database.datname <> 'powa'
), all_scopes AS (
    SELECT * FROM database_trends
    UNION ALL
    SELECT
        server_id,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY server_id, timestamp
    UNION ALL
    SELECT
        NULL::integer,
        NULL::oid,
        timestamp,
        sum(total_exec_time_ms)::double precision,
        sum(calls)::bigint
    FROM database_trends
    GROUP BY timestamp
)
SELECT * FROM all_scopes
WITH NO DATA;

CREATE UNIQUE INDEX global_trend_snapshot_1h_identity_idx
    ON advisor.global_trend_snapshot_1h
       (server_id, database_id, timestamp) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX global_trend_snapshot_24h_identity_idx
    ON advisor.global_trend_snapshot_24h
       (server_id, database_id, timestamp) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX global_trend_snapshot_7d_identity_idx
    ON advisor.global_trend_snapshot_7d
       (server_id, database_id, timestamp) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX global_trend_snapshot_30d_identity_idx
    ON advisor.global_trend_snapshot_30d
       (server_id, database_id, timestamp) NULLS NOT DISTINCT;

CREATE TABLE advisor.global_trend_snapshot_state (
    window_key text PRIMARY KEY
        CHECK (window_key IN ('1h', '24h', '7d', '30d')),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'refreshing', 'ready', 'failed')),
    refresh_started_at timestamptz,
    refreshed_at timestamptz,
    refresh_duration_ms bigint
        CHECK (refresh_duration_ms IS NULL OR refresh_duration_ms >= 0),
    row_count bigint
        CHECK (row_count IS NULL OR row_count >= 0),
    last_error text,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO advisor.global_trend_snapshot_state (window_key)
VALUES ('1h'), ('24h'), ('7d'), ('30d');

REVOKE ALL ON advisor.global_trend_snapshot_state FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON advisor.global_trend_snapshot_state
    TO advisor_api;

GRANT SELECT, MAINTAIN ON
    advisor.global_trend_snapshot_1h,
    advisor.global_trend_snapshot_24h,
    advisor.global_trend_snapshot_7d,
    advisor.global_trend_snapshot_30d
TO advisor_api;

COMMENT ON TABLE advisor.global_trend_snapshot_state IS
    'Persistent refresh status for precomputed overview trends and scopes.';
