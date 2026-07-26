\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION advisor._query_trend(
    p_start timestamptz,
    p_bucket interval,
    p_server_id integer,
    p_database_id oid,
    p_query_id bigint,
    p_scoped boolean
)
RETURNS TABLE (
    bucket_at timestamptz,
    total_exec_time_ms double precision,
    calls bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
SET plan_cache_mode = force_custom_plan
AS $$
WITH params AS MATERIALIZED (
    SELECT p_start AS start_at, p_bucket AS bucket
), valid_series AS MATERIALIZED (
    SELECT
        statement.srvid,
        statement.dbid,
        statement.queryid,
        statement.userid
    FROM "PoWA".powa_statements AS statement
    JOIN "PoWA".powa_databases AS database
      ON database.srvid = statement.srvid
     AND database.oid = statement.dbid
    WHERE database.datname <> 'powa'
      AND (
          NOT p_scoped
          OR (
              (p_server_id IS NULL OR statement.srvid = p_server_id)
              AND (p_database_id IS NULL OR statement.dbid = p_database_id)
              AND (p_query_id IS NULL OR statement.queryid = p_query_id)
          )
      )
      AND statement.query ~* '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)'
), active_series AS MATERIALIZED (
    -- Chunk headers are enough to identify candidate series.  Avoid scanning
    -- and materializing every record once merely to calculate min(sample_at).
    SELECT DISTINCT
        candidate.server_id,
        candidate.database_id,
        candidate.query_id,
        candidate.user_id,
        candidate.toplevel
    FROM (
        SELECT
            history.srvid AS server_id,
            history.dbid AS database_id,
            history.queryid AS query_id,
            history.userid AS user_id,
            history.toplevel
        FROM params
        JOIN "PoWA".powa_statements_history AS history
          ON history.coalesce_range
             && tstzrange(params.start_at, now(), '[]')
        JOIN valid_series AS series
          ON series.srvid = history.srvid
         AND series.dbid = history.dbid
         AND series.queryid = history.queryid
         AND series.userid = history.userid
        WHERE history.toplevel

        UNION ALL

        SELECT
            current_sample.srvid,
            current_sample.dbid,
            current_sample.queryid,
            current_sample.userid,
            current_sample.toplevel
        FROM params
        JOIN "PoWA".powa_statements_history_current AS current_sample
          ON (current_sample.record).ts >= params.start_at
        JOIN valid_series AS series
          ON series.srvid = current_sample.srvid
         AND series.dbid = current_sample.dbid
         AND series.queryid = current_sample.queryid
         AND series.userid = current_sample.userid
        WHERE current_sample.toplevel
    ) AS candidate
), active_samples AS (
    SELECT
        history.srvid AS server_id,
        history.dbid AS database_id,
        history.queryid AS query_id,
        history.userid AS user_id,
        history.toplevel,
        (sample_record).ts AS sample_at,
        (sample_record).calls AS calls,
        (sample_record).total_exec_time AS total_exec_time_ms
    FROM params
    JOIN "PoWA".powa_statements_history AS history
      ON history.coalesce_range
         && tstzrange(params.start_at, now(), '[]')
    JOIN valid_series AS series
      ON series.srvid = history.srvid
     AND series.dbid = history.dbid
     AND series.queryid = history.queryid
     AND series.userid = history.userid
    CROSS JOIN LATERAL unnest(history.records) AS sample_record
    WHERE history.toplevel
      AND (sample_record).ts >= params.start_at

    UNION ALL

    SELECT
        current_sample.srvid,
        current_sample.dbid,
        current_sample.queryid,
        current_sample.userid,
        current_sample.toplevel,
        (current_sample.record).ts,
        (current_sample.record).calls,
        (current_sample.record).total_exec_time
    FROM params
    JOIN "PoWA".powa_statements_history_current AS current_sample
      ON (current_sample.record).ts >= params.start_at
    JOIN valid_series AS series
      ON series.srvid = current_sample.srvid
     AND series.dbid = current_sample.dbid
     AND series.queryid = current_sample.queryid
     AND series.userid = current_sample.userid
    WHERE current_sample.toplevel
), predecessor_samples AS MATERIALIZED (
    -- One exact pre-window row per active series is sufficient for the first
    -- delta.  It replaces the old one-hour bulk look-behind and still exposes
    -- a long collector outage through the same 3 x frequency boundary check.
    SELECT
        series.server_id,
        series.database_id,
        series.query_id,
        series.user_id,
        series.toplevel,
        predecessor.sample_at,
        predecessor.calls,
        predecessor.total_exec_time_ms
    FROM active_series AS series
    CROSS JOIN params
    CROSS JOIN LATERAL (
        SELECT candidate.*
        FROM (
            (
                SELECT
                    (history_record).ts AS sample_at,
                    (history_record).calls AS calls,
                    (history_record).total_exec_time AS total_exec_time_ms
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
                          params.start_at,
                          '[)'
                      )
                    ORDER BY upper(history.coalesce_range) DESC
                    LIMIT 1
                ) AS latest_history
                CROSS JOIN LATERAL
                    unnest(latest_history.records) AS history_record
                WHERE (history_record).ts < params.start_at
                ORDER BY (history_record).ts DESC
                LIMIT 1
            )

            UNION ALL

            (
                SELECT
                    (current_sample.record).ts,
                    (current_sample.record).calls,
                    (current_sample.record).total_exec_time
                FROM "PoWA".powa_statements_history_current AS current_sample
                WHERE current_sample.srvid = series.server_id
                  AND current_sample.dbid = series.database_id
                  AND current_sample.queryid = series.query_id
                  AND current_sample.userid = series.user_id
                  AND current_sample.toplevel = series.toplevel
                  AND (current_sample.record).ts < params.start_at
                ORDER BY (current_sample.record).ts DESC
                LIMIT 1
            )
        ) AS candidate
        ORDER BY candidate.sample_at DESC
        LIMIT 1
    ) AS predecessor
), samples AS (
    SELECT * FROM active_samples
    UNION ALL
    SELECT * FROM predecessor_samples
), ordered AS (
    SELECT
        samples.*,
        lag(sample_at) OVER metric_window AS previous_sample_at,
        lag(calls) OVER metric_window AS previous_calls,
        lag(total_exec_time_ms) OVER metric_window
            AS previous_total_exec_time_ms,
        CASE
            WHEN source.frequency > 0 THEN source.frequency
            ELSE 300
        END AS frequency_seconds
    FROM samples
    JOIN "PoWA".powa_servers AS source
      ON source.id = samples.server_id
    WINDOW metric_window AS (
        PARTITION BY
            server_id, database_id, query_id, user_id, toplevel
        ORDER BY sample_at
    )
), deltas AS (
    SELECT
        ordered.sample_at,
        CASE
            WHEN ordered.calls >= ordered.previous_calls
                THEN ordered.calls - ordered.previous_calls
            ELSE COALESCE(ordered.calls, 0)
        END::bigint AS calls,
        CASE
            WHEN ordered.total_exec_time_ms
                    >= ordered.previous_total_exec_time_ms
                THEN ordered.total_exec_time_ms
                    - ordered.previous_total_exec_time_ms
            ELSE COALESCE(ordered.total_exec_time_ms, 0)
        END::double precision AS total_exec_time_ms
    FROM ordered
    CROSS JOIN params
    WHERE ordered.sample_at >= params.start_at
      AND ordered.previous_sample_at IS NOT NULL
      AND NOT (
          ordered.sample_at - ordered.previous_sample_at
              > make_interval(secs => ordered.frequency_seconds * 3)
          AND ordered.previous_sample_at < params.start_at
      )
)
SELECT
    date_bin(
        params.bucket,
        deltas.sample_at,
        timestamptz '2000-01-01'
    ) AS bucket_at,
    sum(deltas.total_exec_time_ms)::double precision
        AS total_exec_time_ms,
    sum(deltas.calls)::bigint AS calls
FROM deltas
CROSS JOIN params
GROUP BY 1
ORDER BY 1;
$$;


CREATE OR REPLACE FUNCTION advisor.query_trend(
    p_start timestamptz,
    p_bucket interval,
    p_server_id integer,
    p_database_id oid
)
RETURNS TABLE (
    bucket_at timestamptz,
    total_exec_time_ms double precision,
    calls bigint
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
SELECT *
FROM advisor._query_trend(
    p_start,
    p_bucket,
    p_server_id,
    p_database_id,
    NULL::bigint,
    true
);
$$;

REVOKE ALL ON FUNCTION advisor.query_trend(
    timestamptz, interval, integer, oid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.query_trend(
    timestamptz, interval, integer, oid
) TO advisor_api;

CREATE OR REPLACE FUNCTION advisor.release_info()
RETURNS TABLE (
    current_migration text,
    applied_count bigint,
    latest_applied_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor_migrations
AS $$
SELECT max(version)::text,
       count(*)::bigint,
       max(installed_at)
FROM advisor_migrations.schema_migrations;
$$;

REVOKE ALL ON FUNCTION advisor.release_info() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.release_info() TO advisor_api;

CREATE OR REPLACE FUNCTION advisor.table_write_metrics(
    p_window interval DEFAULT interval '24 hours',
    p_server_id integer DEFAULT NULL,
    p_database_id oid DEFAULT NULL,
    p_relation_ids oid[] DEFAULT NULL
)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    relation_id oid,
    inserted_rows bigint,
    updated_rows bigint,
    deleted_rows bigint,
    write_rows bigint,
    writes_per_hour double precision,
    reset_detected boolean,
    observed_from timestamptz,
    observed_to timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor
SET plan_cache_mode = force_custom_plan
AS $$
WITH samples AS (
    SELECT history.srvid AS server_id,
           history.dbid AS database_id,
           history.relid AS relation_id,
           (sample).ts AS sample_at,
           (sample).n_tup_ins AS inserted_rows,
           (sample).n_tup_upd AS updated_rows,
           (sample).n_tup_del AS deleted_rows
    FROM "PoWA".powa_all_tables_history AS history
    CROSS JOIN LATERAL unnest(history.records) AS sample
    WHERE history.coalesce_range && tstzrange(
              now() - p_window - interval '1 hour', now(), '[]'
          )
      AND (sample).ts >= now() - p_window - interval '1 hour'
      AND (p_server_id IS NULL OR history.srvid = p_server_id)
      AND (p_database_id IS NULL OR history.dbid = p_database_id)
      AND (p_relation_ids IS NULL OR history.relid = ANY(p_relation_ids))

    UNION ALL

    SELECT current_sample.srvid,
           current_sample.dbid,
           current_sample.relid,
           (current_sample.record).ts,
           (current_sample.record).n_tup_ins,
           (current_sample.record).n_tup_upd,
           (current_sample.record).n_tup_del
    FROM "PoWA".powa_all_tables_history_current AS current_sample
    WHERE (current_sample.record).ts >= now() - p_window - interval '1 hour'
      AND (p_server_id IS NULL OR current_sample.srvid = p_server_id)
      AND (p_database_id IS NULL OR current_sample.dbid = p_database_id)
      AND (p_relation_ids IS NULL OR current_sample.relid = ANY(p_relation_ids))
), ordered AS (
    SELECT samples.*,
           lag(sample_at) OVER metric_window AS previous_sample_at,
           lag(inserted_rows) OVER metric_window AS previous_inserted_rows,
           lag(updated_rows) OVER metric_window AS previous_updated_rows,
           lag(deleted_rows) OVER metric_window AS previous_deleted_rows
    FROM samples
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, relation_id
        ORDER BY sample_at
    )
), deltas AS (
    SELECT server_id,
           database_id,
           relation_id,
           previous_sample_at,
           sample_at,
           CASE WHEN inserted_rows >= previous_inserted_rows
                THEN inserted_rows - previous_inserted_rows
                ELSE COALESCE(inserted_rows, 0) END::bigint AS inserted_rows,
           CASE WHEN updated_rows >= previous_updated_rows
                THEN updated_rows - previous_updated_rows
                ELSE COALESCE(updated_rows, 0) END::bigint AS updated_rows,
           CASE WHEN deleted_rows >= previous_deleted_rows
                THEN deleted_rows - previous_deleted_rows
                ELSE COALESCE(deleted_rows, 0) END::bigint AS deleted_rows,
           inserted_rows < previous_inserted_rows
             OR updated_rows < previous_updated_rows
             OR deleted_rows < previous_deleted_rows AS reset_detected
    FROM ordered
    WHERE previous_inserted_rows IS NOT NULL
      AND sample_at >= now() - p_window
), aggregated AS (
    SELECT deltas.server_id,
           deltas.database_id,
           deltas.relation_id,
           sum(deltas.inserted_rows)::bigint AS inserted_rows,
           sum(deltas.updated_rows)::bigint AS updated_rows,
           sum(deltas.deleted_rows)::bigint AS deleted_rows,
           bool_or(deltas.reset_detected) AS reset_detected,
           min(deltas.previous_sample_at) AS observed_from,
           max(deltas.sample_at) AS observed_to
    FROM deltas
    GROUP BY deltas.server_id, deltas.database_id, deltas.relation_id
)
SELECT aggregated.server_id,
       aggregated.database_id,
       aggregated.relation_id,
       aggregated.inserted_rows,
       aggregated.updated_rows,
       aggregated.deleted_rows,
       (aggregated.inserted_rows + aggregated.updated_rows + aggregated.deleted_rows)::bigint,
       (aggregated.inserted_rows + aggregated.updated_rows + aggregated.deleted_rows)
         / NULLIF(extract(epoch FROM greatest(
               aggregated.observed_to - aggregated.observed_from,
               interval '1 second'
           )) / 3600.0, 0),
       aggregated.reset_detected,
       aggregated.observed_from,
       aggregated.observed_to
FROM aggregated;
$$;

REVOKE ALL ON FUNCTION advisor.table_write_metrics(
    interval, integer, oid, oid[]
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.table_write_metrics(
    interval, integer, oid, oid[]
) TO advisor_api;
