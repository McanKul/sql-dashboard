\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS advisor AUTHORIZATION postgres;

CREATE TABLE IF NOT EXISTS advisor.query_annotations (
    server_id integer NOT NULL,
    database_id oid NOT NULL,
    query_id bigint NOT NULL,
    status text NOT NULL DEFAULT 'NEW'
        CHECK (status IN ('NEW', 'IN_REVIEW', 'COMPLETED', 'REJECTED')),
    note text,
    updated_by text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, database_id, query_id)
);

CREATE TABLE IF NOT EXISTS advisor.audit_log (
    id bigserial PRIMARY KEY,
    event_time timestamptz NOT NULL DEFAULT now(),
    actor text NOT NULL,
    action text NOT NULL,
    object_type text NOT NULL,
    object_key text NOT NULL,
    details jsonb
);

CREATE TABLE IF NOT EXISTS advisor.runtime_settings (
    key text PRIMARY KEY,
    value jsonb NOT NULL,
    description text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO advisor.runtime_settings (key, value, description)
VALUES
    ('retention_days', '90', 'PoWA remote sunucu retention hedefi'),
    ('default_window', '"24h"', 'Arayuz varsayilan analiz penceresi'),
    ('sql_visibility', '"authorized"', 'Tam SQL yalniz analyst/admin rolunde gorunur')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description;

CREATE OR REPLACE FUNCTION advisor.audit_annotation_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor
AS $$
DECLARE
    actor_name text := COALESCE(NULLIF(current_setting('app.actor', true), ''), NEW.updated_by);
BEGIN
    INSERT INTO advisor.audit_log(actor, action, object_type, object_key, details)
    VALUES (
        actor_name,
        CASE WHEN TG_OP = 'INSERT' THEN 'ANNOTATION_CREATED' ELSE 'ANNOTATION_UPDATED' END,
        'query',
        NEW.server_id || ':' || NEW.database_id || ':' || NEW.query_id,
        jsonb_build_object(
            'status', NEW.status,
            'note', NEW.note,
            'previousStatus', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE NULL END
        )
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_query_annotation_audit ON advisor.query_annotations;
CREATE TRIGGER trg_query_annotation_audit
AFTER INSERT OR UPDATE ON advisor.query_annotations
FOR EACH ROW EXECUTE FUNCTION advisor.audit_annotation_change();

-- PoWA'nin coalesce edilmis ve henuz coalesce edilmemis kayitlarini tek adapter
-- gorunumunde birlestirir. Uygulama PoWA tablo ayrintilarini bilmez.
CREATE OR REPLACE VIEW advisor.v_query_samples AS
SELECT
    h.srvid AS server_id,
    h.dbid AS database_id,
    h.queryid AS query_id,
    h.userid AS user_id,
    h.toplevel,
    (sample_record).ts AS sample_at,
    (sample_record).calls AS calls,
    (sample_record).total_exec_time AS total_exec_time_ms,
    (sample_record).shared_blks_hit AS shared_blocks_hit,
    (sample_record).shared_blks_read AS shared_blocks_read,
    (sample_record).temp_blks_written AS temp_blocks_written,
    (sample_record).wal_bytes AS wal_bytes
FROM "PoWA".powa_statements_history AS h
CROSS JOIN LATERAL unnest(h.records) AS sample_record
JOIN "PoWA".powa_statements AS statement
  ON statement.srvid = h.srvid
 AND statement.dbid = h.dbid
 AND statement.queryid = h.queryid
 AND statement.userid = h.userid
WHERE statement.query ~* '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)'
UNION ALL
SELECT
    c.srvid,
    c.dbid,
    c.queryid,
    c.userid,
    c.toplevel,
    (c.record).ts,
    (c.record).calls,
    (c.record).total_exec_time,
    (c.record).shared_blks_hit,
    (c.record).shared_blks_read,
    (c.record).temp_blks_written,
    (c.record).wal_bytes
FROM "PoWA".powa_statements_history_current AS c
JOIN "PoWA".powa_statements AS statement
  ON statement.srvid = c.srvid
 AND statement.dbid = c.dbid
 AND statement.queryid = c.queryid
 AND statement.userid = c.userid
WHERE statement.query ~* '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)';

CREATE OR REPLACE VIEW advisor.v_query_deltas AS
WITH ordered AS (
    SELECT
        samples.*,
        lag(calls) OVER metric_window AS previous_calls,
        lag(total_exec_time_ms) OVER metric_window AS previous_total_exec_time_ms,
        lag(shared_blocks_hit) OVER metric_window AS previous_shared_blocks_hit,
        lag(shared_blocks_read) OVER metric_window AS previous_shared_blocks_read,
        lag(temp_blocks_written) OVER metric_window AS previous_temp_blocks_written,
        lag(wal_bytes) OVER metric_window AS previous_wal_bytes
    FROM advisor.v_query_samples AS samples
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, query_id, user_id, toplevel
        ORDER BY sample_at
    )
)
SELECT
    server_id,
    database_id,
    query_id,
    user_id,
    toplevel,
    sample_at,
    CASE WHEN calls >= previous_calls THEN calls - previous_calls ELSE 0 END::bigint AS calls,
    CASE WHEN total_exec_time_ms >= previous_total_exec_time_ms
         THEN total_exec_time_ms - previous_total_exec_time_ms ELSE 0 END::double precision AS total_exec_time_ms,
    CASE WHEN shared_blocks_hit >= previous_shared_blocks_hit
         THEN shared_blocks_hit - previous_shared_blocks_hit ELSE 0 END::bigint AS shared_blocks_hit,
    CASE WHEN shared_blocks_read >= previous_shared_blocks_read
         THEN shared_blocks_read - previous_shared_blocks_read ELSE 0 END::bigint AS shared_blocks_read,
    CASE WHEN temp_blocks_written >= previous_temp_blocks_written
         THEN temp_blocks_written - previous_temp_blocks_written ELSE 0 END::bigint AS temp_blocks_written,
    CASE WHEN wal_bytes >= previous_wal_bytes
         THEN wal_bytes - previous_wal_bytes ELSE 0 END::numeric AS wal_bytes
FROM ordered
WHERE previous_calls IS NOT NULL;

CREATE OR REPLACE FUNCTION advisor.query_metrics(p_window interval DEFAULT interval '24 hours')
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    user_id oid,
    sql_text text,
    database_name text,
    calls bigint,
    total_exec_time_ms double precision,
    mean_exec_time_ms double precision,
    db_load_percent double precision,
    shared_blocks_hit bigint,
    shared_blocks_read bigint,
    temp_blocks_written bigint,
    wal_bytes numeric,
    previous_calls bigint,
    previous_mean_exec_time_ms double precision,
    regression_percent double precision,
    impact_score double precision,
    priority text,
    total_time_score double precision,
    physical_read_score double precision,
    call_frequency_score double precision,
    temp_write_score double precision,
    regression_score double precision,
    wal_score double precision,
    review_status text,
    note text,
    updated_by text,
    updated_at timestamptz
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH period AS (
    SELECT
        d.server_id,
        d.database_id,
        d.query_id,
        CASE WHEN count(DISTINCT d.user_id) = 1
             THEN min(d.user_id::bigint)::oid
             ELSE NULL::oid
        END AS user_id,
        sum(d.calls) FILTER (WHERE d.sample_at >= now() - p_window)::bigint AS calls,
        sum(d.total_exec_time_ms) FILTER (WHERE d.sample_at >= now() - p_window)::double precision AS total_exec_time_ms,
        sum(d.shared_blocks_hit) FILTER (WHERE d.sample_at >= now() - p_window)::bigint AS shared_blocks_hit,
        sum(d.shared_blocks_read) FILTER (WHERE d.sample_at >= now() - p_window)::bigint AS shared_blocks_read,
        sum(d.temp_blocks_written) FILTER (WHERE d.sample_at >= now() - p_window)::bigint AS temp_blocks_written,
        sum(d.wal_bytes) FILTER (WHERE d.sample_at >= now() - p_window)::numeric AS wal_bytes,
        sum(d.calls) FILTER (
            WHERE d.sample_at >= now() - (p_window * 2)
              AND d.sample_at < now() - p_window
        )::bigint AS previous_calls,
        sum(d.total_exec_time_ms) FILTER (
            WHERE d.sample_at >= now() - (p_window * 2)
              AND d.sample_at < now() - p_window
        )::double precision AS previous_total_exec_time_ms
    FROM advisor.v_query_deltas AS d
    WHERE d.sample_at >= now() - (p_window * 2)
      AND NOT EXISTS (
          SELECT 1
            FROM "PoWA".powa_databases AS excluded_db
           WHERE excluded_db.srvid = d.server_id
             AND excluded_db.oid = d.database_id
             AND excluded_db.datname = 'powa'
      )
      AND NOT EXISTS (
          SELECT 1
            FROM "PoWA".powa_catalog_roles AS excluded_role
           WHERE excluded_role.srvid = d.server_id
             AND excluded_role.oid = d.user_id
             AND excluded_role.rolname = 'powa_collector'
      )
    GROUP BY d.server_id, d.database_id, d.query_id
), enriched AS (
    SELECT
        p.*,
        s.query AS sql_text,
        db.datname::text AS database_name,
        p.total_exec_time_ms / NULLIF(p.calls, 0) AS mean_exec_time_ms,
        p.previous_total_exec_time_ms / NULLIF(p.previous_calls, 0) AS previous_mean_exec_time_ms,
        100.0 * (
            (p.total_exec_time_ms / NULLIF(p.calls, 0)) -
            (p.previous_total_exec_time_ms / NULLIF(p.previous_calls, 0))
        ) / NULLIF((p.previous_total_exec_time_ms / NULLIF(p.previous_calls, 0)), 0) AS regression_percent
    FROM period AS p
    JOIN (
        SELECT srvid, dbid, queryid, min(query) AS query
          FROM "PoWA".powa_statements
         GROUP BY srvid, dbid, queryid
    ) AS s
      ON s.srvid = p.server_id
     AND s.dbid = p.database_id
     AND s.queryid = p.query_id
    LEFT JOIN "PoWA".powa_databases AS db
      ON db.srvid = p.server_id AND db.oid = p.database_id
    WHERE COALESCE(p.calls, 0) > 0
      AND s.query !~* '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK|SET|SHOW)([[:space:]]|$)'
), normalized AS (
    SELECT
        e.*,
        100.0 * cume_dist() OVER (
            PARTITION BY e.server_id, e.database_id ORDER BY e.total_exec_time_ms
        ) AS total_time_score,
        CASE WHEN e.shared_blocks_read > 0
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id ORDER BY e.shared_blocks_read
             )
             ELSE 0 END AS physical_read_score,
        100.0 * cume_dist() OVER (
            PARTITION BY e.server_id, e.database_id ORDER BY e.calls
        ) AS call_frequency_score,
        CASE WHEN e.temp_blocks_written > 0
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id ORDER BY e.temp_blocks_written
             )
             ELSE 0 END AS temp_write_score,
        CASE WHEN COALESCE(e.regression_percent, 0) > 0 AND COALESCE(e.previous_calls, 0) >= 5
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id
                 ORDER BY greatest(COALESCE(e.regression_percent, 0), 0)
             )
             ELSE 0 END AS regression_score,
        CASE WHEN e.wal_bytes > 0
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id ORDER BY e.wal_bytes
             )
             ELSE 0 END AS wal_score,
        100.0 * e.total_exec_time_ms / NULLIF(
            sum(e.total_exec_time_ms) OVER (PARTITION BY e.server_id, e.database_id), 0
        ) AS db_load_percent
    FROM enriched AS e
), scored AS (
    SELECT
        n.*,
        0.40 * n.total_time_score
        + 0.20 * n.physical_read_score
        + 0.15 * n.call_frequency_score
        + 0.10 * n.temp_write_score
        + 0.10 * n.regression_score
        + 0.05 * n.wal_score AS impact_score
    FROM normalized AS n
)
SELECT
    sc.server_id,
    sc.database_id,
    sc.query_id,
    sc.user_id,
    sc.sql_text,
    COALESCE(sc.database_name, 'db-' || sc.database_id::text),
    sc.calls,
    sc.total_exec_time_ms,
    sc.mean_exec_time_ms,
    sc.db_load_percent,
    sc.shared_blocks_hit,
    sc.shared_blocks_read,
    sc.temp_blocks_written,
    sc.wal_bytes,
    COALESCE(sc.previous_calls, 0),
    sc.previous_mean_exec_time_ms,
    sc.regression_percent,
    sc.impact_score,
    CASE
        WHEN sc.impact_score >= 85 THEN 'CRITICAL'
        WHEN sc.impact_score >= 70 THEN 'HIGH'
        WHEN sc.impact_score >= 40 THEN 'MEDIUM'
        ELSE 'LOW'
    END,
    sc.total_time_score,
    sc.physical_read_score,
    sc.call_frequency_score,
    sc.temp_write_score,
    sc.regression_score,
    sc.wal_score,
    COALESCE(a.status, 'NEW'),
    a.note,
    a.updated_by,
    a.updated_at
FROM scored AS sc
LEFT JOIN advisor.query_annotations AS a
  ON a.server_id = sc.server_id
 AND a.database_id = sc.database_id
 AND a.query_id = sc.query_id;
$$;

CREATE OR REPLACE VIEW advisor.v_query_summary AS
SELECT * FROM advisor.query_metrics(interval '24 hours');

CREATE OR REPLACE VIEW advisor.v_query_regression AS
SELECT * FROM advisor.query_metrics(interval '24 hours')
WHERE regression_percent > 0 AND previous_calls >= 5;

CREATE OR REPLACE VIEW advisor.v_query_impact AS
SELECT * FROM advisor.query_metrics(interval '24 hours')
ORDER BY impact_score DESC;

CREATE OR REPLACE VIEW advisor.v_table_health AS
WITH latest AS (
    SELECT DISTINCT ON (t.srvid, t.dbid, t.relid)
        t.srvid AS server_id,
        t.dbid AS database_id,
        t.relid AS relation_id,
        (t.record).ts AS sample_at,
        (t.record).tbl_size AS table_size_bytes,
        (t.record).seq_scan AS seq_scan,
        (t.record).seq_tup_read AS seq_tup_read,
        (t.record).idx_scan AS idx_scan,
        (t.record).n_liv_tup AS live_tuples,
        (t.record).n_dead_tup AS dead_tuples,
        (t.record).last_autovacuum AS last_autovacuum
    FROM "PoWA".powa_all_tables_history_current AS t
    ORDER BY t.srvid, t.dbid, t.relid, (t.record).ts DESC
)
SELECT
    l.*,
    COALESCE(db.datname::text, 'db-' || l.database_id::text) AS database_name,
    COALESCE(ns.nspname || '.', '') || COALESCE(cls.relname, 'relation-' || l.relation_id::text) AS relation_name,
    round(100.0 * l.dead_tuples / NULLIF(l.live_tuples + l.dead_tuples, 0), 2) AS dead_tuple_percent,
    CASE
        WHEN l.dead_tuples > 1000 AND 100.0 * l.dead_tuples / NULLIF(l.live_tuples + l.dead_tuples, 0) >= 20 THEN 'CRITICAL'
        WHEN l.table_size_bytes >= 1048576 AND l.seq_scan >= 50 AND l.seq_tup_read > COALESCE(l.idx_scan, 0) * 100 THEN 'WARNING'
        WHEN l.dead_tuples > 200 OR (l.last_autovacuum IS NOT NULL AND l.last_autovacuum < now() - interval '7 days') THEN 'NOTICE'
        ELSE 'HEALTHY'
    END AS signal_level,
    CASE
        WHEN l.dead_tuples > 1000 AND 100.0 * l.dead_tuples / NULLIF(l.live_tuples + l.dead_tuples, 0) >= 20
            THEN 'Dead tuple egilimi yuksek; autovacuum ve uzun transaction incelenmeli.'
        WHEN l.table_size_bytes >= 1048576 AND l.seq_scan >= 50 AND l.seq_tup_read > COALESCE(l.idx_scan, 0) * 100
            THEN 'Buyuk tabloda yogun sequential scan; sorgu plani incelenmeli.'
        WHEN l.dead_tuples > 200 OR (l.last_autovacuum IS NOT NULL AND l.last_autovacuum < now() - interval '7 days')
            THEN 'Dead tuple veya gecikmis autovacuum sinyali var; autovacuum ayarlari ve uzun transactionlar incelenmeli.'
        WHEN l.last_autovacuum IS NULL
            THEN 'Henuz autovacuum kaydi yok; yazma hacmiyle birlikte izlenmeli.'
        ELSE 'Belirgin bir tablo sagligi sinyali yok.'
    END AS recommendation
FROM latest AS l
LEFT JOIN "PoWA".powa_databases AS db
  ON db.srvid = l.server_id AND db.oid = l.database_id
LEFT JOIN "PoWA".powa_catalog_class AS cls
  ON cls.srvid = l.server_id AND cls.dbid = l.database_id AND cls.oid = l.relation_id
LEFT JOIN "PoWA".powa_catalog_namespace AS ns
  ON ns.srvid = cls.srvid AND ns.dbid = cls.dbid AND ns.oid = cls.relnamespace
WHERE COALESCE(ns.nspname, 'public') !~ '^(pg_|information_schema$)'
  AND COALESCE(db.datname::text, '') <> 'powa';

CREATE OR REPLACE VIEW advisor.v_collector_health AS
SELECT
    s.id AS server_id,
    s.alias,
    s.hostname,
    s.port,
    s.frequency,
    s.retention,
    m.snapts AS last_snapshot_at,
    extract(epoch FROM now() - m.snapts)::double precision AS lag_seconds,
    COALESCE(m.errors, ARRAY[]::text[]) AS errors,
    CASE
        WHEN m.snapts = '-infinity'::timestamptz THEN 'STARTING'
        WHEN cardinality(COALESCE(m.errors, ARRAY[]::text[])) > 0 THEN 'DEGRADED'
        WHEN now() - m.snapts > make_interval(secs => s.frequency * 3) THEN 'STALE'
        ELSE 'HEALTHY'
    END AS status
FROM "PoWA".powa_servers AS s
JOIN "PoWA".powa_snapshot_metas AS m ON m.srvid = s.id
WHERE s.id > 0
  AND s.frequency > 0;

CREATE OR REPLACE VIEW advisor.v_long_transactions AS
WITH latest AS (
    SELECT DISTINCT ON (activity.srvid, (activity.record).pid)
        activity.srvid AS server_id,
        (activity.record).pid AS pid,
        (activity.record).datid AS database_id,
        (activity.record).application_name AS application_name,
        (activity.record).state AS state,
        (activity.record).xact_start AS transaction_started_at,
        (activity.record).clock_ts AS observed_at,
        extract(epoch FROM (activity.record).clock_ts - (activity.record).xact_start)::double precision AS age_seconds
    FROM "PoWA".powa_stat_activity_history_current AS activity
    WHERE (activity.record).pid IS NOT NULL
    ORDER BY activity.srvid, (activity.record).pid, (activity.record).ts DESC
)
SELECT
    latest.*,
    COALESCE(db.datname::text, 'db-' || latest.database_id::text) AS database_name
FROM latest
LEFT JOIN "PoWA".powa_databases AS db
  ON db.srvid = latest.server_id AND db.oid = latest.database_id
WHERE latest.transaction_started_at IS NOT NULL
  AND latest.age_seconds >= 30
  AND COALESCE(latest.state, '') <> 'idle'
  AND COALESCE(latest.application_name, '') !~ '^PoWA collector';

GRANT USAGE ON SCHEMA advisor TO advisor_api;
GRANT SELECT ON ALL TABLES IN SCHEMA advisor TO advisor_api;
GRANT INSERT, UPDATE ON advisor.query_annotations TO advisor_api;
GRANT INSERT ON advisor.audit_log TO advisor_api;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA advisor TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.query_metrics(interval) TO advisor_api;

ALTER DEFAULT PRIVILEGES IN SCHEMA advisor GRANT SELECT ON TABLES TO advisor_api;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor GRANT EXECUTE ON FUNCTIONS TO advisor_api;

COMMENT ON SCHEMA advisor IS
'Urun verileri ve PoWA surumunden bagimsiz adapter katmani. PoWA nesneleri degistirilmez.';
