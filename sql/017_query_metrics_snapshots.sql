\set ON_ERROR_STOP on

-- Query metrics are expensive at ERP fingerprint cardinalities.  Keep one
-- persistent, atomically replaceable materialized snapshot per supported
-- dashboard window.  The refresh worker populates these outside the migration
-- transaction and uses REFRESH MATERIALIZED VIEW CONCURRENTLY after the first
-- population, so readers retain the previous complete generation.

CREATE MATERIALIZED VIEW advisor.query_metrics_snapshot_1h AS
SELECT metrics.*, servers.alias AS server_alias
FROM advisor.query_metrics(interval '1 hour') AS metrics
LEFT JOIN "PoWA".powa_servers AS servers
  ON servers.id = metrics.server_id
WITH NO DATA;

CREATE MATERIALIZED VIEW advisor.query_metrics_snapshot_24h AS
SELECT metrics.*, servers.alias AS server_alias
FROM advisor.query_metrics(interval '24 hours') AS metrics
LEFT JOIN "PoWA".powa_servers AS servers
  ON servers.id = metrics.server_id
WITH NO DATA;

CREATE MATERIALIZED VIEW advisor.query_metrics_snapshot_7d AS
SELECT metrics.*, servers.alias AS server_alias
FROM advisor.query_metrics(interval '7 days') AS metrics
LEFT JOIN "PoWA".powa_servers AS servers
  ON servers.id = metrics.server_id
WITH NO DATA;

CREATE MATERIALIZED VIEW advisor.query_metrics_snapshot_30d AS
SELECT metrics.*, servers.alias AS server_alias
FROM advisor.query_metrics(interval '30 days') AS metrics
LEFT JOIN "PoWA".powa_servers AS servers
  ON servers.id = metrics.server_id
WITH NO DATA;

CREATE UNIQUE INDEX query_metrics_snapshot_1h_identity_idx
    ON advisor.query_metrics_snapshot_1h
       (server_id, database_id, query_id, user_id) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX query_metrics_snapshot_24h_identity_idx
    ON advisor.query_metrics_snapshot_24h
       (server_id, database_id, query_id, user_id) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX query_metrics_snapshot_7d_identity_idx
    ON advisor.query_metrics_snapshot_7d
       (server_id, database_id, query_id, user_id) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX query_metrics_snapshot_30d_identity_idx
    ON advisor.query_metrics_snapshot_30d
       (server_id, database_id, query_id, user_id) NULLS NOT DISTINCT;

CREATE TABLE advisor.query_metrics_snapshot_state (
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

INSERT INTO advisor.query_metrics_snapshot_state (window_key)
VALUES ('1h'), ('24h'), ('7d'), ('30d');

REVOKE ALL ON advisor.query_metrics_snapshot_state FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON advisor.query_metrics_snapshot_state
    TO advisor_api;

GRANT SELECT, MAINTAIN ON
    advisor.query_metrics_snapshot_1h,
    advisor.query_metrics_snapshot_24h,
    advisor.query_metrics_snapshot_7d,
    advisor.query_metrics_snapshot_30d
TO advisor_api;

COMMENT ON TABLE advisor.query_metrics_snapshot_state IS
    'Persistent refresh status for precomputed dashboard query-metrics windows.';
