\set ON_ERROR_STOP on

-- Forward migration for already initialized repository volumes.
-- Keep this definition set aligned with the reset/coverage section in
-- 001_advisor_schema.sql; the fresh schema and upgrade path intentionally
-- expose the same function signatures and reliability semantics.
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

GRANT EXECUTE ON FUNCTION advisor.query_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.kcache_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.wait_deltas(timestamptz) TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.query_metrics(interval) TO advisor_api;
GRANT SELECT ON advisor.v_query_summary, advisor.v_query_regression,
    advisor.v_query_impact TO advisor_api;
