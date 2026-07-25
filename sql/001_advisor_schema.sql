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
    (sample_record).wal_bytes AS wal_bytes,
    (sample_record).rows AS rows
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
    (c.record).wal_bytes,
    (c.record).rows
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
        lag(wal_bytes) OVER metric_window AS previous_wal_bytes,
        lag(rows) OVER metric_window AS previous_rows
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
         THEN wal_bytes - previous_wal_bytes ELSE 0 END::numeric AS wal_bytes,
    CASE WHEN rows >= previous_rows THEN rows - previous_rows ELSE 0 END::bigint AS rows
FROM ordered
WHERE previous_calls IS NOT NULL;

-- API-facing variant with range predicates pushed into PoWA's storage tables.
-- One hour of baseline is read so the first in-window cumulative sample can be
-- converted to a delta without scanning the full retention period.
CREATE OR REPLACE FUNCTION advisor.query_deltas(p_start timestamptz)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    user_id oid,
    toplevel boolean,
    sample_at timestamptz,
    calls bigint,
    total_exec_time_ms double precision,
    shared_blocks_hit bigint,
    shared_blocks_read bigint,
    temp_blocks_written bigint,
    wal_bytes numeric,
    rows bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH samples AS (
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
        (sample_record).wal_bytes AS wal_bytes,
        (sample_record).rows AS rows
    FROM (
        SELECT history.*
        FROM "PoWA".powa_statements_history AS history
        WHERE history.coalesce_range && tstzrange(p_start - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    JOIN "PoWA".powa_statements AS statement
      ON statement.srvid = h.srvid
     AND statement.dbid = h.dbid
     AND statement.queryid = h.queryid
     AND statement.userid = h.userid
    WHERE (sample_record).ts >= p_start - interval '1 hour'
      AND statement.query ~* '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)'
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
        (c.record).wal_bytes,
        (c.record).rows
    FROM "PoWA".powa_statements_history_current AS c
    JOIN "PoWA".powa_statements AS statement
      ON statement.srvid = c.srvid
     AND statement.dbid = c.dbid
     AND statement.queryid = c.queryid
     AND statement.userid = c.userid
    WHERE (c.record).ts >= p_start - interval '1 hour'
      AND statement.query ~* '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)'
), ordered AS (
    SELECT
        samples.*,
        lag(calls) OVER metric_window AS previous_calls,
        lag(total_exec_time_ms) OVER metric_window AS previous_total_exec_time_ms,
        lag(shared_blocks_hit) OVER metric_window AS previous_shared_blocks_hit,
        lag(shared_blocks_read) OVER metric_window AS previous_shared_blocks_read,
        lag(temp_blocks_written) OVER metric_window AS previous_temp_blocks_written,
        lag(wal_bytes) OVER metric_window AS previous_wal_bytes,
        lag(rows) OVER metric_window AS previous_rows
    FROM samples
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
    CASE WHEN calls >= previous_calls THEN calls - previous_calls ELSE 0 END::bigint,
    CASE WHEN total_exec_time_ms >= previous_total_exec_time_ms THEN total_exec_time_ms - previous_total_exec_time_ms ELSE 0 END::double precision,
    CASE WHEN shared_blocks_hit >= previous_shared_blocks_hit THEN shared_blocks_hit - previous_shared_blocks_hit ELSE 0 END::bigint,
    CASE WHEN shared_blocks_read >= previous_shared_blocks_read THEN shared_blocks_read - previous_shared_blocks_read ELSE 0 END::bigint,
    CASE WHEN temp_blocks_written >= previous_temp_blocks_written THEN temp_blocks_written - previous_temp_blocks_written ELSE 0 END::bigint,
    CASE WHEN wal_bytes >= previous_wal_bytes THEN wal_bytes - previous_wal_bytes ELSE 0 END::numeric,
    CASE WHEN rows >= previous_rows THEN rows - previous_rows ELSE 0 END::bigint
FROM ordered
WHERE previous_calls IS NOT NULL
  AND sample_at >= p_start;
$$;

-- pg_stat_kcache counters are cumulative like pg_stat_statements counters.
-- Read both PoWA storage tiers and turn them into reset-safe per-snapshot
-- deltas.  CPU values are seconds in the extension/PoWA record and are kept
-- in seconds here; the public query adapter converts them to milliseconds.
CREATE OR REPLACE FUNCTION advisor.kcache_deltas(p_start timestamptz)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    user_id oid,
    toplevel boolean,
    sample_at timestamptz,
    exec_user_time_seconds double precision,
    exec_system_time_seconds double precision,
    filesystem_reads_bytes bigint,
    filesystem_writes_bytes bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH samples AS (
    SELECT
        h.srvid AS server_id,
        h.dbid AS database_id,
        h.queryid AS query_id,
        h.userid AS user_id,
        h.top AS toplevel,
        (sample_record).ts AS sample_at,
        (sample_record).exec_user_time AS exec_user_time_seconds,
        (sample_record).exec_system_time AS exec_system_time_seconds,
        (sample_record).exec_reads AS filesystem_reads_bytes,
        (sample_record).exec_writes AS filesystem_writes_bytes
    FROM "PoWA".powa_kcache_metrics AS h
    CROSS JOIN LATERAL unnest(h.metrics) AS sample_record
    WHERE h.coalesce_range && tstzrange(p_start - interval '1 hour', now(), '[]')
      AND (sample_record).ts >= p_start - interval '1 hour'
      AND (sample_record).ts <= now()
    UNION ALL
    SELECT
        c.srvid,
        c.dbid,
        c.queryid,
        c.userid,
        c.top,
        (c.metrics).ts,
        (c.metrics).exec_user_time,
        (c.metrics).exec_system_time,
        (c.metrics).exec_reads,
        (c.metrics).exec_writes
    FROM "PoWA".powa_kcache_metrics_current AS c
    WHERE (c.metrics).ts >= p_start - interval '1 hour'
      AND (c.metrics).ts <= now()
), ordered AS (
    SELECT
        samples.*,
        lag(exec_user_time_seconds) OVER metric_window AS previous_user_time,
        lag(exec_system_time_seconds) OVER metric_window AS previous_system_time,
        lag(filesystem_reads_bytes) OVER metric_window AS previous_reads,
        lag(filesystem_writes_bytes) OVER metric_window AS previous_writes
    FROM samples
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
    CASE WHEN exec_user_time_seconds >= previous_user_time
         THEN exec_user_time_seconds - previous_user_time ELSE 0 END,
    CASE WHEN exec_system_time_seconds >= previous_system_time
         THEN exec_system_time_seconds - previous_system_time ELSE 0 END,
    CASE
        WHEN filesystem_reads_bytes IS NULL OR previous_reads IS NULL THEN NULL
        WHEN filesystem_reads_bytes >= previous_reads THEN filesystem_reads_bytes - previous_reads
        ELSE 0
    END::bigint,
    CASE
        WHEN filesystem_writes_bytes IS NULL OR previous_writes IS NULL THEN NULL
        WHEN filesystem_writes_bytes >= previous_writes THEN filesystem_writes_bytes - previous_writes
        ELSE 0
    END::bigint
FROM ordered
WHERE previous_user_time IS NOT NULL
  AND previous_system_time IS NOT NULL
  AND sample_at >= p_start;
$$;

-- The return shape grew in iteration 1.  Drop the three convenience views first
-- so this migration remains rerunnable on an already initialized repository.
DROP VIEW IF EXISTS advisor.v_query_summary;
DROP VIEW IF EXISTS advisor.v_query_regression;
DROP VIEW IF EXISTS advisor.v_query_impact;
DROP FUNCTION IF EXISTS advisor.query_metrics(interval);

CREATE FUNCTION advisor.query_metrics(p_window interval DEFAULT interval '24 hours')
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    user_id oid,
    sql_text text,
    database_name text,
    calls bigint,
    rows bigint,
    rows_per_call double precision,
    total_exec_time_ms double precision,
    mean_exec_time_ms double precision,
    db_load_percent double precision,
    shared_blocks_hit bigint,
    shared_blocks_read bigint,
    temp_blocks_written bigint,
    wal_bytes numeric,
    kcache_available boolean,
    kcache_version text,
    kcache_data_available boolean,
    cpu_user_time_ms double precision,
    cpu_system_time_ms double precision,
    cpu_total_time_ms double precision,
    cpu_percent_of_exec_time double precision,
    filesystem_reads_bytes bigint,
    filesystem_writes_bytes bigint,
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
    score_details jsonb,
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
        sum(d.rows) FILTER (WHERE d.sample_at >= now() - p_window)::bigint AS rows,
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
        )::double precision AS previous_total_exec_time_ms,
        greatest(
            1.0,
            extract(epoch FROM (
                max(d.sample_at) FILTER (WHERE d.sample_at >= now() - p_window)
                - min(d.sample_at) FILTER (WHERE d.sample_at >= now() - p_window)
            )) / 3600.0
        )::double precision AS observation_hours
    FROM advisor.query_deltas(now() - (p_window * 2)) AS d
    WHERE d.sample_at >= now() - (p_window * 2)
      AND d.toplevel
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
             AND excluded_role.rolname IN ('powa_collector', 'advisor_evaluator')
      )
    GROUP BY d.server_id, d.database_id, d.query_id
), kcache_period AS (
    SELECT
        k.server_id,
        k.database_id,
        k.query_id,
        sum(k.exec_user_time_seconds) * 1000.0 AS cpu_user_time_ms,
        sum(k.exec_system_time_seconds) * 1000.0 AS cpu_system_time_ms,
        sum(k.filesystem_reads_bytes)::bigint AS filesystem_reads_bytes,
        sum(k.filesystem_writes_bytes)::bigint AS filesystem_writes_bytes
    FROM advisor.kcache_deltas(now() - p_window) AS k
    WHERE k.sample_at >= now() - p_window
      AND k.toplevel
    GROUP BY k.server_id, k.database_id, k.query_id
), kcache_capability AS (
    SELECT
        config.srvid AS server_id,
        bool_or(config.enabled) AS available,
        max(config.version)::text AS version
    FROM "PoWA".powa_extension_config AS config
    WHERE config.extname = 'pg_stat_kcache'
    GROUP BY config.srvid
), enriched AS (
    SELECT
        p.*,
        s.query AS sql_text,
        db.datname::text AS database_name,
        COALESCE(cap.available, false) AS kcache_available,
        cap.version AS kcache_version,
        k.query_id IS NOT NULL AS kcache_data_available,
        k.cpu_user_time_ms,
        k.cpu_system_time_ms,
        k.filesystem_reads_bytes,
        k.filesystem_writes_bytes,
        p.rows / NULLIF(p.calls, 0)::double precision AS rows_per_call,
        p.total_exec_time_ms / NULLIF(p.calls, 0) AS mean_exec_time_ms,
        p.previous_total_exec_time_ms / NULLIF(p.previous_calls, 0) AS previous_mean_exec_time_ms,
        100.0 * (
            (p.total_exec_time_ms / NULLIF(p.calls, 0)) -
            (p.previous_total_exec_time_ms / NULLIF(p.previous_calls, 0))
        ) / NULLIF((p.previous_total_exec_time_ms / NULLIF(p.previous_calls, 0)), 0) AS regression_percent
    FROM period AS p
    JOIN (
        SELECT statement.srvid, statement.dbid, statement.queryid, min(statement.query) AS query
          FROM "PoWA".powa_statements AS statement
         WHERE NOT EXISTS (
             SELECT 1
               FROM "PoWA".powa_catalog_roles AS excluded_role
              WHERE excluded_role.srvid = statement.srvid
                AND excluded_role.oid = statement.userid
                AND excluded_role.rolname IN ('powa_collector', 'advisor_evaluator')
         )
         GROUP BY statement.srvid, statement.dbid, statement.queryid
    ) AS s
      ON s.srvid = p.server_id
     AND s.dbid = p.database_id
     AND s.queryid = p.query_id
    LEFT JOIN "PoWA".powa_databases AS db
      ON db.srvid = p.server_id AND db.oid = p.database_id
    LEFT JOIN kcache_period AS k
      ON k.server_id = p.server_id
     AND k.database_id = p.database_id
     AND k.query_id = p.query_id
    LEFT JOIN kcache_capability AS cap ON cap.server_id = p.server_id
    WHERE COALESCE(p.calls, 0) > 0
      AND s.query !~* '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK|SET|SHOW)([[:space:]]|$)'
), ranked AS (
    SELECT
        e.*,
        100.0 * cume_dist() OVER (
            PARTITION BY e.server_id, e.database_id ORDER BY e.total_exec_time_ms
        ) AS total_time_percentile_score,
        CASE WHEN e.shared_blocks_read > 0
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id ORDER BY e.shared_blocks_read
             )
             ELSE 0 END AS physical_read_percentile_score,
        100.0 * cume_dist() OVER (
            PARTITION BY e.server_id, e.database_id ORDER BY e.calls
        ) AS call_frequency_percentile_score,
        CASE WHEN e.temp_blocks_written > 0
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id ORDER BY e.temp_blocks_written
             )
             ELSE 0 END AS temp_write_percentile_score,
        CASE WHEN COALESCE(e.regression_percent, 0) >= 20
                   AND COALESCE(e.previous_calls, 0) >= 20
                   AND e.calls >= 20
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id
                 ORDER BY greatest(COALESCE(e.regression_percent, 0), 0)
             )
             ELSE 0 END AS regression_percentile_score,
        CASE WHEN e.wal_bytes > 0
             THEN 100.0 * cume_dist() OVER (
                 PARTITION BY e.server_id, e.database_id ORDER BY e.wal_bytes
             )
             ELSE 0 END AS wal_percentile_score,
        least(1.0, e.total_exec_time_ms / NULLIF(60000.0 * e.observation_hours, 0)) AS total_time_volume_factor,
        least(1.0, e.shared_blocks_read / NULLIF(1024.0 * e.observation_hours, 0)) AS physical_read_volume_factor,
        least(1.0, e.calls / NULLIF(1000.0 * e.observation_hours, 0)) AS call_frequency_volume_factor,
        least(1.0, e.temp_blocks_written / NULLIF(512.0 * e.observation_hours, 0)) AS temp_write_volume_factor,
        CASE WHEN COALESCE(e.regression_percent, 0) >= 20
                  AND COALESCE(e.previous_calls, 0) >= 20
                  AND e.calls >= 20
             THEN least(1.0, e.regression_percent / 50.0)
             ELSE 0 END AS regression_volume_factor,
        least(1.0, e.wal_bytes / NULLIF(8388608.0 * e.observation_hours, 0)) AS wal_volume_factor,
        100.0 * e.total_exec_time_ms / NULLIF(
            sum(e.total_exec_time_ms) OVER (PARTITION BY e.server_id, e.database_id), 0
        ) AS db_load_percent
    FROM enriched AS e
), normalized AS (
    SELECT
        r.*,
        r.total_time_percentile_score * r.total_time_volume_factor AS total_time_score,
        r.physical_read_percentile_score * r.physical_read_volume_factor AS physical_read_score,
        r.call_frequency_percentile_score * r.call_frequency_volume_factor AS call_frequency_score,
        r.temp_write_percentile_score * r.temp_write_volume_factor AS temp_write_score,
        r.regression_percentile_score * r.regression_volume_factor AS regression_score,
        r.wal_percentile_score * r.wal_volume_factor AS wal_score
    FROM ranked AS r
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
    sc.rows,
    sc.rows_per_call,
    sc.total_exec_time_ms,
    sc.mean_exec_time_ms,
    sc.db_load_percent,
    sc.shared_blocks_hit,
    sc.shared_blocks_read,
    sc.temp_blocks_written,
    sc.wal_bytes,
    sc.kcache_available,
    sc.kcache_version,
    sc.kcache_data_available,
    sc.cpu_user_time_ms,
    sc.cpu_system_time_ms,
    sc.cpu_user_time_ms + sc.cpu_system_time_ms,
    100.0 * (sc.cpu_user_time_ms + sc.cpu_system_time_ms)
        / NULLIF(sc.total_exec_time_ms, 0),
    sc.filesystem_reads_bytes,
    sc.filesystem_writes_bytes,
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
    jsonb_build_object(
        'totalTime', jsonb_build_object(
            'percentileScore', sc.total_time_percentile_score,
            'volumeFactor', sc.total_time_volume_factor,
            'absoluteValue', sc.total_exec_time_ms,
            'volumeValue', sc.total_exec_time_ms,
            'fullScoreAt', 60000.0 * sc.observation_hours,
            'unit', 'ms'
        ),
        'physicalRead', jsonb_build_object(
            'percentileScore', sc.physical_read_percentile_score,
            'volumeFactor', sc.physical_read_volume_factor,
            'absoluteValue', sc.shared_blocks_read,
            'volumeValue', sc.shared_blocks_read,
            'fullScoreAt', 1024.0 * sc.observation_hours,
            'unit', 'blocks'
        ),
        'callFrequency', jsonb_build_object(
            'percentileScore', sc.call_frequency_percentile_score,
            'volumeFactor', sc.call_frequency_volume_factor,
            'absoluteValue', sc.calls,
            'volumeValue', sc.calls,
            'fullScoreAt', 1000.0 * sc.observation_hours,
            'unit', 'calls'
        ),
        'tempWrite', jsonb_build_object(
            'percentileScore', sc.temp_write_percentile_score,
            'volumeFactor', sc.temp_write_volume_factor,
            'absoluteValue', sc.temp_blocks_written,
            'volumeValue', sc.temp_blocks_written,
            'fullScoreAt', 512.0 * sc.observation_hours,
            'unit', 'blocks'
        ),
        'regression', jsonb_build_object(
            'percentileScore', sc.regression_percentile_score,
            'volumeFactor', sc.regression_volume_factor,
            'absoluteValue', sc.regression_percent,
            'volumeValue', sc.regression_percent,
            'fullScoreAt', 50,
            'unit', '%'
        ),
        'wal', jsonb_build_object(
            'percentileScore', sc.wal_percentile_score,
            'volumeFactor', sc.wal_volume_factor,
            'absoluteValue', sc.wal_bytes,
            'volumeValue', sc.wal_bytes,
            'fullScoreAt', 8388608.0 * sc.observation_hours,
            'unit', 'bytes'
        )
    ),
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
WHERE regression_percent >= 20 AND previous_calls >= 20 AND calls >= 20;

CREATE OR REPLACE VIEW advisor.v_query_impact AS
SELECT * FROM advisor.query_metrics(interval '24 hours')
ORDER BY impact_score DESC;

-- Index statistics are cumulative counters.  Convert both PoWA storage tiers to
-- one sample stream, then to reset-safe deltas before applying the API window.
CREATE OR REPLACE VIEW advisor.v_index_samples AS
SELECT
    h.srvid AS server_id,
    h.dbid AS database_id,
    h.relid AS relation_id,
    h.indexrelid AS index_id,
    (sample_record).ts AS sample_at,
    (sample_record).idx_size AS index_size_bytes,
    (sample_record).idx_scan AS scans,
    (sample_record).last_idx_scan AS last_scan_at,
    (sample_record).idx_tup_read AS tuples_read,
    (sample_record).idx_tup_fetch AS tuples_fetched,
    (sample_record).idx_blks_read AS blocks_read,
    (sample_record).idx_blks_hit AS blocks_hit
FROM "PoWA".powa_all_indexes_history AS h
CROSS JOIN LATERAL unnest(h.records) AS sample_record
UNION ALL
SELECT
    c.srvid,
    c.dbid,
    c.relid,
    c.indexrelid,
    (c.record).ts,
    (c.record).idx_size,
    (c.record).idx_scan,
    (c.record).last_idx_scan,
    (c.record).idx_tup_read,
    (c.record).idx_tup_fetch,
    (c.record).idx_blks_read,
    (c.record).idx_blks_hit
FROM "PoWA".powa_all_indexes_history_current AS c;

CREATE OR REPLACE VIEW advisor.v_index_deltas AS
WITH ordered AS (
    SELECT
        samples.*,
        lag(scans) OVER metric_window AS previous_scans,
        lag(tuples_read) OVER metric_window AS previous_tuples_read,
        lag(tuples_fetched) OVER metric_window AS previous_tuples_fetched,
        lag(blocks_read) OVER metric_window AS previous_blocks_read,
        lag(blocks_hit) OVER metric_window AS previous_blocks_hit
    FROM advisor.v_index_samples AS samples
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, relation_id, index_id
        ORDER BY sample_at
    )
)
SELECT
    server_id,
    database_id,
    relation_id,
    index_id,
    sample_at,
    index_size_bytes,
    last_scan_at,
    CASE WHEN scans >= previous_scans THEN scans - previous_scans ELSE COALESCE(scans, 0) END::bigint AS scans,
    CASE WHEN tuples_read >= previous_tuples_read THEN tuples_read - previous_tuples_read ELSE COALESCE(tuples_read, 0) END::bigint AS tuples_read,
    CASE WHEN tuples_fetched >= previous_tuples_fetched THEN tuples_fetched - previous_tuples_fetched ELSE COALESCE(tuples_fetched, 0) END::bigint AS tuples_fetched,
    CASE WHEN blocks_read >= previous_blocks_read THEN blocks_read - previous_blocks_read ELSE COALESCE(blocks_read, 0) END::bigint AS blocks_read,
    CASE WHEN blocks_hit >= previous_blocks_hit THEN blocks_hit - previous_blocks_hit ELSE COALESCE(blocks_hit, 0) END::bigint AS blocks_hit
FROM ordered
WHERE previous_scans IS NOT NULL;

CREATE OR REPLACE FUNCTION advisor.index_metrics(p_window interval DEFAULT interval '24 hours')
RETURNS TABLE (
    server_id integer,
    database_id oid,
    database_name text,
    relation_id oid,
    table_name text,
    index_id oid,
    index_name text,
    size_bytes bigint,
    scans bigint,
    tuples_read bigint,
    tuples_fetched bigint,
    blocks_read bigint,
    blocks_hit bigint,
    cache_hit_percent double precision,
    last_scan_at timestamptz,
    signal_level text,
    signal text,
    recommendation text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH samples AS (
    SELECT
        h.srvid AS server_id,
        h.dbid AS database_id,
        h.relid AS relation_id,
        h.indexrelid AS index_id,
        (sample_record).ts AS sample_at,
        (sample_record).idx_size AS index_size_bytes,
        (sample_record).idx_scan AS scans,
        (sample_record).last_idx_scan AS last_scan_at,
        (sample_record).idx_tup_read AS tuples_read,
        (sample_record).idx_tup_fetch AS tuples_fetched,
        (sample_record).idx_blks_read AS blocks_read,
        (sample_record).idx_blks_hit AS blocks_hit
    FROM (
        SELECT history.*
        FROM "PoWA".powa_all_indexes_history AS history
        WHERE history.coalesce_range && tstzrange(now() - p_window - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    WHERE (sample_record).ts >= now() - p_window - interval '1 hour'
    UNION ALL
    SELECT
        c.srvid,
        c.dbid,
        c.relid,
        c.indexrelid,
        (c.record).ts,
        (c.record).idx_size,
        (c.record).idx_scan,
        (c.record).last_idx_scan,
        (c.record).idx_tup_read,
        (c.record).idx_tup_fetch,
        (c.record).idx_blks_read,
        (c.record).idx_blks_hit
    FROM "PoWA".powa_all_indexes_history_current AS c
    WHERE (c.record).ts >= now() - p_window - interval '1 hour'
), ordered AS (
    SELECT
        samples.*,
        lag(scans) OVER metric_window AS previous_scans,
        lag(tuples_read) OVER metric_window AS previous_tuples_read,
        lag(tuples_fetched) OVER metric_window AS previous_tuples_fetched,
        lag(blocks_read) OVER metric_window AS previous_blocks_read,
        lag(blocks_hit) OVER metric_window AS previous_blocks_hit
    FROM samples
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, relation_id, index_id
        ORDER BY sample_at
    )
), deltas AS (
    SELECT
        server_id,
        database_id,
        relation_id,
        index_id,
        sample_at,
        index_size_bytes,
        last_scan_at,
        CASE WHEN scans >= previous_scans THEN scans - previous_scans ELSE COALESCE(scans, 0) END::bigint AS scans,
        CASE WHEN tuples_read >= previous_tuples_read THEN tuples_read - previous_tuples_read ELSE COALESCE(tuples_read, 0) END::bigint AS tuples_read,
        CASE WHEN tuples_fetched >= previous_tuples_fetched THEN tuples_fetched - previous_tuples_fetched ELSE COALESCE(tuples_fetched, 0) END::bigint AS tuples_fetched,
        CASE WHEN blocks_read >= previous_blocks_read THEN blocks_read - previous_blocks_read ELSE COALESCE(blocks_read, 0) END::bigint AS blocks_read,
        CASE WHEN blocks_hit >= previous_blocks_hit THEN blocks_hit - previous_blocks_hit ELSE COALESCE(blocks_hit, 0) END::bigint AS blocks_hit
    FROM ordered
    WHERE previous_scans IS NOT NULL
      AND sample_at >= now() - p_window
), metrics AS (
    SELECT
        d.server_id,
        d.database_id,
        d.relation_id,
        d.index_id,
        (array_agg(d.index_size_bytes ORDER BY d.sample_at DESC))[1]::bigint AS size_bytes,
        sum(d.scans)::bigint AS scans,
        sum(d.tuples_read)::bigint AS tuples_read,
        sum(d.tuples_fetched)::bigint AS tuples_fetched,
        sum(d.blocks_read)::bigint AS blocks_read,
        sum(d.blocks_hit)::bigint AS blocks_hit,
        max(d.last_scan_at) AS last_scan_at,
        count(*)::bigint AS sample_count,
        extract(epoch FROM max(d.sample_at) - min(d.sample_at)) / 3600.0 AS observed_hours
    FROM deltas AS d
    GROUP BY d.server_id, d.database_id, d.relation_id, d.index_id
), named AS (
    SELECT
        m.*,
        COALESCE(db.datname::text, 'db-' || m.database_id::text) AS database_name,
        COALESCE(ns.nspname || '.', '') || COALESCE(tbl.relname, 'relation-' || m.relation_id::text) AS table_name,
        COALESCE(ns.nspname || '.', '') || COALESCE(idx.relname, 'index-' || m.index_id::text) AS index_name
    FROM metrics AS m
    LEFT JOIN "PoWA".powa_databases AS db
      ON db.srvid = m.server_id AND db.oid = m.database_id
    LEFT JOIN "PoWA".powa_catalog_class AS tbl
      ON tbl.srvid = m.server_id AND tbl.dbid = m.database_id AND tbl.oid = m.relation_id
    LEFT JOIN "PoWA".powa_catalog_class AS idx
      ON idx.srvid = m.server_id AND idx.dbid = m.database_id AND idx.oid = m.index_id
    LEFT JOIN "PoWA".powa_catalog_namespace AS ns
      ON ns.srvid = tbl.srvid AND ns.dbid = tbl.dbid AND ns.oid = tbl.relnamespace
    WHERE COALESCE(ns.nspname, 'public') !~ '^(pg_|information_schema$)'
      AND COALESCE(db.datname::text, '') <> 'powa'
)
SELECT
    n.server_id,
    n.database_id,
    n.database_name,
    n.relation_id,
    n.table_name,
    n.index_id,
    n.index_name,
    n.size_bytes,
    n.scans,
    n.tuples_read,
    n.tuples_fetched,
    n.blocks_read,
    n.blocks_hit,
    100.0 * n.blocks_hit / NULLIF(n.blocks_hit + n.blocks_read, 0) AS cache_hit_percent,
    n.last_scan_at,
    CASE
        WHEN n.sample_count < 6 OR n.observed_hours < 1 THEN 'UNKNOWN'
        WHEN n.sample_count >= 6 AND n.observed_hours >= 1
             AND n.size_bytes >= 1048576 AND n.scans = 0 THEN 'WARNING'
        WHEN n.sample_count >= 6 AND n.observed_hours >= 1
             AND n.size_bytes >= 10485760 AND n.scans < 10 THEN 'NOTICE'
        ELSE 'HEALTHY'
    END AS signal_level,
    CASE
        WHEN n.sample_count < 6 OR n.observed_hours < 1 THEN 'INSUFFICIENT_DATA'
        WHEN n.sample_count >= 6 AND n.observed_hours >= 1
             AND n.size_bytes >= 1048576 AND n.scans = 0 THEN 'NO_SCANS_OBSERVED'
        WHEN n.sample_count >= 6 AND n.observed_hours >= 1
             AND n.size_bytes >= 10485760 AND n.scans < 10 THEN 'LOW_USAGE_OBSERVED'
        ELSE 'HEALTHY'
    END AS signal,
    CASE
        WHEN n.sample_count < 6 OR n.observed_hours < 1
            THEN 'Yeterli gozlem suresi yok; dusuk kullanim sinyali uretilmedi.'
        WHEN n.size_bytes >= 1048576 AND n.scans = 0
            THEN 'Secili pencerede tarama gozlenmedi. Bu bir DROP onerisi degildir; PK/unique/constraint gorevi ve daha uzun trafik penceresi dogrulanmalidir.'
        WHEN n.size_bytes >= 10485760 AND n.scans < 10
            THEN 'Boyutuna gore az tarama gozleniyor. Bu bir DROP onerisi degildir; yazma maliyeti ve daha uzun donem kullanimiyla birlikte incelenmelidir.'
        ELSE 'Secili pencerede belirgin bir dusuk kullanim sinyali yok.'
    END AS recommendation
FROM named AS n;
$$;

-- Database-level activity, cache and temporary-file counters.
CREATE OR REPLACE VIEW advisor.v_database_samples AS
SELECT
    h.srvid AS server_id,
    h.datid AS database_id,
    (sample_record).ts AS sample_at,
    (sample_record).numbackends AS current_backends,
    (sample_record).xact_commit AS transactions_committed,
    (sample_record).xact_rollback AS transactions_rolled_back,
    (sample_record).blks_read AS blocks_read,
    (sample_record).blks_hit AS blocks_hit,
    (sample_record).tup_returned AS tuples_returned,
    (sample_record).tup_fetched AS tuples_fetched,
    (sample_record).tup_inserted AS tuples_inserted,
    (sample_record).tup_updated AS tuples_updated,
    (sample_record).tup_deleted AS tuples_deleted,
    (sample_record).temp_files AS temp_files,
    (sample_record).temp_bytes AS temp_bytes,
    (sample_record).deadlocks AS deadlocks,
    (sample_record).blk_read_time AS block_read_time_ms,
    (sample_record).blk_write_time AS block_write_time_ms,
    (sample_record).stats_reset AS stats_reset
FROM "PoWA".powa_stat_database_history AS h
CROSS JOIN LATERAL unnest(h.records) AS sample_record
UNION ALL
SELECT
    c.srvid,
    c.datid,
    (c.record).ts,
    (c.record).numbackends,
    (c.record).xact_commit,
    (c.record).xact_rollback,
    (c.record).blks_read,
    (c.record).blks_hit,
    (c.record).tup_returned,
    (c.record).tup_fetched,
    (c.record).tup_inserted,
    (c.record).tup_updated,
    (c.record).tup_deleted,
    (c.record).temp_files,
    (c.record).temp_bytes,
    (c.record).deadlocks,
    (c.record).blk_read_time,
    (c.record).blk_write_time,
    (c.record).stats_reset
FROM "PoWA".powa_stat_database_history_current AS c;

CREATE OR REPLACE VIEW advisor.v_database_deltas AS
WITH ordered AS (
    SELECT
        samples.*,
        lag(transactions_committed) OVER metric_window AS previous_transactions_committed,
        lag(transactions_rolled_back) OVER metric_window AS previous_transactions_rolled_back,
        lag(blocks_read) OVER metric_window AS previous_blocks_read,
        lag(blocks_hit) OVER metric_window AS previous_blocks_hit,
        lag(tuples_returned) OVER metric_window AS previous_tuples_returned,
        lag(tuples_fetched) OVER metric_window AS previous_tuples_fetched,
        lag(tuples_inserted) OVER metric_window AS previous_tuples_inserted,
        lag(tuples_updated) OVER metric_window AS previous_tuples_updated,
        lag(tuples_deleted) OVER metric_window AS previous_tuples_deleted,
        lag(temp_files) OVER metric_window AS previous_temp_files,
        lag(temp_bytes) OVER metric_window AS previous_temp_bytes,
        lag(deadlocks) OVER metric_window AS previous_deadlocks,
        lag(block_read_time_ms) OVER metric_window AS previous_block_read_time_ms,
        lag(block_write_time_ms) OVER metric_window AS previous_block_write_time_ms
    FROM advisor.v_database_samples AS samples
    WINDOW metric_window AS (PARTITION BY server_id, database_id, stats_reset ORDER BY sample_at)
)
SELECT
    server_id,
    database_id,
    sample_at,
    current_backends,
    CASE WHEN transactions_committed >= previous_transactions_committed THEN transactions_committed - previous_transactions_committed ELSE COALESCE(transactions_committed, 0) END::bigint AS transactions_committed,
    CASE WHEN transactions_rolled_back >= previous_transactions_rolled_back THEN transactions_rolled_back - previous_transactions_rolled_back ELSE COALESCE(transactions_rolled_back, 0) END::bigint AS transactions_rolled_back,
    CASE WHEN blocks_read >= previous_blocks_read THEN blocks_read - previous_blocks_read ELSE COALESCE(blocks_read, 0) END::bigint AS blocks_read,
    CASE WHEN blocks_hit >= previous_blocks_hit THEN blocks_hit - previous_blocks_hit ELSE COALESCE(blocks_hit, 0) END::bigint AS blocks_hit,
    CASE WHEN tuples_returned >= previous_tuples_returned THEN tuples_returned - previous_tuples_returned ELSE COALESCE(tuples_returned, 0) END::bigint AS tuples_returned,
    CASE WHEN tuples_fetched >= previous_tuples_fetched THEN tuples_fetched - previous_tuples_fetched ELSE COALESCE(tuples_fetched, 0) END::bigint AS tuples_fetched,
    CASE WHEN tuples_inserted >= previous_tuples_inserted THEN tuples_inserted - previous_tuples_inserted ELSE COALESCE(tuples_inserted, 0) END::bigint AS tuples_inserted,
    CASE WHEN tuples_updated >= previous_tuples_updated THEN tuples_updated - previous_tuples_updated ELSE COALESCE(tuples_updated, 0) END::bigint AS tuples_updated,
    CASE WHEN tuples_deleted >= previous_tuples_deleted THEN tuples_deleted - previous_tuples_deleted ELSE COALESCE(tuples_deleted, 0) END::bigint AS tuples_deleted,
    CASE WHEN temp_files >= previous_temp_files THEN temp_files - previous_temp_files ELSE COALESCE(temp_files, 0) END::bigint AS temp_files,
    CASE WHEN temp_bytes >= previous_temp_bytes THEN temp_bytes - previous_temp_bytes ELSE COALESCE(temp_bytes, 0) END::bigint AS temp_bytes,
    CASE WHEN deadlocks >= previous_deadlocks THEN deadlocks - previous_deadlocks ELSE COALESCE(deadlocks, 0) END::bigint AS deadlocks,
    CASE WHEN block_read_time_ms >= previous_block_read_time_ms THEN block_read_time_ms - previous_block_read_time_ms ELSE COALESCE(block_read_time_ms, 0) END::double precision AS block_read_time_ms,
    CASE WHEN block_write_time_ms >= previous_block_write_time_ms THEN block_write_time_ms - previous_block_write_time_ms ELSE COALESCE(block_write_time_ms, 0) END::double precision AS block_write_time_ms
FROM ordered
WHERE previous_transactions_committed IS NOT NULL;

CREATE OR REPLACE FUNCTION advisor.database_io_metrics(p_window interval DEFAULT interval '24 hours')
RETURNS TABLE (
    server_id integer,
    database_id oid,
    database_name text,
    current_backends integer,
    transactions_committed bigint,
    transactions_rolled_back bigint,
    blocks_read bigint,
    blocks_hit bigint,
    cache_hit_percent double precision,
    temp_files bigint,
    temp_bytes bigint,
    deadlocks bigint,
    block_read_time_ms double precision,
    block_write_time_ms double precision,
    tuples_returned bigint,
    tuples_fetched bigint,
    tuples_inserted bigint,
    tuples_updated bigint,
    tuples_deleted bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH samples AS (
    SELECT
        h.srvid AS server_id,
        h.datid AS database_id,
        (sample_record).ts AS sample_at,
        (sample_record).numbackends AS current_backends,
        (sample_record).xact_commit AS transactions_committed,
        (sample_record).xact_rollback AS transactions_rolled_back,
        (sample_record).blks_read AS blocks_read,
        (sample_record).blks_hit AS blocks_hit,
        (sample_record).tup_returned AS tuples_returned,
        (sample_record).tup_fetched AS tuples_fetched,
        (sample_record).tup_inserted AS tuples_inserted,
        (sample_record).tup_updated AS tuples_updated,
        (sample_record).tup_deleted AS tuples_deleted,
        (sample_record).temp_files AS temp_files,
        (sample_record).temp_bytes AS temp_bytes,
        (sample_record).deadlocks AS deadlocks,
        (sample_record).blk_read_time AS block_read_time_ms,
        (sample_record).blk_write_time AS block_write_time_ms,
        (sample_record).stats_reset AS stats_reset
    FROM (
        SELECT history.*
        FROM "PoWA".powa_stat_database_history AS history
        WHERE history.coalesce_range && tstzrange(now() - p_window - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    WHERE (sample_record).ts >= now() - p_window - interval '1 hour'
    UNION ALL
    SELECT
        c.srvid,
        c.datid,
        (c.record).ts,
        (c.record).numbackends,
        (c.record).xact_commit,
        (c.record).xact_rollback,
        (c.record).blks_read,
        (c.record).blks_hit,
        (c.record).tup_returned,
        (c.record).tup_fetched,
        (c.record).tup_inserted,
        (c.record).tup_updated,
        (c.record).tup_deleted,
        (c.record).temp_files,
        (c.record).temp_bytes,
        (c.record).deadlocks,
        (c.record).blk_read_time,
        (c.record).blk_write_time,
        (c.record).stats_reset
    FROM "PoWA".powa_stat_database_history_current AS c
    WHERE (c.record).ts >= now() - p_window - interval '1 hour'
), ordered AS (
    SELECT
        samples.*,
        lag(transactions_committed) OVER metric_window AS previous_transactions_committed,
        lag(transactions_rolled_back) OVER metric_window AS previous_transactions_rolled_back,
        lag(blocks_read) OVER metric_window AS previous_blocks_read,
        lag(blocks_hit) OVER metric_window AS previous_blocks_hit,
        lag(tuples_returned) OVER metric_window AS previous_tuples_returned,
        lag(tuples_fetched) OVER metric_window AS previous_tuples_fetched,
        lag(tuples_inserted) OVER metric_window AS previous_tuples_inserted,
        lag(tuples_updated) OVER metric_window AS previous_tuples_updated,
        lag(tuples_deleted) OVER metric_window AS previous_tuples_deleted,
        lag(temp_files) OVER metric_window AS previous_temp_files,
        lag(temp_bytes) OVER metric_window AS previous_temp_bytes,
        lag(deadlocks) OVER metric_window AS previous_deadlocks,
        lag(block_read_time_ms) OVER metric_window AS previous_block_read_time_ms,
        lag(block_write_time_ms) OVER metric_window AS previous_block_write_time_ms
    FROM samples
    WINDOW metric_window AS (PARTITION BY server_id, database_id, stats_reset ORDER BY sample_at)
), deltas AS (
    SELECT
        server_id,
        database_id,
        sample_at,
        current_backends,
        CASE WHEN transactions_committed >= previous_transactions_committed THEN transactions_committed - previous_transactions_committed ELSE 0 END::bigint AS transactions_committed,
        CASE WHEN transactions_rolled_back >= previous_transactions_rolled_back THEN transactions_rolled_back - previous_transactions_rolled_back ELSE 0 END::bigint AS transactions_rolled_back,
        CASE WHEN blocks_read >= previous_blocks_read THEN blocks_read - previous_blocks_read ELSE 0 END::bigint AS blocks_read,
        CASE WHEN blocks_hit >= previous_blocks_hit THEN blocks_hit - previous_blocks_hit ELSE 0 END::bigint AS blocks_hit,
        CASE WHEN tuples_returned >= previous_tuples_returned THEN tuples_returned - previous_tuples_returned ELSE 0 END::bigint AS tuples_returned,
        CASE WHEN tuples_fetched >= previous_tuples_fetched THEN tuples_fetched - previous_tuples_fetched ELSE 0 END::bigint AS tuples_fetched,
        CASE WHEN tuples_inserted >= previous_tuples_inserted THEN tuples_inserted - previous_tuples_inserted ELSE 0 END::bigint AS tuples_inserted,
        CASE WHEN tuples_updated >= previous_tuples_updated THEN tuples_updated - previous_tuples_updated ELSE 0 END::bigint AS tuples_updated,
        CASE WHEN tuples_deleted >= previous_tuples_deleted THEN tuples_deleted - previous_tuples_deleted ELSE 0 END::bigint AS tuples_deleted,
        CASE WHEN temp_files >= previous_temp_files THEN temp_files - previous_temp_files ELSE 0 END::bigint AS temp_files,
        CASE WHEN temp_bytes >= previous_temp_bytes THEN temp_bytes - previous_temp_bytes ELSE 0 END::bigint AS temp_bytes,
        CASE WHEN deadlocks >= previous_deadlocks THEN deadlocks - previous_deadlocks ELSE 0 END::bigint AS deadlocks,
        CASE WHEN block_read_time_ms >= previous_block_read_time_ms THEN block_read_time_ms - previous_block_read_time_ms ELSE 0 END::double precision AS block_read_time_ms,
        CASE WHEN block_write_time_ms >= previous_block_write_time_ms THEN block_write_time_ms - previous_block_write_time_ms ELSE 0 END::double precision AS block_write_time_ms
    FROM ordered
    WHERE previous_transactions_committed IS NOT NULL
      AND sample_at >= now() - p_window
)
SELECT
    d.server_id,
    d.database_id,
    COALESCE(db.datname::text, 'db-' || d.database_id::text) AS database_name,
    (array_agg(d.current_backends ORDER BY d.sample_at DESC))[1]::integer AS current_backends,
    sum(d.transactions_committed)::bigint,
    sum(d.transactions_rolled_back)::bigint,
    sum(d.blocks_read)::bigint,
    sum(d.blocks_hit)::bigint,
    100.0 * sum(d.blocks_hit) / NULLIF(sum(d.blocks_hit) + sum(d.blocks_read), 0) AS cache_hit_percent,
    sum(d.temp_files)::bigint,
    sum(d.temp_bytes)::bigint,
    sum(d.deadlocks)::bigint,
    sum(d.block_read_time_ms)::double precision,
    sum(d.block_write_time_ms)::double precision,
    sum(d.tuples_returned)::bigint,
    sum(d.tuples_fetched)::bigint,
    sum(d.tuples_inserted)::bigint,
    sum(d.tuples_updated)::bigint,
    sum(d.tuples_deleted)::bigint
FROM deltas AS d
LEFT JOIN "PoWA".powa_databases AS db
  ON db.srvid = d.server_id AND db.oid = d.database_id
WHERE d.database_id <> 0
  AND COALESCE(db.datname::text, '') <> 'powa'
GROUP BY d.server_id, d.database_id, db.datname;
$$;

-- PostgreSQL 16+ pg_stat_io is cluster-wide and keyed by backend/object/context.
-- Byte counts are derived from operation deltas * op_bytes because pg_stat_io
-- exposes operation size rather than cumulative byte counters.
CREATE OR REPLACE VIEW advisor.v_io_samples AS
SELECT
    h.srvid AS server_id,
    h.backend_type,
    h.object,
    h.context,
    (sample_record).ts AS sample_at,
    (sample_record).reads AS reads,
    (sample_record).read_time AS read_time_ms,
    (sample_record).writes AS writes,
    (sample_record).write_time AS write_time_ms,
    (sample_record).writebacks AS writebacks,
    (sample_record).writeback_time AS writeback_time_ms,
    (sample_record).extends AS extends,
    (sample_record).extend_time AS extend_time_ms,
    (sample_record).op_bytes AS operation_bytes,
    (sample_record).hits AS hits,
    (sample_record).evictions AS evictions,
    (sample_record).reuses AS reuses,
    (sample_record).fsyncs AS fsyncs,
    (sample_record).fsync_time AS fsync_time_ms,
    (sample_record).read_bytes AS read_bytes,
    (sample_record).write_bytes AS write_bytes,
    (sample_record).extend_bytes AS extend_bytes,
    (sample_record).stats_reset AS stats_reset
FROM "PoWA".powa_stat_io_history AS h
CROSS JOIN LATERAL unnest(h.records) AS sample_record
UNION ALL
SELECT
    c.srvid,
    c.backend_type,
    c.object,
    c.context,
    (c.record).ts,
    (c.record).reads,
    (c.record).read_time,
    (c.record).writes,
    (c.record).write_time,
    (c.record).writebacks,
    (c.record).writeback_time,
    (c.record).extends,
    (c.record).extend_time,
    (c.record).op_bytes,
    (c.record).hits,
    (c.record).evictions,
    (c.record).reuses,
    (c.record).fsyncs,
    (c.record).fsync_time,
    (c.record).read_bytes,
    (c.record).write_bytes,
    (c.record).extend_bytes,
    (c.record).stats_reset
FROM "PoWA".powa_stat_io_history_current AS c;

CREATE OR REPLACE VIEW advisor.v_io_deltas AS
WITH ordered AS (
    SELECT
        samples.*,
        lag(reads) OVER metric_window AS previous_reads,
        lag(read_time_ms) OVER metric_window AS previous_read_time_ms,
        lag(writes) OVER metric_window AS previous_writes,
        lag(write_time_ms) OVER metric_window AS previous_write_time_ms,
        lag(writebacks) OVER metric_window AS previous_writebacks,
        lag(writeback_time_ms) OVER metric_window AS previous_writeback_time_ms,
        lag(extends) OVER metric_window AS previous_extends,
        lag(extend_time_ms) OVER metric_window AS previous_extend_time_ms,
        lag(hits) OVER metric_window AS previous_hits,
        lag(evictions) OVER metric_window AS previous_evictions,
        lag(reuses) OVER metric_window AS previous_reuses,
        lag(fsyncs) OVER metric_window AS previous_fsyncs,
        lag(fsync_time_ms) OVER metric_window AS previous_fsync_time_ms,
        lag(read_bytes) OVER metric_window AS previous_read_bytes,
        lag(write_bytes) OVER metric_window AS previous_write_bytes,
        lag(extend_bytes) OVER metric_window AS previous_extend_bytes
    FROM advisor.v_io_samples AS samples
    WINDOW metric_window AS (
        PARTITION BY server_id, backend_type, object, context, stats_reset
        ORDER BY sample_at
    )
)
SELECT
    server_id,
    backend_type,
    object,
    context,
    sample_at,
    operation_bytes,
    CASE WHEN reads >= previous_reads THEN reads - previous_reads ELSE COALESCE(reads, 0) END::bigint AS reads,
    CASE WHEN read_time_ms >= previous_read_time_ms THEN read_time_ms - previous_read_time_ms ELSE COALESCE(read_time_ms, 0) END::double precision AS read_time_ms,
    CASE WHEN writes >= previous_writes THEN writes - previous_writes ELSE COALESCE(writes, 0) END::bigint AS writes,
    CASE WHEN write_time_ms >= previous_write_time_ms THEN write_time_ms - previous_write_time_ms ELSE COALESCE(write_time_ms, 0) END::double precision AS write_time_ms,
    CASE WHEN writebacks >= previous_writebacks THEN writebacks - previous_writebacks ELSE COALESCE(writebacks, 0) END::bigint AS writebacks,
    CASE WHEN writeback_time_ms >= previous_writeback_time_ms THEN writeback_time_ms - previous_writeback_time_ms ELSE COALESCE(writeback_time_ms, 0) END::double precision AS writeback_time_ms,
    CASE WHEN extends >= previous_extends THEN extends - previous_extends ELSE COALESCE(extends, 0) END::bigint AS extends,
    CASE WHEN extend_time_ms >= previous_extend_time_ms THEN extend_time_ms - previous_extend_time_ms ELSE COALESCE(extend_time_ms, 0) END::double precision AS extend_time_ms,
    CASE WHEN hits >= previous_hits THEN hits - previous_hits ELSE COALESCE(hits, 0) END::bigint AS hits,
    CASE WHEN evictions >= previous_evictions THEN evictions - previous_evictions ELSE COALESCE(evictions, 0) END::bigint AS evictions,
    CASE WHEN reuses >= previous_reuses THEN reuses - previous_reuses ELSE COALESCE(reuses, 0) END::bigint AS reuses,
    CASE WHEN fsyncs >= previous_fsyncs THEN fsyncs - previous_fsyncs ELSE COALESCE(fsyncs, 0) END::bigint AS fsyncs,
    CASE WHEN fsync_time_ms >= previous_fsync_time_ms THEN fsync_time_ms - previous_fsync_time_ms ELSE COALESCE(fsync_time_ms, 0) END::double precision AS fsync_time_ms,
    CASE WHEN read_bytes >= previous_read_bytes THEN read_bytes - previous_read_bytes ELSE COALESCE(read_bytes, 0) END::numeric AS read_bytes,
    CASE WHEN write_bytes >= previous_write_bytes THEN write_bytes - previous_write_bytes ELSE COALESCE(write_bytes, 0) END::numeric AS write_bytes,
    CASE WHEN extend_bytes >= previous_extend_bytes THEN extend_bytes - previous_extend_bytes ELSE COALESCE(extend_bytes, 0) END::numeric AS extend_bytes
FROM ordered
WHERE previous_reads IS NOT NULL OR previous_writes IS NOT NULL OR previous_hits IS NOT NULL;

CREATE OR REPLACE FUNCTION advisor.io_metrics(p_window interval DEFAULT interval '24 hours')
RETURNS TABLE (
    server_id integer,
    backend_type text,
    object text,
    context text,
    reads bigint,
    read_bytes numeric,
    read_time_ms double precision,
    writes bigint,
    write_bytes numeric,
    write_time_ms double precision,
    writebacks bigint,
    writeback_time_ms double precision,
    extends bigint,
    extend_bytes numeric,
    extend_time_ms double precision,
    hits bigint,
    evictions bigint,
    reuses bigint,
    fsyncs bigint,
    fsync_time_ms double precision
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH samples AS (
    SELECT
        h.srvid AS server_id,
        h.backend_type,
        h.object,
        h.context,
        (sample_record).ts AS sample_at,
        (sample_record).reads AS reads,
        (sample_record).read_time AS read_time_ms,
        (sample_record).writes AS writes,
        (sample_record).write_time AS write_time_ms,
        (sample_record).writebacks AS writebacks,
        (sample_record).writeback_time AS writeback_time_ms,
        (sample_record).extends AS extends,
        (sample_record).extend_time AS extend_time_ms,
        (sample_record).op_bytes AS operation_bytes,
        (sample_record).hits AS hits,
        (sample_record).evictions AS evictions,
        (sample_record).reuses AS reuses,
        (sample_record).fsyncs AS fsyncs,
        (sample_record).fsync_time AS fsync_time_ms,
        (sample_record).read_bytes AS read_bytes,
        (sample_record).write_bytes AS write_bytes,
        (sample_record).extend_bytes AS extend_bytes,
        (sample_record).stats_reset AS stats_reset
    FROM (
        SELECT history.*
        FROM "PoWA".powa_stat_io_history AS history
        WHERE history.coalesce_range && tstzrange(now() - p_window - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    WHERE (sample_record).ts >= now() - p_window - interval '1 hour'
    UNION ALL
    SELECT
        c.srvid,
        c.backend_type,
        c.object,
        c.context,
        (c.record).ts,
        (c.record).reads,
        (c.record).read_time,
        (c.record).writes,
        (c.record).write_time,
        (c.record).writebacks,
        (c.record).writeback_time,
        (c.record).extends,
        (c.record).extend_time,
        (c.record).op_bytes,
        (c.record).hits,
        (c.record).evictions,
        (c.record).reuses,
        (c.record).fsyncs,
        (c.record).fsync_time,
        (c.record).read_bytes,
        (c.record).write_bytes,
        (c.record).extend_bytes,
        (c.record).stats_reset
    FROM "PoWA".powa_stat_io_history_current AS c
    WHERE (c.record).ts >= now() - p_window - interval '1 hour'
), ordered AS (
    SELECT
        samples.*,
        lag(reads) OVER metric_window AS previous_reads,
        lag(read_time_ms) OVER metric_window AS previous_read_time_ms,
        lag(writes) OVER metric_window AS previous_writes,
        lag(write_time_ms) OVER metric_window AS previous_write_time_ms,
        lag(writebacks) OVER metric_window AS previous_writebacks,
        lag(writeback_time_ms) OVER metric_window AS previous_writeback_time_ms,
        lag(extends) OVER metric_window AS previous_extends,
        lag(extend_time_ms) OVER metric_window AS previous_extend_time_ms,
        lag(hits) OVER metric_window AS previous_hits,
        lag(evictions) OVER metric_window AS previous_evictions,
        lag(reuses) OVER metric_window AS previous_reuses,
        lag(fsyncs) OVER metric_window AS previous_fsyncs,
        lag(fsync_time_ms) OVER metric_window AS previous_fsync_time_ms,
        lag(read_bytes) OVER metric_window AS previous_read_bytes,
        lag(write_bytes) OVER metric_window AS previous_write_bytes,
        lag(extend_bytes) OVER metric_window AS previous_extend_bytes
    FROM samples
    WINDOW metric_window AS (
        PARTITION BY server_id, backend_type, object, context, stats_reset
        ORDER BY sample_at
    )
), deltas AS (
    SELECT
        server_id,
        backend_type,
        object,
        context,
        sample_at,
        operation_bytes,
        CASE WHEN reads >= previous_reads THEN reads - previous_reads ELSE 0 END::bigint AS reads,
        CASE WHEN read_time_ms >= previous_read_time_ms THEN read_time_ms - previous_read_time_ms ELSE 0 END::double precision AS read_time_ms,
        CASE WHEN writes >= previous_writes THEN writes - previous_writes ELSE 0 END::bigint AS writes,
        CASE WHEN write_time_ms >= previous_write_time_ms THEN write_time_ms - previous_write_time_ms ELSE 0 END::double precision AS write_time_ms,
        CASE WHEN writebacks >= previous_writebacks THEN writebacks - previous_writebacks ELSE 0 END::bigint AS writebacks,
        CASE WHEN writeback_time_ms >= previous_writeback_time_ms THEN writeback_time_ms - previous_writeback_time_ms ELSE 0 END::double precision AS writeback_time_ms,
        CASE WHEN extends >= previous_extends THEN extends - previous_extends ELSE 0 END::bigint AS extends,
        CASE WHEN extend_time_ms >= previous_extend_time_ms THEN extend_time_ms - previous_extend_time_ms ELSE 0 END::double precision AS extend_time_ms,
        CASE WHEN hits >= previous_hits THEN hits - previous_hits ELSE 0 END::bigint AS hits,
        CASE WHEN evictions >= previous_evictions THEN evictions - previous_evictions ELSE 0 END::bigint AS evictions,
        CASE WHEN reuses >= previous_reuses THEN reuses - previous_reuses ELSE 0 END::bigint AS reuses,
        CASE WHEN fsyncs >= previous_fsyncs THEN fsyncs - previous_fsyncs ELSE 0 END::bigint AS fsyncs,
        CASE WHEN fsync_time_ms >= previous_fsync_time_ms THEN fsync_time_ms - previous_fsync_time_ms ELSE 0 END::double precision AS fsync_time_ms,
        CASE WHEN read_bytes >= previous_read_bytes THEN read_bytes - previous_read_bytes ELSE 0 END::numeric AS read_bytes,
        CASE WHEN write_bytes >= previous_write_bytes THEN write_bytes - previous_write_bytes ELSE 0 END::numeric AS write_bytes,
        CASE WHEN extend_bytes >= previous_extend_bytes THEN extend_bytes - previous_extend_bytes ELSE 0 END::numeric AS extend_bytes
    FROM ordered
    WHERE (previous_reads IS NOT NULL OR previous_writes IS NOT NULL OR previous_hits IS NOT NULL)
      AND sample_at >= now() - p_window
)
SELECT
    d.server_id,
    d.backend_type,
    d.object,
    d.context,
    sum(d.reads)::bigint,
    sum(CASE WHEN COALESCE(d.operation_bytes, 0) > 0
             THEN d.reads::numeric * d.operation_bytes
             ELSE d.read_bytes END)::numeric AS read_bytes,
    sum(d.read_time_ms)::double precision,
    sum(d.writes)::bigint,
    sum(CASE WHEN COALESCE(d.operation_bytes, 0) > 0
             THEN d.writes::numeric * d.operation_bytes
             ELSE d.write_bytes END)::numeric AS write_bytes,
    sum(d.write_time_ms)::double precision,
    sum(d.writebacks)::bigint,
    sum(d.writeback_time_ms)::double precision,
    sum(d.extends)::bigint,
    sum(CASE WHEN COALESCE(d.operation_bytes, 0) > 0
             THEN d.extends::numeric * d.operation_bytes
             ELSE d.extend_bytes END)::numeric AS extend_bytes,
    sum(d.extend_time_ms)::double precision,
    sum(d.hits)::bigint,
    sum(d.evictions)::bigint,
    sum(d.reuses)::bigint,
    sum(d.fsyncs)::bigint,
    sum(d.fsync_time_ms)::double precision
FROM deltas AS d
GROUP BY d.server_id, d.backend_type, d.object, d.context;
$$;

-- WAL/checkpointer/bgwriter counters are source-server telemetry and do not have
-- a database dimension.  One adapter function keeps their reset handling and
-- naming stable for the API.
CREATE OR REPLACE FUNCTION advisor.operation_metrics(p_window interval DEFAULT interval '24 hours')
RETURNS TABLE (
    server_id integer,
    wal_records bigint,
    wal_fpi bigint,
    wal_bytes numeric,
    wal_buffers_full bigint,
    wal_writes bigint,
    wal_syncs bigint,
    wal_write_time_ms double precision,
    wal_sync_time_ms double precision,
    timed_checkpoints bigint,
    requested_checkpoints bigint,
    checkpoint_write_time_ms double precision,
    checkpoint_sync_time_ms double precision,
    checkpoint_buffers_written bigint,
    buffers_clean bigint,
    maxwritten_clean bigint,
    buffers_backend bigint,
    buffers_backend_fsync bigint,
    buffers_allocated bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH wal_samples AS (
    SELECT
        h.srvid AS server_id,
        (sample_record).ts AS sample_at,
        (sample_record).wal_records AS wal_records,
        (sample_record).wal_fpi AS wal_fpi,
        (sample_record).wal_bytes AS wal_bytes,
        (sample_record).wal_buffers_full AS wal_buffers_full,
        (sample_record).wal_write AS wal_writes,
        (sample_record).wal_sync AS wal_syncs,
        (sample_record).wal_write_time AS wal_write_time_ms,
        (sample_record).wal_sync_time AS wal_sync_time_ms,
        (sample_record).stats_reset AS stats_reset
    FROM (
        SELECT history.*
        FROM "PoWA".powa_stat_wal_history AS history
        WHERE history.coalesce_range && tstzrange(now() - p_window - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    WHERE (sample_record).ts >= now() - p_window - interval '1 hour'
    UNION ALL
    SELECT
        c.srvid,
        (c.record).ts,
        (c.record).wal_records,
        (c.record).wal_fpi,
        (c.record).wal_bytes,
        (c.record).wal_buffers_full,
        (c.record).wal_write,
        (c.record).wal_sync,
        (c.record).wal_write_time,
        (c.record).wal_sync_time,
        (c.record).stats_reset
    FROM "PoWA".powa_stat_wal_history_current AS c
    WHERE (c.record).ts >= now() - p_window - interval '1 hour'
), wal_ordered AS (
    SELECT
        samples.*,
        lag(wal_records) OVER metric_window AS previous_wal_records,
        lag(wal_fpi) OVER metric_window AS previous_wal_fpi,
        lag(wal_bytes) OVER metric_window AS previous_wal_bytes,
        lag(wal_buffers_full) OVER metric_window AS previous_wal_buffers_full,
        lag(wal_writes) OVER metric_window AS previous_wal_writes,
        lag(wal_syncs) OVER metric_window AS previous_wal_syncs,
        lag(wal_write_time_ms) OVER metric_window AS previous_wal_write_time_ms,
        lag(wal_sync_time_ms) OVER metric_window AS previous_wal_sync_time_ms
    FROM wal_samples AS samples
    WINDOW metric_window AS (PARTITION BY server_id, stats_reset ORDER BY sample_at)
), wal_metrics AS (
    SELECT
        server_id,
        sum(CASE WHEN wal_records >= previous_wal_records THEN wal_records - previous_wal_records ELSE COALESCE(wal_records, 0) END)::bigint AS wal_records,
        sum(CASE WHEN wal_fpi >= previous_wal_fpi THEN wal_fpi - previous_wal_fpi ELSE COALESCE(wal_fpi, 0) END)::bigint AS wal_fpi,
        sum(CASE WHEN wal_bytes >= previous_wal_bytes THEN wal_bytes - previous_wal_bytes ELSE COALESCE(wal_bytes, 0) END)::numeric AS wal_bytes,
        sum(CASE WHEN wal_buffers_full >= previous_wal_buffers_full THEN wal_buffers_full - previous_wal_buffers_full ELSE COALESCE(wal_buffers_full, 0) END)::bigint AS wal_buffers_full,
        sum(CASE WHEN wal_writes >= previous_wal_writes THEN wal_writes - previous_wal_writes ELSE COALESCE(wal_writes, 0) END)::bigint AS wal_writes,
        sum(CASE WHEN wal_syncs >= previous_wal_syncs THEN wal_syncs - previous_wal_syncs ELSE COALESCE(wal_syncs, 0) END)::bigint AS wal_syncs,
        sum(CASE WHEN wal_write_time_ms >= previous_wal_write_time_ms THEN wal_write_time_ms - previous_wal_write_time_ms ELSE COALESCE(wal_write_time_ms, 0) END)::double precision AS wal_write_time_ms,
        sum(CASE WHEN wal_sync_time_ms >= previous_wal_sync_time_ms THEN wal_sync_time_ms - previous_wal_sync_time_ms ELSE COALESCE(wal_sync_time_ms, 0) END)::double precision AS wal_sync_time_ms
    FROM wal_ordered
    WHERE sample_at >= now() - p_window AND previous_wal_records IS NOT NULL
    GROUP BY server_id
), checkpoint_samples AS (
    SELECT
        h.srvid AS server_id,
        (sample_record).ts AS sample_at,
        (sample_record).num_timed AS timed_checkpoints,
        (sample_record).num_requested AS requested_checkpoints,
        (sample_record).write_time AS checkpoint_write_time_ms,
        (sample_record).sync_time AS checkpoint_sync_time_ms,
        (sample_record).buffers_written AS checkpoint_buffers_written
    FROM (
        SELECT history.*
        FROM "PoWA".powa_stat_checkpointer_history AS history
        WHERE history.coalesce_range && tstzrange(now() - p_window - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    WHERE (sample_record).ts >= now() - p_window - interval '1 hour'
    UNION ALL
    SELECT
        c.srvid,
        (c.record).ts,
        (c.record).num_timed,
        (c.record).num_requested,
        (c.record).write_time,
        (c.record).sync_time,
        (c.record).buffers_written
    FROM "PoWA".powa_stat_checkpointer_history_current AS c
    WHERE (c.record).ts >= now() - p_window - interval '1 hour'
), checkpoint_ordered AS (
    SELECT
        samples.*,
        lag(timed_checkpoints) OVER metric_window AS previous_timed_checkpoints,
        lag(requested_checkpoints) OVER metric_window AS previous_requested_checkpoints,
        lag(checkpoint_write_time_ms) OVER metric_window AS previous_checkpoint_write_time_ms,
        lag(checkpoint_sync_time_ms) OVER metric_window AS previous_checkpoint_sync_time_ms,
        lag(checkpoint_buffers_written) OVER metric_window AS previous_checkpoint_buffers_written
    FROM checkpoint_samples AS samples
    WINDOW metric_window AS (PARTITION BY server_id ORDER BY sample_at)
), checkpoint_metrics AS (
    SELECT
        server_id,
        sum(CASE WHEN timed_checkpoints >= previous_timed_checkpoints THEN timed_checkpoints - previous_timed_checkpoints ELSE 0 END)::bigint AS timed_checkpoints,
        sum(CASE WHEN requested_checkpoints >= previous_requested_checkpoints THEN requested_checkpoints - previous_requested_checkpoints ELSE 0 END)::bigint AS requested_checkpoints,
        sum(CASE WHEN checkpoint_write_time_ms >= previous_checkpoint_write_time_ms THEN checkpoint_write_time_ms - previous_checkpoint_write_time_ms ELSE 0 END)::double precision AS checkpoint_write_time_ms,
        sum(CASE WHEN checkpoint_sync_time_ms >= previous_checkpoint_sync_time_ms THEN checkpoint_sync_time_ms - previous_checkpoint_sync_time_ms ELSE 0 END)::double precision AS checkpoint_sync_time_ms,
        sum(CASE WHEN checkpoint_buffers_written >= previous_checkpoint_buffers_written THEN checkpoint_buffers_written - previous_checkpoint_buffers_written ELSE 0 END)::bigint AS checkpoint_buffers_written
    FROM checkpoint_ordered
    WHERE sample_at >= now() - p_window AND previous_timed_checkpoints IS NOT NULL
    GROUP BY server_id
), bgwriter_samples AS (
    SELECT
        h.srvid AS server_id,
        (sample_record).ts AS sample_at,
        (sample_record).buffers_clean AS buffers_clean,
        (sample_record).maxwritten_clean AS maxwritten_clean,
        (sample_record).buffers_backend AS buffers_backend,
        (sample_record).buffers_backend_fsync AS buffers_backend_fsync,
        (sample_record).buffers_alloc AS buffers_allocated
    FROM (
        SELECT history.*
        FROM "PoWA".powa_stat_bgwriter_history AS history
        WHERE history.coalesce_range && tstzrange(now() - p_window - interval '1 hour', now(), '[]')
    ) AS h
    CROSS JOIN LATERAL unnest(ARRAY[h.mins_in_range, h.maxs_in_range]) AS sample_record
    WHERE (sample_record).ts >= now() - p_window - interval '1 hour'
    UNION ALL
    SELECT
        c.srvid,
        (c.record).ts,
        (c.record).buffers_clean,
        (c.record).maxwritten_clean,
        (c.record).buffers_backend,
        (c.record).buffers_backend_fsync,
        (c.record).buffers_alloc
    FROM "PoWA".powa_stat_bgwriter_history_current AS c
    WHERE (c.record).ts >= now() - p_window - interval '1 hour'
), bgwriter_ordered AS (
    SELECT
        samples.*,
        lag(buffers_clean) OVER metric_window AS previous_buffers_clean,
        lag(maxwritten_clean) OVER metric_window AS previous_maxwritten_clean,
        lag(buffers_backend) OVER metric_window AS previous_buffers_backend,
        lag(buffers_backend_fsync) OVER metric_window AS previous_buffers_backend_fsync,
        lag(buffers_allocated) OVER metric_window AS previous_buffers_allocated
    FROM bgwriter_samples AS samples
    WINDOW metric_window AS (PARTITION BY server_id ORDER BY sample_at)
), bgwriter_metrics AS (
    SELECT
        server_id,
        sum(CASE WHEN buffers_clean >= previous_buffers_clean THEN buffers_clean - previous_buffers_clean ELSE 0 END)::bigint AS buffers_clean,
        sum(CASE WHEN maxwritten_clean >= previous_maxwritten_clean THEN maxwritten_clean - previous_maxwritten_clean ELSE 0 END)::bigint AS maxwritten_clean,
        sum(CASE WHEN buffers_backend >= previous_buffers_backend THEN buffers_backend - previous_buffers_backend ELSE 0 END)::bigint AS buffers_backend,
        sum(CASE WHEN buffers_backend_fsync >= previous_buffers_backend_fsync THEN buffers_backend_fsync - previous_buffers_backend_fsync ELSE 0 END)::bigint AS buffers_backend_fsync,
        sum(CASE WHEN buffers_allocated >= previous_buffers_allocated THEN buffers_allocated - previous_buffers_allocated ELSE 0 END)::bigint AS buffers_allocated
    FROM bgwriter_ordered
    WHERE sample_at >= now() - p_window AND previous_buffers_clean IS NOT NULL
    GROUP BY server_id
), server_ids AS (
    SELECT server_id FROM wal_metrics
    UNION SELECT server_id FROM checkpoint_metrics
    UNION SELECT server_id FROM bgwriter_metrics
)
SELECT
    ids.server_id,
    COALESCE(w.wal_records, 0),
    COALESCE(w.wal_fpi, 0),
    COALESCE(w.wal_bytes, 0),
    COALESCE(w.wal_buffers_full, 0),
    COALESCE(w.wal_writes, 0),
    COALESCE(w.wal_syncs, 0),
    COALESCE(w.wal_write_time_ms, 0),
    COALESCE(w.wal_sync_time_ms, 0),
    COALESCE(c.timed_checkpoints, 0),
    COALESCE(c.requested_checkpoints, 0),
    COALESCE(c.checkpoint_write_time_ms, 0),
    COALESCE(c.checkpoint_sync_time_ms, 0),
    COALESCE(c.checkpoint_buffers_written, 0),
    COALESCE(b.buffers_clean, 0),
    COALESCE(b.maxwritten_clean, 0),
    COALESCE(b.buffers_backend, 0),
    COALESCE(b.buffers_backend_fsync, 0),
    COALESCE(b.buffers_allocated, 0)
FROM server_ids AS ids
LEFT JOIN wal_metrics AS w USING (server_id)
LEFT JOIN checkpoint_metrics AS c USING (server_id)
LEFT JOIN bgwriter_metrics AS b USING (server_id);
$$;

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

-- pg_qualstats evidence is deliberately kept outside the impact score.  This
-- adapter exposes only predicates that PoWA has already persisted in the
-- repository and never emits executable DDL.  Stock PoWA 5.2 transfers
-- WHERE/filter predicates, but not column-to-column JOIN predicates.
CREATE OR REPLACE FUNCTION advisor.predicate_metrics(
    p_window interval DEFAULT interval '24 hours',
    p_server_id integer DEFAULT NULL,
    p_database_id oid DEFAULT NULL,
    p_query_id bigint DEFAULT NULL
)
RETURNS TABLE (
    server_id integer,
    server_alias text,
    database_id oid,
    database_name text,
    query_id bigint,
    user_id oid,
    qual_id bigint,
    relation_id oid,
    schema_name text,
    table_name text,
    column_names text[],
    operator_oids oid[],
    eval_type text,
    occurrences bigint,
    rows_processed bigint,
    rows_filtered bigint,
    filter_ratio double precision,
    observed_from timestamptz,
    observed_to timestamptz,
    sample_count bigint,
    signal text,
    recommendation text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor
AS $$
WITH historical_samples AS (
    SELECT
        h.srvid AS server_id,
        h.qualid AS qual_id,
        h.queryid AS query_id,
        h.dbid AS database_id,
        h.userid AS user_id,
        (sample_record).ts AS sample_at,
        (sample_record).occurences AS occurrences,
        (sample_record).execution_count AS rows_processed,
        (sample_record).nbfiltered AS rows_filtered
    FROM "PoWA".powa_qualstats_quals_history AS h
    CROSS JOIN LATERAL unnest(h.records) AS sample_record
    WHERE h.coalesce_range && tstzrange(now() - p_window, now(), '[]')
      AND (sample_record).ts >= now() - p_window
      AND (sample_record).ts <= now()
), current_samples AS (
    SELECT
        c.srvid,
        c.qualid,
        c.queryid,
        c.dbid,
        c.userid,
        c.ts,
        c.occurences,
        c.execution_count,
        c.nbfiltered
    FROM "PoWA".powa_qualstats_quals_history_current AS c
    WHERE c.ts >= now() - p_window
      AND c.ts <= now()
), samples AS (
    SELECT * FROM historical_samples
    UNION ALL
    SELECT * FROM current_samples
), metrics AS (
    SELECT
        s.server_id,
        s.qual_id,
        s.query_id,
        s.database_id,
        s.user_id,
        sum(COALESCE(s.occurrences, 0))::bigint AS occurrences,
        sum(COALESCE(s.rows_processed, 0))::bigint AS rows_processed,
        sum(COALESCE(s.rows_filtered, 0))::bigint AS rows_filtered,
        min(s.sample_at) AS observed_from,
        max(s.sample_at) AS observed_to,
        count(*)::bigint AS sample_count
    FROM samples AS s
    WHERE (p_server_id IS NULL OR s.server_id = p_server_id)
      AND (p_database_id IS NULL OR s.database_id = p_database_id)
      AND (p_query_id IS NULL OR s.query_id = p_query_id)
    GROUP BY s.server_id, s.qual_id, s.query_id, s.database_id, s.user_id
), predicate_columns AS (
    SELECT
        q.srvid AS server_id,
        q.qualid AS qual_id,
        q.queryid AS query_id,
        q.dbid AS database_id,
        q.userid AS user_id,
        predicate.relid AS relation_id,
        predicate.eval_type::text AS raw_eval_type,
        COALESCE(ns.nspname::text, 'unknown') AS schema_name,
        COALESCE(cls.relname::text, 'relation-' || predicate.relid::text) AS table_name,
        COALESCE(
            array_agg(attr.attname::text ORDER BY predicate.attnum)
                FILTER (WHERE attr.attname IS NOT NULL),
            ARRAY[]::text[]
        ) AS column_names,
        array_agg(predicate.opno ORDER BY predicate.attnum)::oid[] AS operator_oids
    FROM "PoWA".powa_qualstats_quals AS q
    CROSS JOIN LATERAL unnest(q.quals) AS predicate(relid, attnum, opno, eval_type)
    LEFT JOIN "PoWA".powa_catalog_class AS cls
      ON cls.srvid = q.srvid AND cls.dbid = q.dbid AND cls.oid = predicate.relid
    LEFT JOIN "PoWA".powa_catalog_namespace AS ns
      ON ns.srvid = cls.srvid AND ns.dbid = cls.dbid AND ns.oid = cls.relnamespace
    LEFT JOIN "PoWA".powa_catalog_attribute AS attr
      ON attr.srvid = q.srvid AND attr.dbid = q.dbid
     AND attr.attrelid = predicate.relid AND attr.attnum = predicate.attnum
    GROUP BY
        q.srvid, q.qualid, q.queryid, q.dbid, q.userid,
        predicate.relid, predicate.eval_type, ns.nspname, cls.relname
), evidence AS (
    SELECT
        m.*,
        pc.relation_id,
        pc.schema_name,
        pc.table_name,
        pc.column_names,
        pc.operator_oids,
        CASE pc.raw_eval_type
            WHEN 'f' THEN 'FILTER'
            WHEN 'i' THEN 'INDEX_CONDITION'
            ELSE 'UNKNOWN'
        END AS eval_type,
        LEAST(
            1.0,
            GREATEST(0.0, m.rows_filtered::double precision / NULLIF(m.rows_processed, 0))
        ) AS filter_ratio
    FROM metrics AS m
    JOIN predicate_columns AS pc
      ON pc.server_id = m.server_id
     AND pc.qual_id = m.qual_id
     AND pc.query_id = m.query_id
     AND pc.database_id = m.database_id
     AND pc.user_id = m.user_id
), classified AS (
    SELECT
        e.*,
        CASE
            WHEN e.sample_count < 2 OR e.occurrences < 5 OR e.rows_processed < 1000
                THEN 'INSUFFICIENT_DATA'
            WHEN e.eval_type = 'INDEX_CONDITION'
                THEN 'INDEX_CONDITION_OBSERVED'
            WHEN e.filter_ratio >= 0.50 AND e.occurrences >= 20 AND e.rows_processed >= 10000
                THEN 'INDEX_CANDIDATE'
            WHEN e.filter_ratio >= 0.20 AND e.occurrences >= 10
                THEN 'REVIEW'
            ELSE 'OBSERVED'
        END AS signal
    FROM evidence AS e
)
SELECT
    c.server_id,
    COALESCE(server.alias::text, server.hostname::text, 'server-' || c.server_id::text),
    c.database_id,
    COALESCE(db.datname::text, 'db-' || c.database_id::text),
    c.query_id,
    c.user_id,
    c.qual_id,
    c.relation_id,
    c.schema_name,
    c.table_name,
    c.column_names,
    c.operator_oids,
    c.eval_type,
    c.occurrences,
    c.rows_processed,
    c.rows_filtered,
    c.filter_ratio,
    c.observed_from,
    c.observed_to,
    c.sample_count,
    c.signal,
    CASE c.signal
        WHEN 'INSUFFICIENT_DATA'
            THEN 'Ornek sayisi dusuk; index karari vermeden once daha fazla predicate verisi toplayin.'
        WHEN 'INDEX_CONDITION_OBSERVED'
            THEN 'Bu predicate planlarda index kosulu olarak goruluyor; mevcut indexin etkinligini EXPLAIN ile dogrulayin.'
        WHEN 'INDEX_CANDIDATE'
            THEN 'Yuksek eleme oranli WHERE filtresi; HypoPG ve EXPLAIN ile sanal index faydasini dogrulayin.'
        WHEN 'REVIEW'
            THEN 'WHERE filtresi kayda deger satir eliyor; tablo boyutu ve sorgu planiyla birlikte inceleyin.'
        ELSE 'Predicate gozlemlendi; daha guclu bir index sinyali icin veri birikimini izleyin.'
    END
FROM classified AS c
LEFT JOIN "PoWA".powa_servers AS server ON server.id = c.server_id
LEFT JOIN "PoWA".powa_databases AS db
  ON db.srvid = c.server_id AND db.oid = c.database_id
WHERE c.schema_name !~ '^(pg_|information_schema$)'
ORDER BY
    CASE c.signal
        WHEN 'INDEX_CANDIDATE' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'INDEX_CONDITION_OBSERVED' THEN 3
        WHEN 'OBSERVED' THEN 4
        ELSE 5
    END,
    c.filter_ratio DESC NULLS LAST,
    c.occurrences DESC;
$$;

CREATE OR REPLACE FUNCTION advisor.predicate_capability(p_server_id integer)
RETURNS TABLE (
    available boolean,
    version text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor
AS $$
SELECT
    COALESCE(bool_or(config.enabled), false) AS available,
    max(config.version)::text AS version
FROM "PoWA".powa_extension_config AS config
WHERE config.srvid = p_server_id
  AND config.extname = 'pg_qualstats';
$$;

GRANT USAGE ON SCHEMA advisor TO advisor_api;
GRANT SELECT ON ALL TABLES IN SCHEMA advisor TO advisor_api;
GRANT INSERT, UPDATE ON advisor.query_annotations TO advisor_api;
GRANT INSERT ON advisor.audit_log TO advisor_api;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA advisor TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.query_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.kcache_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.query_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.index_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.database_io_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.io_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.operation_metrics(interval) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.predicate_metrics(interval, integer, oid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.predicate_metrics(interval, integer, oid, bigint) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.predicate_capability(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.predicate_capability(integer) TO advisor_api;

ALTER DEFAULT PRIVILEGES IN SCHEMA advisor GRANT SELECT ON TABLES TO advisor_api;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor GRANT EXECUTE ON FUNCTIONS TO advisor_api;

COMMENT ON SCHEMA advisor IS
'Urun verileri ve PoWA surumunden bagimsiz adapter katmani. PoWA nesneleri degistirilmez.';
