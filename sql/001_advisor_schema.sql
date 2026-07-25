\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS advisor AUTHORIZATION postgres;
CREATE SCHEMA IF NOT EXISTS advisor_ingest AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA advisor_ingest FROM PUBLIC;

-- Private ingest objects stay private by default in later migrations too.
-- Individual low-privilege entry points are granted explicitly at the end of
-- this file; tables, sequences and future functions are never PUBLIC.
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor_ingest
    REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor_ingest
    REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor_ingest
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE IF NOT EXISTS advisor_ingest.join_snapshot_batches (
    server_id integer NOT NULL,
    batch_id bigint NOT NULL,
    captured_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    row_count integer NOT NULL,
    PRIMARY KEY (server_id, batch_id)
);

CREATE TABLE IF NOT EXISTS advisor_ingest.join_predicate_samples (
    sample_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    server_id integer NOT NULL,
    batch_id bigint NOT NULL,
    dbid oid NOT NULL,
    userid oid NOT NULL,
    queryid bigint NOT NULL,
    qualid bigint NOT NULL,
    qualnodeid bigint NOT NULL,
    lrelid oid,
    lattnum smallint,
    opno oid NOT NULL,
    operator_name text,
    operator_commutator oid,
    btree_strategy smallint,
    rrelid oid,
    rattnum smallint,
    occurences bigint NOT NULL,
    execution_count bigint NOT NULL,
    nbfiltered bigint NOT NULL,
    eval_type "char" NOT NULL,
    is_join boolean NOT NULL,
    UNIQUE NULLS NOT DISTINCT (
        server_id, batch_id, dbid, userid, queryid, qualnodeid,
        opno, lrelid, lattnum, rrelid, rattnum
    ),
    FOREIGN KEY (server_id, batch_id)
        REFERENCES advisor_ingest.join_snapshot_batches(server_id, batch_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS join_predicate_samples_lookup_idx
    ON advisor_ingest.join_predicate_samples
    (server_id, dbid, queryid, is_join, batch_id);

CREATE TABLE IF NOT EXISTS advisor_ingest.join_source_status (
    server_id integer PRIMARY KEY,
    status text NOT NULL DEFAULT 'STARTING'
        CHECK (status IN ('STARTING', 'HEALTHY', 'DEGRADED', 'ERROR')),
    last_capture_at timestamptz,
    last_ingest_at timestamptz,
    last_batch_id bigint,
    last_row_count integer,
    last_error text,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Every repository login used by a JOIN snapshotter is pinned to one PoWA
-- source.  SECURITY DEFINER entry points resolve this table with session_user,
-- so a caller cannot select another source by changing a request parameter or
-- by using SET ROLE.  Multiple roles may intentionally point at the same
-- source during credential rotation, but one role can never span sources.
CREATE TABLE IF NOT EXISTS advisor_ingest.join_source_role_bindings (
    role_name name PRIMARY KEY,
    server_id integer NOT NULL,
    bound_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS join_source_role_bindings_server_idx
    ON advisor_ingest.join_source_role_bindings (server_id);

REVOKE ALL ON ALL TABLES IN SCHEMA advisor_ingest FROM PUBLIC;

CREATE TABLE IF NOT EXISTS advisor.index_candidates (
    candidate_id uuid PRIMARY KEY,
    server_id integer NOT NULL,
    database_id oid NOT NULL,
    query_id bigint NOT NULL,
    relation_id oid NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    method text NOT NULL DEFAULT 'btree' CHECK (method = 'btree'),
    key_attnums smallint[] NOT NULL CHECK (cardinality(key_attnums) = 2),
    key_column_names text[] NOT NULL CHECK (cardinality(key_column_names) = 2),
    operator_oids oid[] NOT NULL,
    ordering_rule text NOT NULL,
    first_supported_at timestamptz NOT NULL,
    last_supported_at timestamptz NOT NULL,
    UNIQUE (server_id, database_id, query_id, relation_id, key_attnums)
);

CREATE TABLE IF NOT EXISTS advisor.index_candidate_evidence (
    candidate_id uuid NOT NULL REFERENCES advisor.index_candidates(candidate_id) ON DELETE CASCADE,
    server_id integer NOT NULL,
    batch_id bigint NOT NULL,
    captured_at timestamptz NOT NULL,
    join_occurrences bigint NOT NULL,
    filter_occurrences bigint NOT NULL,
    rows_processed bigint NOT NULL,
    rows_filtered bigint NOT NULL,
    PRIMARY KEY (candidate_id, server_id, batch_id)
);

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
SET description = EXCLUDED.description;

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
    CASE WHEN calls >= previous_calls THEN calls - previous_calls ELSE COALESCE(calls, 0) END::bigint AS calls,
    CASE WHEN total_exec_time_ms >= previous_total_exec_time_ms
         THEN total_exec_time_ms - previous_total_exec_time_ms ELSE COALESCE(total_exec_time_ms, 0) END::double precision AS total_exec_time_ms,
    CASE WHEN shared_blocks_hit >= previous_shared_blocks_hit
         THEN shared_blocks_hit - previous_shared_blocks_hit ELSE COALESCE(shared_blocks_hit, 0) END::bigint AS shared_blocks_hit,
    CASE WHEN shared_blocks_read >= previous_shared_blocks_read
         THEN shared_blocks_read - previous_shared_blocks_read ELSE COALESCE(shared_blocks_read, 0) END::bigint AS shared_blocks_read,
    CASE WHEN temp_blocks_written >= previous_temp_blocks_written
         THEN temp_blocks_written - previous_temp_blocks_written ELSE COALESCE(temp_blocks_written, 0) END::bigint AS temp_blocks_written,
    CASE WHEN wal_bytes >= previous_wal_bytes
         THEN wal_bytes - previous_wal_bytes ELSE COALESCE(wal_bytes, 0) END::numeric AS wal_bytes,
    CASE WHEN rows >= previous_rows THEN rows - previous_rows ELSE COALESCE(rows, 0) END::bigint AS rows
FROM ordered
WHERE previous_calls IS NOT NULL;

-- The API-facing delta functions have a wider return shape than older
-- installations.  Drop their convenience consumers before replacing them so
-- this fresh-schema file remains safe to reapply to an initialized volume.
DROP VIEW IF EXISTS advisor.v_query_summary;
DROP VIEW IF EXISTS advisor.v_query_regression;
DROP VIEW IF EXISTS advisor.v_query_impact;
DROP FUNCTION IF EXISTS advisor.query_metrics(interval);
DROP FUNCTION IF EXISTS advisor.query_deltas(timestamptz);
DROP FUNCTION IF EXISTS advisor.kcache_deltas(timestamptz);
DROP FUNCTION IF EXISTS advisor.wait_deltas(timestamptz);

-- API-facing variant with range predicates pushed into PoWA's storage tables.
-- The one-hour look-behind is the bounded hot path.  Series without a row in
-- that baseline perform one indexed nearest-predecessor lookup, so long
-- collector gaps are explicit.  If retention removed that predecessor, the
-- first sample is emitted with predecessor_available=false.
-- Full chunk records (not only mins/maxs) are read: otherwise a reset followed
-- by enough activity to exceed the old chunk endpoint would be invisible.
CREATE OR REPLACE FUNCTION advisor.query_deltas(p_start timestamptz)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    user_id oid,
    toplevel boolean,
    sample_at timestamptz,
    previous_sample_at timestamptz,
    calls bigint,
    total_exec_time_ms double precision,
    shared_blocks_hit bigint,
    shared_blocks_read bigint,
    temp_blocks_written bigint,
    wal_bytes numeric,
    rows bigint,
    reset_detected boolean,
    predecessor_available boolean,
    gap_detected boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH bounded_samples AS (
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
    CROSS JOIN LATERAL unnest(h.records) AS sample_record
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
), series_without_predecessor AS (
    SELECT
        sample.server_id,
        sample.database_id,
        sample.query_id,
        sample.user_id,
        sample.toplevel,
        min(sample.sample_at) AS first_sample_at
    FROM bounded_samples AS sample
    GROUP BY
        sample.server_id, sample.database_id, sample.query_id,
        sample.user_id, sample.toplevel
    HAVING min(sample.sample_at) >= p_start
), older_samples AS (
    -- Only series that had no bounded look-behind row pay for a nearest-row
    -- lookup.  This keeps the normal hot path range-bounded while turning a
    -- >1 hour collector outage into an explicit gap instead of warm-up.
    SELECT
        series.server_id,
        series.database_id,
        series.query_id,
        series.user_id,
        series.toplevel,
        predecessor.sample_at,
        predecessor.calls,
        predecessor.total_exec_time_ms,
        predecessor.shared_blocks_hit,
        predecessor.shared_blocks_read,
        predecessor.temp_blocks_written,
        predecessor.wal_bytes,
        predecessor.rows
    FROM series_without_predecessor AS series
    CROSS JOIN LATERAL (
        SELECT candidate.*
        FROM (
            (
                SELECT
                    (history_record).ts AS sample_at,
                    (history_record).calls AS calls,
                    (history_record).total_exec_time AS total_exec_time_ms,
                    (history_record).shared_blks_hit AS shared_blocks_hit,
                    (history_record).shared_blks_read AS shared_blocks_read,
                    (history_record).temp_blks_written AS temp_blocks_written,
                    (history_record).wal_bytes AS wal_bytes,
                    (history_record).rows AS rows
                FROM LATERAL (
                    SELECT history.records
                    FROM "PoWA".powa_statements_history AS history
                    WHERE history.srvid = series.server_id
                      AND history.dbid = series.database_id
                      AND history.queryid = series.query_id
                      AND history.userid = series.user_id
                      AND history.toplevel = series.toplevel
                      AND history.coalesce_range && tstzrange(
                          '-infinity'::timestamptz,
                          series.first_sample_at,
                          '[)'
                      )
                    ORDER BY upper(history.coalesce_range) DESC
                    LIMIT 1
                ) AS latest_history
                CROSS JOIN LATERAL unnest(latest_history.records) AS history_record
                WHERE (history_record).ts < series.first_sample_at
                ORDER BY (history_record).ts DESC
                LIMIT 1
            )
            UNION ALL
            (
                SELECT
                    (current_sample.record).ts,
                    (current_sample.record).calls,
                    (current_sample.record).total_exec_time,
                    (current_sample.record).shared_blks_hit,
                    (current_sample.record).shared_blks_read,
                    (current_sample.record).temp_blks_written,
                    (current_sample.record).wal_bytes,
                    (current_sample.record).rows
                FROM "PoWA".powa_statements_history_current AS current_sample
                WHERE current_sample.srvid = series.server_id
                  AND current_sample.dbid = series.database_id
                  AND current_sample.queryid = series.query_id
                  AND current_sample.userid = series.user_id
                  AND current_sample.toplevel = series.toplevel
                  AND (current_sample.record).ts < series.first_sample_at
                ORDER BY (current_sample.record).ts DESC
                LIMIT 1
            )
        ) AS candidate
        ORDER BY candidate.sample_at DESC
        LIMIT 1
    ) AS predecessor
), samples AS (
    SELECT * FROM bounded_samples
    UNION ALL
    SELECT * FROM older_samples
), ordered AS (
    SELECT
        samples.*,
        lag(sample_at) OVER metric_window AS previous_sample_at,
        lag(calls) OVER metric_window AS previous_calls,
        lag(total_exec_time_ms) OVER metric_window AS previous_total_exec_time_ms,
        lag(shared_blocks_hit) OVER metric_window AS previous_shared_blocks_hit,
        lag(shared_blocks_read) OVER metric_window AS previous_shared_blocks_read,
        lag(temp_blocks_written) OVER metric_window AS previous_temp_blocks_written,
        lag(wal_bytes) OVER metric_window AS previous_wal_bytes,
        lag(rows) OVER metric_window AS previous_rows,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END AS frequency_seconds
    FROM samples
    JOIN "PoWA".powa_servers AS source ON source.id = samples.server_id
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
    previous_sample_at,
    CASE
        WHEN previous_calls IS NULL THEN 0
        WHEN calls >= previous_calls THEN calls - previous_calls
        ELSE COALESCE(calls, 0)
    END::bigint,
    CASE
        WHEN previous_total_exec_time_ms IS NULL THEN 0
        WHEN total_exec_time_ms >= previous_total_exec_time_ms THEN total_exec_time_ms - previous_total_exec_time_ms
        ELSE COALESCE(total_exec_time_ms, 0)
    END::double precision,
    CASE
        WHEN previous_shared_blocks_hit IS NULL THEN 0
        WHEN shared_blocks_hit >= previous_shared_blocks_hit THEN shared_blocks_hit - previous_shared_blocks_hit
        ELSE COALESCE(shared_blocks_hit, 0)
    END::bigint,
    CASE
        WHEN previous_shared_blocks_read IS NULL THEN 0
        WHEN shared_blocks_read >= previous_shared_blocks_read THEN shared_blocks_read - previous_shared_blocks_read
        ELSE COALESCE(shared_blocks_read, 0)
    END::bigint,
    CASE
        WHEN previous_temp_blocks_written IS NULL THEN 0
        WHEN temp_blocks_written >= previous_temp_blocks_written THEN temp_blocks_written - previous_temp_blocks_written
        ELSE COALESCE(temp_blocks_written, 0)
    END::bigint,
    CASE
        WHEN previous_wal_bytes IS NULL THEN 0
        WHEN wal_bytes >= previous_wal_bytes THEN wal_bytes - previous_wal_bytes
        ELSE COALESCE(wal_bytes, 0)
    END::numeric,
    CASE
        WHEN previous_rows IS NULL THEN 0
        WHEN rows >= previous_rows THEN rows - previous_rows
        ELSE COALESCE(rows, 0)
    END::bigint,
    previous_sample_at IS NOT NULL AND COALESCE((
        calls < previous_calls
        OR total_exec_time_ms < previous_total_exec_time_ms
        OR shared_blocks_hit < previous_shared_blocks_hit
        OR shared_blocks_read < previous_shared_blocks_read
        OR temp_blocks_written < previous_temp_blocks_written
        OR wal_bytes < previous_wal_bytes
        OR rows < previous_rows
    ), false) AS reset_detected,
    previous_sample_at IS NOT NULL AS predecessor_available,
    previous_sample_at IS NOT NULL
        AND sample_at - previous_sample_at
            > make_interval(secs => frequency_seconds * 3) AS gap_detected
FROM ordered
WHERE sample_at >= p_start;
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
    previous_sample_at timestamptz,
    exec_user_time_seconds double precision,
    exec_system_time_seconds double precision,
    filesystem_reads_bytes bigint,
    filesystem_writes_bytes bigint,
    reset_detected boolean,
    predecessor_available boolean,
    gap_detected boolean
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
        lag(sample_at) OVER metric_window AS previous_sample_at,
        lag(exec_user_time_seconds) OVER metric_window AS previous_user_time,
        lag(exec_system_time_seconds) OVER metric_window AS previous_system_time,
        lag(filesystem_reads_bytes) OVER metric_window AS previous_reads,
        lag(filesystem_writes_bytes) OVER metric_window AS previous_writes,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END AS frequency_seconds
    FROM samples
    JOIN "PoWA".powa_servers AS source ON source.id = samples.server_id
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
    previous_sample_at,
    CASE
        WHEN previous_user_time IS NULL THEN 0
        WHEN exec_user_time_seconds >= previous_user_time
            THEN exec_user_time_seconds - previous_user_time
        ELSE COALESCE(exec_user_time_seconds, 0)
    END,
    CASE
        WHEN previous_system_time IS NULL THEN 0
        WHEN exec_system_time_seconds >= previous_system_time
            THEN exec_system_time_seconds - previous_system_time
        ELSE COALESCE(exec_system_time_seconds, 0)
    END,
    CASE
        WHEN filesystem_reads_bytes IS NULL THEN NULL
        WHEN previous_reads IS NULL THEN 0
        WHEN filesystem_reads_bytes >= previous_reads THEN filesystem_reads_bytes - previous_reads
        ELSE filesystem_reads_bytes
    END::bigint,
    CASE
        WHEN filesystem_writes_bytes IS NULL THEN NULL
        WHEN previous_writes IS NULL THEN 0
        WHEN filesystem_writes_bytes >= previous_writes THEN filesystem_writes_bytes - previous_writes
        ELSE filesystem_writes_bytes
    END::bigint,
    previous_sample_at IS NOT NULL AND COALESCE(
        exec_user_time_seconds < previous_user_time
        OR exec_system_time_seconds < previous_system_time
        OR (
            filesystem_reads_bytes IS NOT NULL
            AND previous_reads IS NOT NULL
            AND filesystem_reads_bytes < previous_reads
        )
        OR (
            filesystem_writes_bytes IS NOT NULL
            AND previous_writes IS NOT NULL
            AND filesystem_writes_bytes < previous_writes
        ),
        false
    ) AS reset_detected,
    previous_sample_at IS NOT NULL AS predecessor_available,
    previous_sample_at IS NOT NULL
        AND sample_at - previous_sample_at
            > make_interval(secs => frequency_seconds * 3) AS gap_detected
FROM ordered
WHERE sample_at >= p_start;
$$;

-- pg_wait_sampling profile counters are cumulative.  PoWA stores one series
-- per query/event and intentionally drops NULL event rows (CPU/runnable
-- samples).  Keep raw event names, calculate reset-safe sample deltas and do
-- not convert samples to wall-clock or CPU time.
CREATE OR REPLACE FUNCTION advisor.wait_deltas(p_start timestamptz)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    event_type text,
    event text,
    sample_at timestamptz,
    previous_sample_at timestamptz,
    samples bigint,
    reset_detected boolean,
    predecessor_available boolean,
    gap_detected boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH raw_samples AS (
    SELECT
        h.srvid AS server_id,
        h.dbid AS database_id,
        h.queryid AS query_id,
        h.event_type,
        h.event,
        (sample_record).ts AS sample_at,
        (sample_record).count::numeric AS sample_count
    FROM "PoWA".powa_wait_sampling_history AS h
    CROSS JOIN LATERAL unnest(h.records) AS sample_record
    WHERE h.coalesce_range && tstzrange(p_start - interval '1 hour', now(), '[]')
      AND (sample_record).ts >= p_start - interval '1 hour'
      AND (sample_record).ts <= now()
    UNION ALL
    SELECT
        c.srvid,
        c.dbid,
        c.queryid,
        c.event_type,
        c.event,
        (c.record).ts,
        (c.record).count::numeric
    FROM "PoWA".powa_wait_sampling_history_current AS c
    WHERE (c.record).ts >= p_start - interval '1 hour'
      AND (c.record).ts <= now()
), ordered AS (
    SELECT
        raw_samples.*,
        lag(sample_at) OVER metric_window AS previous_sample_at,
        lag(sample_count) OVER (
            metric_window
        ) AS previous_count,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END AS frequency_seconds
    FROM raw_samples
    JOIN "PoWA".powa_servers AS source ON source.id = raw_samples.server_id
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, query_id, event_type, event
        ORDER BY sample_at
    )
)
SELECT
    server_id,
    database_id,
    query_id,
    event_type,
    event,
    sample_at,
    previous_sample_at,
    CASE
        WHEN previous_count IS NULL THEN 0
        WHEN sample_count >= previous_count THEN sample_count - previous_count
        ELSE sample_count
    END::bigint AS samples,
    previous_sample_at IS NOT NULL AND sample_count < previous_count AS reset_detected,
    previous_sample_at IS NOT NULL AS predecessor_available,
    previous_sample_at IS NOT NULL
        AND sample_at - previous_sample_at
            > make_interval(secs => frequency_seconds * 3) AS gap_detected
FROM ordered
WHERE sample_at >= p_start
  AND query_id <> 0
  AND event_type IS NOT NULL
  AND event IS NOT NULL;
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
    wait_sampling_available boolean,
    wait_sampling_version text,
    wait_sampling_data_available boolean,
    wait_total_samples bigint,
    wait_io_samples bigint,
    wait_lock_samples bigint,
    wait_lwlock_samples bigint,
    wait_client_samples bigint,
    wait_ipc_samples bigint,
    wait_timeout_samples bigint,
    wait_activity_samples bigint,
    wait_extension_samples bigint,
    wait_other_samples bigint,
    dominant_wait_category text,
    dominant_wait_event text,
    dominant_wait_share_percent double precision,
    wait_events jsonb,
    observed_from timestamptz,
    observed_to timestamptz,
    coverage_percent double precision,
    reset_detected boolean,
    comparison_reliable boolean,
    warming_up boolean,
    previous_period_available boolean,
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
WITH bounds AS (
    SELECT
        now() AS observed_until,
        now() - p_window AS current_start,
        now() - (p_window * 2) AS previous_start,
        greatest(extract(epoch FROM p_window), 0)::double precision AS window_seconds
), query_delta_source AS MATERIALIZED (
    SELECT d.*
    FROM bounds AS b
    CROSS JOIN LATERAL advisor.query_deltas(b.previous_start) AS d
    WHERE d.sample_at >= b.previous_start
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
), period AS (
    SELECT
        d.server_id,
        d.database_id,
        d.query_id,
        CASE WHEN count(DISTINCT d.user_id) = 1
             THEN min(d.user_id::bigint)::oid
             ELSE NULL::oid
        END AS user_id,
        sum(d.calls) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::bigint AS calls,
        sum(d.rows) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::bigint AS rows,
        sum(d.total_exec_time_ms) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::double precision AS total_exec_time_ms,
        sum(d.shared_blocks_hit) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::bigint AS shared_blocks_hit,
        sum(d.shared_blocks_read) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::bigint AS shared_blocks_read,
        sum(d.temp_blocks_written) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::bigint AS temp_blocks_written,
        sum(d.wal_bytes) FILTER (
            WHERE d.sample_at >= now() - p_window
              AND d.predecessor_available
              AND NOT (d.gap_detected AND d.previous_sample_at < now() - p_window)
        )::numeric AS wal_bytes,
        sum(d.calls) FILTER (
            WHERE d.sample_at >= now() - (p_window * 2)
              AND d.sample_at < now() - p_window
              AND d.predecessor_available
              AND NOT (
                  d.gap_detected
                  AND d.previous_sample_at < now() - (p_window * 2)
              )
        )::bigint AS previous_calls_raw,
        sum(d.total_exec_time_ms) FILTER (
            WHERE d.sample_at >= now() - (p_window * 2)
              AND d.sample_at < now() - p_window
              AND d.predecessor_available
              AND NOT (
                  d.gap_detected
                  AND d.previous_sample_at < now() - (p_window * 2)
              )
        )::double precision AS previous_total_exec_time_ms_raw
    FROM query_delta_source AS d
    GROUP BY d.server_id, d.database_id, d.query_id
), temporal_samples AS (
    -- Snapshot timestamps are normally shared by all user-id series for a
    -- query.  Collapse those series before summing time intervals so coverage
    -- can never be multiplied by the number of roles that ran the query.
    SELECT
        d.server_id,
        d.database_id,
        d.query_id,
        d.sample_at,
        max(d.previous_sample_at) AS previous_sample_at,
        bool_and(d.predecessor_available) AS predecessor_available,
        bool_or(d.reset_detected) AS reset_detected,
        bool_or(d.gap_detected) AS gap_detected
    FROM query_delta_source AS d
    GROUP BY d.server_id, d.database_id, d.query_id, d.sample_at
), temporal_periods AS (
    SELECT
        sample.server_id,
        sample.database_id,
        sample.query_id,
        min(greatest(sample.previous_sample_at, b.current_start)) FILTER (
            WHERE sample.sample_at >= b.current_start
              AND sample.predecessor_available
              AND NOT sample.gap_detected
        ) AS observed_from,
        max(least(sample.sample_at, b.observed_until)) FILTER (
            WHERE sample.sample_at >= b.current_start
        ) AS observed_to,
        least(
            b.window_seconds,
            sum(
                CASE
                    WHEN sample.sample_at >= b.current_start
                     AND sample.previous_sample_at < b.observed_until
                     AND sample.predecessor_available
                     AND NOT sample.gap_detected
                    THEN greatest(
                        extract(epoch FROM (
                            least(sample.sample_at, b.observed_until)
                            - greatest(sample.previous_sample_at, b.current_start)
                        )),
                        0
                    )
                    ELSE 0
                END
            )
        )::double precision AS current_covered_seconds,
        least(
            b.window_seconds,
            sum(
                CASE
                    WHEN sample.sample_at >= b.current_start
                     AND sample.previous_sample_at < b.observed_until
                     AND sample.predecessor_available
                    THEN greatest(
                        extract(epoch FROM (
                            least(sample.sample_at, b.observed_until)
                            - greatest(sample.previous_sample_at, b.current_start)
                        )),
                        0
                    )
                    ELSE 0
                END
            )
        )::double precision AS current_represented_seconds,
        least(
            b.window_seconds,
            sum(
                CASE
                    WHEN sample.sample_at >= b.previous_start
                     AND sample.sample_at < b.current_start
                     AND sample.previous_sample_at < b.current_start
                     AND sample.predecessor_available
                     AND NOT sample.gap_detected
                    THEN greatest(
                        extract(epoch FROM (
                            least(sample.sample_at, b.current_start)
                            - greatest(sample.previous_sample_at, b.previous_start)
                        )),
                        0
                    )
                    ELSE 0
                END
            )
        )::double precision AS previous_covered_seconds,
        bool_or(sample.reset_detected) FILTER (
            WHERE sample.sample_at >= b.previous_start
        ) AS query_reset_detected,
        bool_or(sample.gap_detected) FILTER (
            WHERE sample.sample_at >= b.previous_start
        ) AS query_gap_detected,
        bool_or(NOT sample.predecessor_available) FILTER (
            WHERE sample.sample_at >= b.previous_start
        ) AS predecessor_missing
    FROM temporal_samples AS sample
    CROSS JOIN bounds AS b
    GROUP BY sample.server_id, sample.database_id, sample.query_id, b.window_seconds
), query_quality AS (
    SELECT
        temporal.*,
        100.0 * temporal.current_covered_seconds
            / NULLIF(b.window_seconds, 0) AS coverage_percent,
        temporal.previous_covered_seconds > 0 AS previous_period_available,
        greatest(
            temporal.current_represented_seconds,
            CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END::double precision
        ) / 3600.0 AS observation_hours,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END::double precision
            AS frequency_seconds,
        (
            temporal.current_covered_seconds >= greatest(
                b.window_seconds - 6.0 * CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END,
                0
            )
            AND temporal.previous_covered_seconds >= greatest(
                b.window_seconds - 6.0 * CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END,
                0
            )
        ) AS coverage_sufficient,
        (
            (
                NOT (temporal.previous_covered_seconds > 0)
                OR COALESCE(temporal.predecessor_missing, false)
            )
            AND NOT COALESCE(temporal.query_gap_detected, false)
        ) AS warming_up
    FROM temporal_periods AS temporal
    JOIN "PoWA".powa_servers AS source ON source.id = temporal.server_id
    CROSS JOIN bounds AS b
), kcache_period AS (
    SELECT
        k.server_id,
        k.database_id,
        k.query_id,
        sum(k.exec_user_time_seconds) FILTER (
            WHERE k.predecessor_available
              AND NOT (
                  k.gap_detected
                  AND k.previous_sample_at < now() - p_window
              )
        ) * 1000.0 AS cpu_user_time_ms,
        sum(k.exec_system_time_seconds) FILTER (
            WHERE k.predecessor_available
              AND NOT (
                  k.gap_detected
                  AND k.previous_sample_at < now() - p_window
              )
        ) * 1000.0 AS cpu_system_time_ms,
        sum(k.filesystem_reads_bytes) FILTER (
            WHERE k.predecessor_available
              AND NOT (
                  k.gap_detected
                  AND k.previous_sample_at < now() - p_window
              )
        )::bigint AS filesystem_reads_bytes,
        sum(k.filesystem_writes_bytes) FILTER (
            WHERE k.predecessor_available
              AND NOT (
                  k.gap_detected
                  AND k.previous_sample_at < now() - p_window
              )
        )::bigint AS filesystem_writes_bytes,
        bool_or(
            k.predecessor_available
            AND NOT (
                k.gap_detected
                AND k.previous_sample_at < now() - p_window
            )
        ) AS data_available,
        bool_or(k.reset_detected) AS reset_detected,
        bool_or(k.gap_detected) AS reliability_issue
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
), wait_delta_source AS MATERIALIZED (
    SELECT w.*
    FROM advisor.wait_deltas(now() - p_window) AS w
    WHERE w.sample_at >= now() - p_window
), wait_period AS (
    SELECT
        w.server_id,
        w.database_id,
        w.query_id,
        w.event_type,
        w.event,
        CASE upper(w.event_type)
            WHEN 'IO' THEN 'IO'
            WHEN 'LOCK' THEN 'LOCK'
            WHEN 'BUFFERPIN' THEN 'LOCK'
            WHEN 'LWLOCK' THEN 'LWLOCK'
            WHEN 'LWLOCKNAMED' THEN 'LWLOCK'
            WHEN 'LWLOCKTRANCHE' THEN 'LWLOCK'
            WHEN 'CLIENT' THEN 'CLIENT'
            WHEN 'IPC' THEN 'IPC'
            WHEN 'TIMEOUT' THEN 'TIMEOUT'
            WHEN 'ACTIVITY' THEN 'ACTIVITY'
            WHEN 'EXTENSION' THEN 'EXTENSION'
            ELSE 'OTHER'
        END AS category,
        sum(w.samples)::bigint AS samples
    FROM wait_delta_source AS w
    WHERE w.samples > 0
      AND w.predecessor_available
      AND NOT (
          w.gap_detected
          AND w.previous_sample_at < now() - p_window
      )
    GROUP BY w.server_id, w.database_id, w.query_id, w.event_type, w.event
), wait_quality AS (
    SELECT
        w.server_id,
        w.database_id,
        w.query_id,
        bool_or(w.reset_detected) AS reset_detected,
        bool_or(w.gap_detected) AS reliability_issue
    FROM wait_delta_source AS w
    GROUP BY w.server_id, w.database_id, w.query_id
), wait_with_category_totals AS (
    SELECT
        wait_period.*,
        sum(samples) OVER (
            PARTITION BY server_id, database_id, query_id, category
        )::bigint AS category_samples
    FROM wait_period
), wait_ranked AS (
    SELECT
        wait_with_category_totals.*,
        row_number() OVER (
            PARTITION BY server_id, database_id, query_id
            ORDER BY samples DESC, event_type, event
        ) AS event_rank,
        row_number() OVER (
            PARTITION BY server_id, database_id, query_id
            ORDER BY category_samples DESC, samples DESC, event_type, event
        ) AS dominant_rank
    FROM wait_with_category_totals
), wait_summary AS (
    SELECT
        w.server_id,
        w.database_id,
        w.query_id,
        sum(w.samples)::bigint AS total_samples,
        sum(w.samples) FILTER (WHERE w.category = 'IO')::bigint AS io_samples,
        sum(w.samples) FILTER (WHERE w.category = 'LOCK')::bigint AS lock_samples,
        sum(w.samples) FILTER (WHERE w.category = 'LWLOCK')::bigint AS lwlock_samples,
        sum(w.samples) FILTER (WHERE w.category = 'CLIENT')::bigint AS client_samples,
        sum(w.samples) FILTER (WHERE w.category = 'IPC')::bigint AS ipc_samples,
        sum(w.samples) FILTER (WHERE w.category = 'TIMEOUT')::bigint AS timeout_samples,
        sum(w.samples) FILTER (WHERE w.category = 'ACTIVITY')::bigint AS activity_samples,
        sum(w.samples) FILTER (WHERE w.category = 'EXTENSION')::bigint AS extension_samples,
        sum(w.samples) FILTER (WHERE w.category = 'OTHER')::bigint AS other_samples,
        max(w.category) FILTER (WHERE w.dominant_rank = 1) AS dominant_category,
        max(w.event) FILTER (WHERE w.dominant_rank = 1) AS dominant_event,
        max(w.category_samples) FILTER (WHERE w.dominant_rank = 1)::bigint AS dominant_samples,
        jsonb_agg(
            jsonb_build_object(
                'category', w.category,
                'eventType', w.event_type,
                'event', w.event,
                'samples', w.samples
            ) ORDER BY w.samples DESC, w.event_type, w.event
        ) AS events
    FROM wait_ranked AS w
    GROUP BY w.server_id, w.database_id, w.query_id
), wait_capability AS (
    SELECT
        config.srvid AS server_id,
        bool_or(config.enabled) AS available,
        max(config.version)::text AS version,
        bool_or(meta.snapts > '-infinity'::timestamptz) AS data_available
    FROM "PoWA".powa_extension_config AS config
    LEFT JOIN "PoWA".powa_snapshot_metas AS meta ON meta.srvid = config.srvid
    WHERE config.extname = 'pg_wait_sampling'
    GROUP BY config.srvid
), enriched_base AS (
    SELECT
        p.*,
        s.query AS sql_text,
        db.datname::text AS database_name,
        COALESCE(cap.available, false) AS kcache_available,
        cap.version AS kcache_version,
        COALESCE(k.data_available, false) AS kcache_data_available,
        k.cpu_user_time_ms,
        k.cpu_system_time_ms,
        k.filesystem_reads_bytes,
        k.filesystem_writes_bytes,
        COALESCE(wait_cap.available, false) AS wait_sampling_available,
        wait_cap.version AS wait_sampling_version,
        COALESCE(wait_cap.data_available, false) AS wait_sampling_data_available,
        COALESCE(ws.total_samples, 0)::bigint AS wait_total_samples,
        COALESCE(ws.io_samples, 0)::bigint AS wait_io_samples,
        COALESCE(ws.lock_samples, 0)::bigint AS wait_lock_samples,
        COALESCE(ws.lwlock_samples, 0)::bigint AS wait_lwlock_samples,
        COALESCE(ws.client_samples, 0)::bigint AS wait_client_samples,
        COALESCE(ws.ipc_samples, 0)::bigint AS wait_ipc_samples,
        COALESCE(ws.timeout_samples, 0)::bigint AS wait_timeout_samples,
        COALESCE(ws.activity_samples, 0)::bigint AS wait_activity_samples,
        COALESCE(ws.extension_samples, 0)::bigint AS wait_extension_samples,
        COALESCE(ws.other_samples, 0)::bigint AS wait_other_samples,
        ws.dominant_category AS dominant_wait_category,
        ws.dominant_event AS dominant_wait_event,
        100.0 * ws.dominant_samples / NULLIF(ws.total_samples, 0) AS dominant_wait_share_percent,
        COALESCE(ws.events, '[]'::jsonb) AS wait_events,
        quality.observed_from,
        quality.observed_to,
        quality.coverage_percent,
        (
            COALESCE(quality.query_reset_detected, false)
            OR COALESCE(k.reset_detected, false)
            OR COALESCE(wait_metric_quality.reset_detected, false)
        ) AS reset_detected,
        (
            quality.previous_period_available
            AND quality.coverage_sufficient
            AND NOT quality.warming_up
            AND NOT COALESCE(quality.query_reset_detected, false)
            AND NOT COALESCE(quality.query_gap_detected, false)
            AND NOT COALESCE(quality.predecessor_missing, false)
            AND NOT COALESCE(k.reset_detected, false)
            AND NOT COALESCE(k.reliability_issue, false)
            AND NOT COALESCE(wait_metric_quality.reset_detected, false)
            AND NOT COALESCE(wait_metric_quality.reliability_issue, false)
        ) AS comparison_reliable,
        quality.warming_up,
        quality.previous_period_available,
        quality.observation_hours,
        CASE
            WHEN quality.previous_period_available
                THEN COALESCE(p.previous_calls_raw, 0)
            ELSE NULL
        END::bigint AS previous_calls,
        CASE
            WHEN quality.previous_period_available
                THEN COALESCE(p.previous_total_exec_time_ms_raw, 0)
            ELSE NULL
        END::double precision AS previous_total_exec_time_ms,
        p.rows / NULLIF(p.calls, 0)::double precision AS rows_per_call,
        p.total_exec_time_ms / NULLIF(p.calls, 0) AS mean_exec_time_ms
    FROM period AS p
    JOIN query_quality AS quality
      ON quality.server_id = p.server_id
     AND quality.database_id = p.database_id
     AND quality.query_id = p.query_id
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
    LEFT JOIN wait_summary AS ws
      ON ws.server_id = p.server_id
     AND ws.database_id = p.database_id
     AND ws.query_id = p.query_id
    LEFT JOIN wait_quality AS wait_metric_quality
      ON wait_metric_quality.server_id = p.server_id
     AND wait_metric_quality.database_id = p.database_id
     AND wait_metric_quality.query_id = p.query_id
    LEFT JOIN wait_capability AS wait_cap ON wait_cap.server_id = p.server_id
    WHERE COALESCE(p.calls, 0) > 0
      AND s.query !~* '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK|SET|SHOW)([[:space:]]|$)'
), enriched AS (
    SELECT
        base.*,
        base.previous_total_exec_time_ms
            / NULLIF(base.previous_calls, 0) AS previous_mean_exec_time_ms,
        CASE
            WHEN base.comparison_reliable THEN 100.0 * (
                base.mean_exec_time_ms
                - base.previous_total_exec_time_ms / NULLIF(base.previous_calls, 0)
            ) / NULLIF(
                base.previous_total_exec_time_ms / NULLIF(base.previous_calls, 0),
                0
            )
            ELSE NULL
        END AS regression_percent
    FROM enriched_base AS base
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
        CASE WHEN e.comparison_reliable
                   AND e.previous_period_available
                   AND COALESCE(e.regression_percent, 0) >= 20
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
        CASE WHEN e.comparison_reliable
                  AND e.previous_period_available
                  AND COALESCE(e.regression_percent, 0) >= 20
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
    sc.wait_sampling_available,
    sc.wait_sampling_version,
    sc.wait_sampling_data_available,
    sc.wait_total_samples,
    sc.wait_io_samples,
    sc.wait_lock_samples,
    sc.wait_lwlock_samples,
    sc.wait_client_samples,
    sc.wait_ipc_samples,
    sc.wait_timeout_samples,
    sc.wait_activity_samples,
    sc.wait_extension_samples,
    sc.wait_other_samples,
    sc.dominant_wait_category,
    sc.dominant_wait_event,
    sc.dominant_wait_share_percent,
    sc.wait_events,
    sc.observed_from,
    sc.observed_to,
    sc.coverage_percent,
    sc.reset_detected,
    sc.comparison_reliable,
    sc.warming_up,
    sc.previous_period_available,
    sc.previous_calls,
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
WHERE comparison_reliable
  AND previous_period_available
  AND regression_percent >= 20
  AND previous_calls >= 20
  AND calls >= 20;

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

CREATE OR REPLACE FUNCTION advisor_ingest.refresh_candidates(
    p_server_id integer,
    p_batch_id bigint
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_count integer;
BEGIN
    -- Product query identity is server/database/query_id, matching the public
    -- metrics API.  Aggregate identical predicate evidence across PostgreSQL
    -- users before candidate_id generation; retaining userid here would emit
    -- duplicate conflict keys in a single upsert for shared queries.
    WITH join_sides AS (
        SELECT
            sample.server_id,
            sample.batch_id,
            sample.dbid,
            sample.queryid,
            side.relation_id,
            side.attribute_number,
            sample.opno,
            sample.occurences
        FROM advisor_ingest.join_predicate_samples AS sample
        CROSS JOIN LATERAL (
            VALUES
                (sample.lrelid, sample.lattnum),
                (sample.rrelid, sample.rattnum)
        ) AS side(relation_id, attribute_number)
        WHERE sample.server_id = p_server_id
          AND sample.batch_id = p_batch_id
          AND sample.is_join
          AND sample.btree_strategy = 3
          AND side.relation_id IS NOT NULL
          AND side.attribute_number IS NOT NULL
    ), join_metrics AS (
        SELECT
            server_id, batch_id, dbid, queryid, relation_id,
            attribute_number, min(opno)::oid AS opno,
            sum(occurences)::bigint AS join_occurrences
        FROM join_sides
        GROUP BY server_id, batch_id, dbid, queryid, relation_id, attribute_number
    ), filter_metrics AS (
        SELECT
            sample.server_id,
            sample.batch_id,
            sample.dbid,
            sample.queryid,
            sample.lrelid AS relation_id,
            sample.lattnum AS attribute_number,
            min(sample.opno)::oid AS opno,
            min(sample.btree_strategy)::smallint AS btree_strategy,
            sum(sample.occurences)::bigint AS filter_occurrences,
            sum(sample.execution_count)::bigint AS rows_processed,
            sum(sample.nbfiltered)::bigint AS rows_filtered
        FROM advisor_ingest.join_predicate_samples AS sample
        WHERE sample.server_id = p_server_id
          AND sample.batch_id = p_batch_id
          AND NOT sample.is_join
          AND sample.lrelid IS NOT NULL
          AND sample.lattnum IS NOT NULL
          AND sample.rrelid IS NULL
          AND sample.btree_strategy BETWEEN 1 AND 5
        GROUP BY
            sample.server_id, sample.batch_id, sample.dbid,
            sample.queryid, sample.lrelid, sample.lattnum
    ), pairs AS (
        SELECT
            join_metric.server_id,
            join_metric.batch_id,
            join_metric.dbid,
            join_metric.queryid,
            join_metric.relation_id,
            CASE
                WHEN filter_metric.btree_strategy = 3
                 AND filter_metric.rows_filtered::double precision
                     / NULLIF(filter_metric.rows_processed, 0) >= 0.20
                    THEN ARRAY[filter_metric.attribute_number, join_metric.attribute_number]::smallint[]
                ELSE ARRAY[join_metric.attribute_number, filter_metric.attribute_number]::smallint[]
            END AS key_attnums,
            CASE
                WHEN filter_metric.btree_strategy = 3
                 AND filter_metric.rows_filtered::double precision
                     / NULLIF(filter_metric.rows_processed, 0) >= 0.20
                    THEN ARRAY[filter_metric.opno, join_metric.opno]::oid[]
                ELSE ARRAY[join_metric.opno, filter_metric.opno]::oid[]
            END AS operator_oids,
            CASE
                WHEN filter_metric.btree_strategy <> 3 THEN 'EQUALITY_JOIN_THEN_RANGE_FILTER'
                WHEN filter_metric.rows_filtered::double precision
                     / NULLIF(filter_metric.rows_processed, 0) >= 0.20
                    THEN 'SELECTIVE_EQUALITY_FILTER_THEN_JOIN'
                ELSE 'EQUALITY_JOIN_THEN_FILTER'
            END AS ordering_rule,
            join_metric.join_occurrences,
            filter_metric.filter_occurrences,
            filter_metric.rows_processed,
            filter_metric.rows_filtered
        FROM join_metrics AS join_metric
        JOIN filter_metrics AS filter_metric
         ON filter_metric.server_id = join_metric.server_id
         AND filter_metric.batch_id = join_metric.batch_id
         AND filter_metric.dbid = join_metric.dbid
         AND filter_metric.queryid = join_metric.queryid
         AND filter_metric.relation_id = join_metric.relation_id
         AND filter_metric.attribute_number <> join_metric.attribute_number
    ), resolved AS (
        SELECT
            pair.*,
            COALESCE(namespace.nspname::text, 'unknown') AS schema_name,
            COALESCE(class.relname::text, 'relation-' || pair.relation_id::text) AS table_name,
            ARRAY[first_attribute.attname::text, second_attribute.attname::text] AS key_column_names,
            batch.captured_at,
            md5(
                pair.server_id::text || ':' || pair.dbid::text || ':' || pair.queryid::text || ':' ||
                pair.relation_id::text || ':' || array_to_string(pair.key_attnums, ',')
            )::uuid AS candidate_id
        FROM pairs AS pair
        JOIN advisor_ingest.join_snapshot_batches AS batch
          ON batch.server_id = pair.server_id AND batch.batch_id = pair.batch_id
        LEFT JOIN "PoWA".powa_catalog_class AS class
          ON class.srvid = pair.server_id AND class.dbid = pair.dbid AND class.oid = pair.relation_id
        LEFT JOIN "PoWA".powa_catalog_namespace AS namespace
          ON namespace.srvid = class.srvid AND namespace.dbid = class.dbid
         AND namespace.oid = class.relnamespace
        LEFT JOIN "PoWA".powa_catalog_attribute AS first_attribute
          ON first_attribute.srvid = pair.server_id AND first_attribute.dbid = pair.dbid
         AND first_attribute.attrelid = pair.relation_id
         AND first_attribute.attnum = pair.key_attnums[1]
        LEFT JOIN "PoWA".powa_catalog_attribute AS second_attribute
          ON second_attribute.srvid = pair.server_id AND second_attribute.dbid = pair.dbid
         AND second_attribute.attrelid = pair.relation_id
         AND second_attribute.attnum = pair.key_attnums[2]
        WHERE first_attribute.attname IS NOT NULL
          AND second_attribute.attname IS NOT NULL
          AND COALESCE(namespace.nspname::text, '') !~ '^(pg_|information_schema$)'
    ), upserted AS (
        INSERT INTO advisor.index_candidates (
            candidate_id, server_id, database_id, query_id, relation_id,
            schema_name, table_name, key_attnums, key_column_names,
            operator_oids, ordering_rule, first_supported_at, last_supported_at
        )
        SELECT
            candidate_id, server_id, dbid, queryid, relation_id,
            schema_name, table_name, key_attnums, key_column_names,
            operator_oids, ordering_rule, captured_at, captured_at
        FROM resolved
        ON CONFLICT (candidate_id) DO UPDATE
           SET schema_name = EXCLUDED.schema_name,
               table_name = EXCLUDED.table_name,
               key_column_names = EXCLUDED.key_column_names,
               operator_oids = EXCLUDED.operator_oids,
               ordering_rule = EXCLUDED.ordering_rule,
               last_supported_at = GREATEST(
                   advisor.index_candidates.last_supported_at,
                   EXCLUDED.last_supported_at
               )
        RETURNING candidate_id
    )
    INSERT INTO advisor.index_candidate_evidence (
        candidate_id, server_id, batch_id, captured_at,
        join_occurrences, filter_occurrences, rows_processed, rows_filtered
    )
    SELECT
        resolved.candidate_id, resolved.server_id, resolved.batch_id,
        resolved.captured_at, resolved.join_occurrences,
        resolved.filter_occurrences, resolved.rows_processed,
        resolved.rows_filtered
    FROM resolved
    JOIN upserted USING (candidate_id)
    ON CONFLICT (candidate_id, server_id, batch_id) DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_ingest.bind_join_source_role(
    p_role name,
    p_server_alias text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
BEGIN
    IF p_role IS NULL OR btrim(p_role::text) = '' THEN
        RAISE EXCEPTION 'join ingest role is required';
    END IF;
    IF p_server_alias IS NULL OR btrim(p_server_alias) = '' THEN
        RAISE EXCEPTION 'join source alias is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'join ingest role % does not exist', p_role;
    END IF;

    SELECT server.id INTO STRICT v_server_id
      FROM "PoWA".powa_servers AS server
     WHERE server.alias = p_server_alias;

    INSERT INTO advisor_ingest.join_source_role_bindings (
        role_name, server_id, bound_at
    ) VALUES (
        p_role, v_server_id, clock_timestamp()
    )
    ON CONFLICT (role_name) DO UPDATE
       SET server_id = EXCLUDED.server_id,
           bound_at = EXCLUDED.bound_at;

    -- Reapply the complete least-privilege envelope on every bind/rotation.
    -- The role gets no table, sequence, helper, admin, or global purge access.
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), p_role);
    EXECUTE format('REVOKE ALL ON SCHEMA advisor, advisor_ingest FROM %I', p_role);
    EXECUTE format(
        'REVOKE ALL ON ALL TABLES IN SCHEMA advisor, advisor_ingest FROM %I', p_role
    );
    EXECUTE format(
        'REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor, advisor_ingest FROM %I', p_role
    );
    EXECUTE format(
        'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA advisor, advisor_ingest FROM %I', p_role
    );
    EXECUTE format('GRANT USAGE ON SCHEMA advisor_ingest TO %I', p_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.ingest_join_batch(text,bigint,timestamptz,jsonb) TO %I',
        p_role
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.record_join_error(text,text) TO %I',
        p_role
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.purge_join_source_history(text,interval) TO %I',
        p_role
    );

    RETURN v_server_id;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_ingest.bound_join_server(p_server_alias text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
BEGIN
    SELECT binding.server_id INTO v_server_id
      FROM advisor_ingest.join_source_role_bindings AS binding
      JOIN "PoWA".powa_servers AS server ON server.id = binding.server_id
     WHERE binding.role_name = session_user::name
       AND server.alias = p_server_alias;

    IF v_server_id IS NULL THEN
        RAISE EXCEPTION 'join ingest login % is not bound to source alias %',
            session_user, p_server_alias
            USING ERRCODE = '42501';
    END IF;
    RETURN v_server_id;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_ingest.ingest_join_batch(
    p_server_alias text,
    p_batch_id bigint,
    p_captured_at timestamptz,
    p_rows jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
    v_inserted integer;
    v_row_count integer;
BEGIN
    IF p_batch_id IS NULL
       OR p_batch_id < 1
       OR p_captured_at IS NULL
       OR p_rows IS NULL
       OR jsonb_typeof(p_rows) <> 'array' THEN
        RAISE EXCEPTION 'invalid join snapshot batch';
    END IF;
    v_row_count := jsonb_array_length(p_rows);
    IF v_row_count > 50000 THEN
        RAISE EXCEPTION 'join snapshot batch exceeds 50000 rows';
    END IF;

    v_server_id := advisor_ingest.bound_join_server(p_server_alias);

    INSERT INTO advisor_ingest.join_snapshot_batches (
        server_id, batch_id, captured_at, row_count
    ) VALUES (
        v_server_id, p_batch_id, p_captured_at, v_row_count
    ) ON CONFLICT (server_id, batch_id) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted > 0 THEN
        INSERT INTO advisor_ingest.join_predicate_samples (
            server_id, batch_id, dbid, userid, queryid, qualid, qualnodeid,
            lrelid, lattnum, opno, operator_name, operator_commutator,
            btree_strategy, rrelid, rattnum, occurences, execution_count,
            nbfiltered, eval_type, is_join
        )
        SELECT
            v_server_id, p_batch_id, row.dbid, row.userid, row.queryid,
            row.qualid, row.qualnodeid, row.lrelid, row.lattnum, row.opno,
            row."operatorName", row."operatorCommutator", row."btreeStrategy",
            row.rrelid, row.rattnum, row.occurences, row."executionCount",
            row.nbfiltered, substring(COALESCE(row."evalType", 'f'), 1, 1)::"char",
            row."isJoin"
        FROM jsonb_to_recordset(p_rows) AS row(
            dbid oid, userid oid, queryid bigint, qualid bigint, qualnodeid bigint,
            lrelid oid, lattnum smallint, opno oid, "operatorName" text,
            "operatorCommutator" oid, "btreeStrategy" smallint,
            rrelid oid, rattnum smallint, occurences bigint,
            "executionCount" bigint, nbfiltered bigint, "evalType" text,
            "isJoin" boolean
        )
        WHERE row.queryid <> 0
          AND row.opno IS NOT NULL
          AND row.occurences >= 0
          AND row."executionCount" >= 0
          AND row.nbfiltered >= 0
        ON CONFLICT DO NOTHING;

        PERFORM advisor_ingest.refresh_candidates(v_server_id, p_batch_id);
    END IF;

    INSERT INTO advisor_ingest.join_source_status (
        server_id, status, last_capture_at, last_ingest_at,
        last_batch_id, last_row_count, last_error, updated_at
    ) VALUES (
        v_server_id, 'HEALTHY', p_captured_at, clock_timestamp(),
        p_batch_id, v_row_count, NULL, clock_timestamp()
    ) ON CONFLICT (server_id) DO UPDATE
       SET status = 'HEALTHY',
           last_capture_at = GREATEST(
               advisor_ingest.join_source_status.last_capture_at,
               EXCLUDED.last_capture_at
           ),
           last_ingest_at = EXCLUDED.last_ingest_at,
           last_batch_id = GREATEST(
               advisor_ingest.join_source_status.last_batch_id,
               EXCLUDED.last_batch_id
           ),
           last_row_count = EXCLUDED.last_row_count,
           last_error = NULL,
           updated_at = EXCLUDED.updated_at;
    RETURN v_inserted > 0;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_ingest.record_join_error(
    p_server_alias text,
    p_error text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
BEGIN
    v_server_id := advisor_ingest.bound_join_server(p_server_alias);
    INSERT INTO advisor_ingest.join_source_status(server_id, status, last_error, updated_at)
    VALUES (
        v_server_id,
        'ERROR',
        left(COALESCE(NULLIF(p_error, ''), 'unspecified join snapshotter error'), 500),
        clock_timestamp()
    )
    ON CONFLICT (server_id) DO UPDATE
       SET status = 'ERROR',
           last_error = EXCLUDED.last_error,
           updated_at = EXCLUDED.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_ingest.purge_join_source_history(
    p_server_alias text,
    p_retention interval DEFAULT interval '30 days'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
    v_deleted bigint;
BEGIN
    IF p_retention IS NULL
       OR p_retention < interval '1 day'
       OR p_retention > interval '365 days' THEN
        RAISE EXCEPTION 'join retention must be between 1 and 365 days';
    END IF;
    v_server_id := advisor_ingest.bound_join_server(p_server_alias);

    DELETE FROM advisor.index_candidate_evidence
     WHERE server_id = v_server_id
       AND captured_at < now() - p_retention;
    DELETE FROM advisor_ingest.join_snapshot_batches
     WHERE server_id = v_server_id
       AND captured_at < now() - p_retention;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    DELETE FROM advisor.index_candidates
     WHERE server_id = v_server_id
       AND last_supported_at < now() - p_retention;
    RETURN v_deleted;
END;
$$;

-- Central repository maintenance can still enforce a global retention policy,
-- but this function is deliberately never granted to a source snapshotter.
CREATE OR REPLACE FUNCTION advisor_ingest.purge_join_history(p_retention interval DEFAULT interval '30 days')
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_deleted bigint;
BEGIN
    IF p_retention IS NULL
       OR p_retention < interval '1 day'
       OR p_retention > interval '365 days' THEN
        RAISE EXCEPTION 'join retention must be between 1 and 365 days';
    END IF;
    DELETE FROM advisor.index_candidate_evidence
     WHERE captured_at < now() - p_retention;
    DELETE FROM advisor_ingest.join_snapshot_batches
     WHERE captured_at < now() - p_retention;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    DELETE FROM advisor.index_candidates
     WHERE last_supported_at < now() - p_retention;
    RETURN v_deleted;
END;
$$;

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

CREATE OR REPLACE FUNCTION advisor.join_predicate_metrics(
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
    qual_id bigint,
    qual_node_id bigint,
    left_relation_id oid,
    left_schema_name text,
    left_table_name text,
    left_attribute_number smallint,
    left_column_name text,
    right_relation_id oid,
    right_schema_name text,
    right_table_name text,
    right_attribute_number smallint,
    right_column_name text,
    operator_oid oid,
    operator_name text,
    btree_strategy smallint,
    occurrences bigint,
    rows_processed bigint,
    sample_count bigint,
    observed_from timestamptz,
    observed_to timestamptz,
    signal text,
    score_included boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor
AS $$
WITH metrics AS (
    SELECT
        sample.server_id,
        sample.dbid,
        sample.queryid,
        sample.qualid,
        sample.qualnodeid,
        sample.lrelid,
        sample.lattnum,
        sample.rrelid,
        sample.rattnum,
        sample.opno,
        max(sample.operator_name) AS operator_name,
        min(sample.btree_strategy)::smallint AS btree_strategy,
        sum(sample.occurences)::bigint AS occurrences,
        sum(sample.execution_count)::bigint AS rows_processed,
        count(DISTINCT sample.batch_id)::bigint AS sample_count,
        min(batch.captured_at) AS observed_from,
        max(batch.captured_at) AS observed_to
    FROM advisor_ingest.join_predicate_samples AS sample
    JOIN advisor_ingest.join_snapshot_batches AS batch
      ON batch.server_id = sample.server_id AND batch.batch_id = sample.batch_id
    WHERE sample.is_join
      AND batch.captured_at >= now() - p_window
      AND (p_server_id IS NULL OR sample.server_id = p_server_id)
      AND (p_database_id IS NULL OR sample.dbid = p_database_id)
      AND (p_query_id IS NULL OR sample.queryid = p_query_id)
    GROUP BY
        sample.server_id, sample.dbid, sample.queryid, sample.qualid,
        sample.qualnodeid, sample.lrelid, sample.lattnum,
        sample.rrelid, sample.rattnum, sample.opno
)
SELECT
    metric.server_id,
    COALESCE(server.alias::text, server.hostname::text, 'server-' || metric.server_id::text),
    metric.dbid,
    COALESCE(database.datname::text, 'db-' || metric.dbid::text),
    metric.queryid,
    metric.qualid,
    metric.qualnodeid,
    metric.lrelid,
    COALESCE(left_namespace.nspname::text, 'unknown'),
    COALESCE(left_class.relname::text, 'relation-' || metric.lrelid::text),
    metric.lattnum,
    COALESCE(left_attribute.attname::text, 'column-' || metric.lattnum::text),
    metric.rrelid,
    COALESCE(right_namespace.nspname::text, 'unknown'),
    COALESCE(right_class.relname::text, 'relation-' || metric.rrelid::text),
    metric.rattnum,
    COALESCE(right_attribute.attname::text, 'column-' || metric.rattnum::text),
    metric.opno,
    metric.operator_name,
    metric.btree_strategy,
    metric.occurrences,
    metric.rows_processed,
    metric.sample_count,
    metric.observed_from,
    metric.observed_to,
    CASE
        WHEN metric.sample_count < 2 OR metric.occurrences < 5 THEN 'INSUFFICIENT_DATA'
        WHEN metric.occurrences >= 20 THEN 'FREQUENT_JOIN'
        ELSE 'OBSERVED_JOIN'
    END,
    false
FROM metrics AS metric
LEFT JOIN "PoWA".powa_servers AS server ON server.id = metric.server_id
LEFT JOIN "PoWA".powa_databases AS database
  ON database.srvid = metric.server_id AND database.oid = metric.dbid
LEFT JOIN "PoWA".powa_catalog_class AS left_class
  ON left_class.srvid = metric.server_id AND left_class.dbid = metric.dbid
 AND left_class.oid = metric.lrelid
LEFT JOIN "PoWA".powa_catalog_namespace AS left_namespace
  ON left_namespace.srvid = left_class.srvid AND left_namespace.dbid = left_class.dbid
 AND left_namespace.oid = left_class.relnamespace
LEFT JOIN "PoWA".powa_catalog_attribute AS left_attribute
  ON left_attribute.srvid = metric.server_id AND left_attribute.dbid = metric.dbid
 AND left_attribute.attrelid = metric.lrelid AND left_attribute.attnum = metric.lattnum
LEFT JOIN "PoWA".powa_catalog_class AS right_class
  ON right_class.srvid = metric.server_id AND right_class.dbid = metric.dbid
 AND right_class.oid = metric.rrelid
LEFT JOIN "PoWA".powa_catalog_namespace AS right_namespace
  ON right_namespace.srvid = right_class.srvid AND right_namespace.dbid = right_class.dbid
 AND right_namespace.oid = right_class.relnamespace
LEFT JOIN "PoWA".powa_catalog_attribute AS right_attribute
  ON right_attribute.srvid = metric.server_id AND right_attribute.dbid = metric.dbid
 AND right_attribute.attrelid = metric.rrelid AND right_attribute.attnum = metric.rattnum
WHERE COALESCE(left_namespace.nspname::text, '') !~ '^(pg_|information_schema$)'
  AND COALESCE(right_namespace.nspname::text, '') !~ '^(pg_|information_schema$)'
ORDER BY metric.occurrences DESC, metric.qualnodeid;
$$;

CREATE OR REPLACE FUNCTION advisor.join_snapshot_capability(p_server_id integer)
RETURNS TABLE (
    available boolean,
    data_available boolean,
    status text,
    last_snapshot_at timestamptz,
    lag_seconds double precision,
    capture_mode text,
    reason text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor
AS $$
SELECT
    source.server_id IS NOT NULL,
    source.last_capture_at IS NOT NULL,
    CASE
        WHEN source.server_id IS NULL THEN 'UNAVAILABLE'
        WHEN source.last_error IS NOT NULL THEN 'ERROR'
        WHEN source.last_capture_at < now() - make_interval(
            secs => greatest(COALESCE(server.frequency, 60), 5) * 3 + 30
        ) THEN 'DEGRADED'
        ELSE source.status
    END,
    source.last_capture_at,
    extract(epoch FROM clock_timestamp() - source.last_capture_at)::double precision,
    'QUALSTATS_RESET_BOUNDARY',
    CASE
        WHEN source.server_id IS NULL THEN 'JOIN snapshotter bu kaynak icin yapilandirilmamis.'
        WHEN source.last_error IS NOT NULL THEN 'JOIN snapshotter son aktarimda hata raporladi.'
        WHEN source.last_capture_at < now() - make_interval(
            secs => greatest(COALESCE(server.frequency, 60), 5) * 3 + 30
        ) THEN 'JOIN snapshotter verisi kaynak snapshot frekansina gore gecikmis.'
        ELSE 'JOIN predicate outbox aktarimi saglikli.'
    END
FROM (SELECT p_server_id AS requested_server) AS requested
LEFT JOIN advisor_ingest.join_source_status AS source
  ON source.server_id = requested.requested_server
LEFT JOIN "PoWA".powa_servers AS server
  ON server.id = requested.requested_server;
$$;

CREATE OR REPLACE FUNCTION advisor.composite_index_candidates(
    p_window interval DEFAULT interval '24 hours',
    p_server_id integer DEFAULT NULL,
    p_database_id oid DEFAULT NULL,
    p_query_id bigint DEFAULT NULL
)
RETURNS TABLE (
    candidate_id uuid,
    server_id integer,
    database_id oid,
    query_id bigint,
    relation_id oid,
    schema_name text,
    table_name text,
    method text,
    key_column_names text[],
    key_attnums smallint[],
    operator_oids oid[],
    ordering_rule text,
    join_occurrences bigint,
    filter_occurrences bigint,
    rows_processed bigint,
    rows_filtered bigint,
    filter_ratio double precision,
    sample_count bigint,
    observed_from timestamptz,
    observed_to timestamptz,
    confidence text,
    create_index_sql text,
    existing_index_checked boolean,
    score_included boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor
AS $$
WITH evidence AS (
    SELECT
        candidate.candidate_id,
        sum(sample.join_occurrences)::bigint AS join_occurrences,
        sum(sample.filter_occurrences)::bigint AS filter_occurrences,
        sum(sample.rows_processed)::bigint AS rows_processed,
        sum(sample.rows_filtered)::bigint AS rows_filtered,
        count(*)::bigint AS sample_count,
        min(sample.captured_at) AS observed_from,
        max(sample.captured_at) AS observed_to
    FROM advisor.index_candidates AS candidate
    JOIN advisor.index_candidate_evidence AS sample USING (candidate_id)
    WHERE sample.captured_at >= now() - p_window
      AND (p_server_id IS NULL OR candidate.server_id = p_server_id)
      AND (p_database_id IS NULL OR candidate.database_id = p_database_id)
      AND (p_query_id IS NULL OR candidate.query_id = p_query_id)
    GROUP BY candidate.candidate_id
)
SELECT
    candidate.candidate_id,
    candidate.server_id,
    candidate.database_id,
    candidate.query_id,
    candidate.relation_id,
    candidate.schema_name,
    candidate.table_name,
    candidate.method,
    candidate.key_column_names,
    candidate.key_attnums,
    candidate.operator_oids,
    candidate.ordering_rule,
    evidence.join_occurrences,
    evidence.filter_occurrences,
    evidence.rows_processed,
    evidence.rows_filtered,
    LEAST(1.0, GREATEST(
        0.0,
        evidence.rows_filtered::double precision / NULLIF(evidence.rows_processed, 0)
    )),
    evidence.sample_count,
    evidence.observed_from,
    evidence.observed_to,
    CASE
        WHEN evidence.sample_count >= 3
         AND evidence.join_occurrences >= 20
         AND evidence.filter_occurrences >= 20
         AND evidence.rows_filtered::double precision / NULLIF(evidence.rows_processed, 0) >= 0.20
            THEN 'HIGH'
        WHEN evidence.sample_count >= 2
         AND evidence.join_occurrences >= 5
         AND evidence.filter_occurrences >= 5
            THEN 'MEDIUM'
        ELSE 'LOW'
    END,
    format(
        'CREATE INDEX CONCURRENTLY %I ON %I.%I USING btree (%I, %I);',
        'idx_advisor_' || left(regexp_replace(candidate.table_name, '[^a-zA-Z0-9_]+', '_', 'g'), 24)
            || '_' || substr(replace(candidate.candidate_id::text, '-', ''), 1, 8),
        candidate.schema_name,
        candidate.table_name,
        candidate.key_column_names[1],
        candidate.key_column_names[2]
    ),
    false,
    false
FROM advisor.index_candidates AS candidate
JOIN evidence USING (candidate_id)
WHERE evidence.sample_count >= 2
  AND evidence.join_occurrences >= 5
  AND evidence.filter_occurrences >= 5
ORDER BY
    CASE
        WHEN evidence.sample_count >= 3
         AND evidence.join_occurrences >= 20
         AND evidence.filter_occurrences >= 20 THEN 1
        ELSE 2
    END,
    evidence.join_occurrences + evidence.filter_occurrences DESC;
$$;

GRANT USAGE ON SCHEMA advisor TO advisor_api;
GRANT SELECT ON ALL TABLES IN SCHEMA advisor TO advisor_api;
GRANT INSERT, UPDATE ON advisor.query_annotations TO advisor_api;
GRANT INSERT ON advisor.audit_log TO advisor_api;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA advisor TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.query_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.kcache_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.wait_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.query_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.index_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.database_io_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.io_metrics(interval) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.operation_metrics(interval) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.predicate_metrics(interval, integer, oid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.predicate_metrics(interval, integer, oid, bigint) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.predicate_capability(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.predicate_capability(integer) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.join_predicate_metrics(interval, integer, oid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.join_predicate_metrics(interval, integer, oid, bigint) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.join_snapshot_capability(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.join_snapshot_capability(integer) TO advisor_api;
REVOKE ALL ON FUNCTION advisor.composite_index_candidates(interval, integer, oid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.composite_index_candidates(interval, integer, oid, bigint) TO advisor_api;

REVOKE ALL ON SCHEMA advisor_ingest FROM PUBLIC, advisor_api;
REVOKE ALL ON ALL TABLES IN SCHEMA advisor_ingest FROM PUBLIC, advisor_api;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor_ingest FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.refresh_candidates(integer, bigint)
    FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.bind_join_source_role(name, text)
    FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.bound_join_server(text)
    FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.ingest_join_batch(text, bigint, timestamptz, jsonb)
    FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.record_join_error(text, text)
    FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.purge_join_source_history(text, interval)
    FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor_ingest.purge_join_history(interval)
    FROM PUBLIC, advisor_api;

-- The adapter is intentionally rerunnable before an existing installation has
-- created its new snapshotter login.  Fresh installs create the role first;
-- the existing-volume migration creates it and reapplies this file.  Keeping
-- the role-specific ACLs conditional avoids coupling unrelated wait/CPU schema
-- upgrades to a credential that may not exist yet.
DO $acl$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_join_ingest') THEN
        REVOKE ALL ON SCHEMA advisor_ingest FROM advisor_join_ingest;
        REVOKE ALL ON ALL TABLES IN SCHEMA advisor_ingest FROM advisor_join_ingest;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor_ingest FROM advisor_join_ingest;
        REVOKE ALL ON FUNCTION advisor_ingest.refresh_candidates(integer, bigint)
            FROM advisor_join_ingest;
        REVOKE ALL ON FUNCTION advisor_ingest.bind_join_source_role(name, text)
            FROM advisor_join_ingest;
        REVOKE ALL ON FUNCTION advisor_ingest.bound_join_server(text)
            FROM advisor_join_ingest;
        REVOKE ALL ON FUNCTION advisor_ingest.purge_join_history(interval)
            FROM advisor_join_ingest;
        GRANT USAGE ON SCHEMA advisor_ingest TO advisor_join_ingest;
        GRANT EXECUTE ON FUNCTION advisor_ingest.ingest_join_batch(text, bigint, timestamptz, jsonb)
            TO advisor_join_ingest;
        GRANT EXECUTE ON FUNCTION advisor_ingest.record_join_error(text, text)
            TO advisor_join_ingest;
        GRANT EXECUTE ON FUNCTION advisor_ingest.purge_join_source_history(text, interval)
            TO advisor_join_ingest;
    END IF;
END
$acl$;

ALTER DEFAULT PRIVILEGES IN SCHEMA advisor GRANT SELECT ON TABLES TO advisor_api;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor GRANT EXECUTE ON FUNCTIONS TO advisor_api;

COMMENT ON SCHEMA advisor IS
'Urun verileri ve PoWA surumunden bagimsiz adapter katmani. PoWA tablolarina dokunulmaz; pinned 5.2.0 qualstats purge uyumluluk migrasyonu ayri uygulanir.';
