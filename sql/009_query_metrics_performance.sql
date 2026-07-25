\set ON_ERROR_STOP on

-- PostgreSQL-native query metric hot-path optimization.
-- The checksum-frozen baseline migrations remain untouched; this forward
-- migration keeps the public query_metrics signature and result semantics.

-- The public delta functions intentionally remain unchanged for compatibility.
-- query_metrics only needs CPU and wait telemetry for queries with activity in
-- the current period, so compact those active keys into JSON and push them into
-- these internal rollup functions before expanding PoWA's history arrays.
-- Each helper returns query/event aggregates rather than hundreds of thousands
-- of per-snapshot rows across an SQL-function materialization boundary.
CREATE OR REPLACE FUNCTION advisor.query_rollups_for_metrics(p_window interval)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    user_id oid,
    calls bigint,
    rows bigint,
    total_exec_time_ms double precision,
    shared_blocks_hit bigint,
    shared_blocks_read bigint,
    temp_blocks_written bigint,
    wal_bytes numeric,
    previous_calls_raw bigint,
    previous_total_exec_time_ms_raw double precision,
    observed_from timestamptz,
    observed_to timestamptz,
    current_covered_seconds double precision,
    current_represented_seconds double precision,
    previous_covered_seconds double precision,
    query_reset_detected boolean,
    query_gap_detected boolean,
    predecessor_missing boolean
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
        now() - (p_window * 2) - interval '1 hour' AS lower_bound
), valid_series AS MATERIALIZED (
    SELECT DISTINCT
        statement.srvid AS server_id,
        statement.dbid AS database_id,
        statement.queryid AS query_id,
        statement.userid AS user_id
    FROM "PoWA".powa_statements AS statement
    WHERE statement.query
        ~* '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)'
      AND NOT EXISTS (
          SELECT 1
          FROM "PoWA".powa_databases AS excluded_db
          WHERE excluded_db.srvid = statement.srvid
            AND excluded_db.oid = statement.dbid
            AND excluded_db.datname = 'powa'
      )
      AND NOT EXISTS (
          SELECT 1
          FROM "PoWA".powa_catalog_roles AS excluded_role
          WHERE excluded_role.srvid = statement.srvid
            AND excluded_role.oid = statement.userid
            AND excluded_role.rolname IN ('powa_collector', 'advisor_evaluator')
      )
), history_chunks AS (
    SELECT
        series.server_id,
        series.database_id,
        series.query_id,
        series.user_id,
        candidate.records
    FROM valid_series AS series
    CROSS JOIN bounds AS bound
    JOIN LATERAL (
        SELECT history.records
        FROM "PoWA".powa_statements_history AS history
        WHERE history.srvid = series.server_id
          AND history.dbid = series.database_id
          AND history.queryid = series.query_id
          AND history.userid = series.user_id
          AND history.toplevel
          AND history.coalesce_range
                && tstzrange(bound.lower_bound, bound.observed_until, '[]')
        UNION ALL
        (
            SELECT history.records
            FROM "PoWA".powa_statements_history AS history
            WHERE history.srvid = series.server_id
              AND history.dbid = series.database_id
              AND history.queryid = series.query_id
              AND history.userid = series.user_id
              AND history.toplevel
              AND upper(history.coalesce_range) < bound.lower_bound
            ORDER BY upper(history.coalesce_range) DESC
            LIMIT 1
        )
    ) AS candidate ON true
), current_chunks AS (
    SELECT
        series.server_id,
        series.database_id,
        series.query_id,
        series.user_id,
        array_agg(candidate.record ORDER BY (candidate.record).ts)
            ::"PoWA".powa_statements_history_record[] AS records
    FROM valid_series AS series
    CROSS JOIN bounds AS bound
    JOIN LATERAL (
        SELECT current_sample.record
        FROM "PoWA".powa_statements_history_current AS current_sample
        WHERE current_sample.srvid = series.server_id
          AND current_sample.dbid = series.database_id
          AND current_sample.queryid = series.query_id
          AND current_sample.userid = series.user_id
          AND current_sample.toplevel
          AND (current_sample.record).ts >= bound.lower_bound
          AND (current_sample.record).ts <= bound.observed_until
        UNION ALL
        (
            SELECT current_sample.record
            FROM "PoWA".powa_statements_history_current AS current_sample
            WHERE current_sample.srvid = series.server_id
              AND current_sample.dbid = series.database_id
              AND current_sample.queryid = series.query_id
              AND current_sample.userid = series.user_id
              AND current_sample.toplevel
              AND (current_sample.record).ts < bound.lower_bound
            ORDER BY (current_sample.record).ts DESC
            LIMIT 1
        )
    ) AS candidate ON true
    GROUP BY
        series.server_id,
        series.database_id,
        series.query_id,
        series.user_id
), raw_chunks AS (
    SELECT * FROM history_chunks
    UNION ALL
    SELECT * FROM current_chunks
), chunk_summaries AS (
    SELECT
        raw.server_id,
        raw.database_id,
        raw.query_id,
        raw.user_id,
        summary.*
    FROM raw_chunks AS raw
    JOIN "PoWA".powa_servers AS source ON source.id = raw.server_id
    CROSS JOIN bounds AS bound
    CROSS JOIN LATERAL (
        WITH points AS (
            SELECT
                (sample_record).ts AS sample_at,
                (sample_record).calls AS calls,
                (sample_record).total_exec_time AS total_exec_time_ms,
                (sample_record).shared_blks_hit AS shared_blocks_hit,
                (sample_record).shared_blks_read AS shared_blocks_read,
                (sample_record).temp_blks_written AS temp_blocks_written,
                (sample_record).wal_bytes AS wal_bytes,
                (sample_record).rows AS rows,
                lag((sample_record).ts) OVER sample_window AS previous_sample_at,
                lag((sample_record).calls) OVER sample_window AS previous_calls,
                lag((sample_record).total_exec_time) OVER sample_window
                    AS previous_total_exec_time_ms,
                lag((sample_record).shared_blks_hit) OVER sample_window
                    AS previous_shared_blocks_hit,
                lag((sample_record).shared_blks_read) OVER sample_window
                    AS previous_shared_blocks_read,
                lag((sample_record).temp_blks_written) OVER sample_window
                    AS previous_temp_blocks_written,
                lag((sample_record).wal_bytes) OVER sample_window
                    AS previous_wal_bytes,
                lag((sample_record).rows) OVER sample_window AS previous_rows
            FROM unnest(raw.records) AS sample_record
            WHERE (sample_record).ts <= bound.observed_until
            WINDOW sample_window AS (ORDER BY (sample_record).ts)
        ), deltas AS (
            SELECT
                points.*,
                CASE
                    WHEN previous_calls IS NULL THEN 0
                    WHEN calls >= previous_calls THEN calls - previous_calls
                    ELSE COALESCE(calls, 0)
                END::bigint AS calls_delta,
                CASE
                    WHEN previous_total_exec_time_ms IS NULL THEN 0
                    WHEN total_exec_time_ms >= previous_total_exec_time_ms
                        THEN total_exec_time_ms - previous_total_exec_time_ms
                    ELSE COALESCE(total_exec_time_ms, 0)
                END::double precision AS total_exec_time_delta,
                CASE
                    WHEN previous_shared_blocks_hit IS NULL THEN 0
                    WHEN shared_blocks_hit >= previous_shared_blocks_hit
                        THEN shared_blocks_hit - previous_shared_blocks_hit
                    ELSE COALESCE(shared_blocks_hit, 0)
                END::bigint AS shared_blocks_hit_delta,
                CASE
                    WHEN previous_shared_blocks_read IS NULL THEN 0
                    WHEN shared_blocks_read >= previous_shared_blocks_read
                        THEN shared_blocks_read - previous_shared_blocks_read
                    ELSE COALESCE(shared_blocks_read, 0)
                END::bigint AS shared_blocks_read_delta,
                CASE
                    WHEN previous_temp_blocks_written IS NULL THEN 0
                    WHEN temp_blocks_written >= previous_temp_blocks_written
                        THEN temp_blocks_written - previous_temp_blocks_written
                    ELSE COALESCE(temp_blocks_written, 0)
                END::bigint AS temp_blocks_written_delta,
                CASE
                    WHEN previous_wal_bytes IS NULL THEN 0
                    WHEN wal_bytes >= previous_wal_bytes
                        THEN wal_bytes - previous_wal_bytes
                    ELSE COALESCE(wal_bytes, 0)
                END::numeric AS wal_bytes_delta,
                CASE
                    WHEN previous_rows IS NULL THEN 0
                    WHEN rows >= previous_rows THEN rows - previous_rows
                    ELSE COALESCE(rows, 0)
                END::bigint AS rows_delta,
                previous_sample_at IS NOT NULL AND COALESCE(
                    calls < previous_calls
                    OR total_exec_time_ms < previous_total_exec_time_ms
                    OR shared_blocks_hit < previous_shared_blocks_hit
                    OR shared_blocks_read < previous_shared_blocks_read
                    OR temp_blocks_written < previous_temp_blocks_written
                    OR wal_bytes < previous_wal_bytes
                    OR rows < previous_rows,
                    false
                ) AS reset_detected,
                previous_sample_at IS NOT NULL
                    AND sample_at - previous_sample_at
                        > make_interval(
                            secs => CASE
                                WHEN source.frequency > 0 THEN source.frequency
                                ELSE 300
                            END * 3
                        ) AS gap_detected
            FROM points
        )
        SELECT
            min(sample_at) AS first_sample_at,
            max(sample_at) AS last_sample_at,
            (jsonb_agg(jsonb_build_object(
                'calls', calls,
                'total_exec_time_ms', total_exec_time_ms,
                'shared_blocks_hit', shared_blocks_hit,
                'shared_blocks_read', shared_blocks_read,
                'temp_blocks_written', temp_blocks_written,
                'wal_bytes', wal_bytes,
                'rows', rows
            ) ORDER BY sample_at))[0] AS first_state,
            (jsonb_agg(jsonb_build_object(
                'calls', calls,
                'total_exec_time_ms', total_exec_time_ms,
                'shared_blocks_hit', shared_blocks_hit,
                'shared_blocks_read', shared_blocks_read,
                'temp_blocks_written', temp_blocks_written,
                'wal_bytes', wal_bytes,
                'rows', rows
            ) ORDER BY sample_at DESC))[0] AS last_state,
            COALESCE(sum(calls_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::bigint AS current_calls,
            COALESCE(sum(rows_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::bigint AS current_rows,
            COALESCE(sum(total_exec_time_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::double precision AS current_total_exec_time_ms,
            COALESCE(sum(shared_blocks_hit_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::bigint AS current_shared_blocks_hit,
            COALESCE(sum(shared_blocks_read_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::bigint AS current_shared_blocks_read,
            COALESCE(sum(temp_blocks_written_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::bigint AS current_temp_blocks_written,
            COALESCE(sum(wal_bytes_delta) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.current_start)
            ), 0)::numeric AS current_wal_bytes,
            COALESCE(sum(calls_delta) FILTER (
                WHERE sample_at >= bound.previous_start
                  AND sample_at < bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.previous_start)
            ), 0)::bigint AS previous_calls,
            COALESCE(sum(total_exec_time_delta) FILTER (
                WHERE sample_at >= bound.previous_start
                  AND sample_at < bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT (gap_detected AND previous_sample_at < bound.previous_start)
            ), 0)::double precision AS previous_total_exec_time_ms,
            min(greatest(previous_sample_at, bound.current_start)) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT gap_detected
            ) AS internal_observed_from,
            max(least(sample_at, bound.observed_until)) FILTER (
                WHERE sample_at >= bound.current_start
            ) AS internal_observed_to,
            COALESCE(sum(greatest(extract(epoch FROM (
                least(sample_at, bound.observed_until)
                - greatest(previous_sample_at, bound.current_start)
            )), 0)) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at < bound.observed_until
                  AND previous_sample_at IS NOT NULL
                  AND NOT gap_detected
            ), 0)::double precision AS internal_current_covered_seconds,
            COALESCE(sum(greatest(extract(epoch FROM (
                least(sample_at, bound.observed_until)
                - greatest(previous_sample_at, bound.current_start)
            )), 0)) FILTER (
                WHERE sample_at >= bound.current_start
                  AND previous_sample_at < bound.observed_until
                  AND previous_sample_at IS NOT NULL
            ), 0)::double precision AS internal_current_represented_seconds,
            COALESCE(sum(greatest(extract(epoch FROM (
                least(sample_at, bound.current_start)
                - greatest(previous_sample_at, bound.previous_start)
            )), 0)) FILTER (
                WHERE sample_at >= bound.previous_start
                  AND sample_at < bound.current_start
                  AND previous_sample_at < bound.current_start
                  AND previous_sample_at IS NOT NULL
                  AND NOT gap_detected
            ), 0)::double precision AS internal_previous_covered_seconds,
            COALESCE(bool_or(reset_detected) FILTER (
                WHERE sample_at >= bound.previous_start
            ), false) AS internal_reset_detected,
            COALESCE(bool_or(gap_detected) FILTER (
                WHERE sample_at >= bound.previous_start
            ), false) AS internal_gap_detected,
            COALESCE(bool_or(previous_sample_at IS NULL) FILTER (
                WHERE sample_at >= bound.previous_start
            ), false) AS internal_predecessor_missing
        FROM deltas
    ) AS summary
    WHERE summary.first_sample_at IS NOT NULL
), ordered_chunks AS (
    SELECT
        chunk.*,
        lag(last_sample_at) OVER chunk_window AS previous_chunk_sample_at,
        lag(last_state) OVER chunk_window AS previous_chunk_state,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
            AS frequency_seconds
    FROM chunk_summaries AS chunk
    JOIN "PoWA".powa_servers AS source ON source.id = chunk.server_id
    WINDOW chunk_window AS (
        PARTITION BY server_id, database_id, query_id, user_id
        ORDER BY first_sample_at
    )
), chunk_boundaries AS (
    SELECT
        ordered.*,
        previous_chunk_sample_at IS NOT NULL AS boundary_predecessor_available,
        previous_chunk_sample_at IS NOT NULL
            AND first_sample_at - previous_chunk_sample_at
                > make_interval(secs => frequency_seconds * 3) AS boundary_gap_detected,
        previous_chunk_sample_at IS NOT NULL AND COALESCE(
            (first_state ->> 'calls')::bigint
                < (previous_chunk_state ->> 'calls')::bigint
            OR (first_state ->> 'total_exec_time_ms')::double precision
                < (previous_chunk_state ->> 'total_exec_time_ms')::double precision
            OR (first_state ->> 'shared_blocks_hit')::bigint
                < (previous_chunk_state ->> 'shared_blocks_hit')::bigint
            OR (first_state ->> 'shared_blocks_read')::bigint
                < (previous_chunk_state ->> 'shared_blocks_read')::bigint
            OR (first_state ->> 'temp_blocks_written')::bigint
                < (previous_chunk_state ->> 'temp_blocks_written')::bigint
            OR (first_state ->> 'wal_bytes')::numeric
                < (previous_chunk_state ->> 'wal_bytes')::numeric
            OR (first_state ->> 'rows')::bigint
                < (previous_chunk_state ->> 'rows')::bigint,
            false
        ) AS boundary_reset_detected
    FROM ordered_chunks AS ordered
), series_rollups AS (
    SELECT
        boundary.server_id,
        boundary.database_id,
        boundary.query_id,
        boundary.user_id,
        sum(boundary.current_calls + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'calls')::bigint
                        >= (boundary.previous_chunk_state ->> 'calls')::bigint
                    THEN (boundary.first_state ->> 'calls')::bigint
                        - (boundary.previous_chunk_state ->> 'calls')::bigint
                ELSE (boundary.first_state ->> 'calls')::bigint
            END
            ELSE 0
        END)::bigint AS calls,
        sum(boundary.current_rows + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'rows')::bigint
                        >= (boundary.previous_chunk_state ->> 'rows')::bigint
                    THEN (boundary.first_state ->> 'rows')::bigint
                        - (boundary.previous_chunk_state ->> 'rows')::bigint
                ELSE (boundary.first_state ->> 'rows')::bigint
            END
            ELSE 0
        END)::bigint AS rows,
        sum(boundary.current_total_exec_time_ms + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'total_exec_time_ms')::double precision
                        >= (boundary.previous_chunk_state ->> 'total_exec_time_ms')::double precision
                    THEN (boundary.first_state ->> 'total_exec_time_ms')::double precision
                        - (boundary.previous_chunk_state ->> 'total_exec_time_ms')::double precision
                ELSE (boundary.first_state ->> 'total_exec_time_ms')::double precision
            END
            ELSE 0
        END)::double precision AS total_exec_time_ms,
        sum(boundary.current_shared_blocks_hit + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'shared_blocks_hit')::bigint
                        >= (boundary.previous_chunk_state ->> 'shared_blocks_hit')::bigint
                    THEN (boundary.first_state ->> 'shared_blocks_hit')::bigint
                        - (boundary.previous_chunk_state ->> 'shared_blocks_hit')::bigint
                ELSE (boundary.first_state ->> 'shared_blocks_hit')::bigint
            END
            ELSE 0
        END)::bigint AS shared_blocks_hit,
        sum(boundary.current_shared_blocks_read + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'shared_blocks_read')::bigint
                        >= (boundary.previous_chunk_state ->> 'shared_blocks_read')::bigint
                    THEN (boundary.first_state ->> 'shared_blocks_read')::bigint
                        - (boundary.previous_chunk_state ->> 'shared_blocks_read')::bigint
                ELSE (boundary.first_state ->> 'shared_blocks_read')::bigint
            END
            ELSE 0
        END)::bigint AS shared_blocks_read,
        sum(boundary.current_temp_blocks_written + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'temp_blocks_written')::bigint
                        >= (boundary.previous_chunk_state ->> 'temp_blocks_written')::bigint
                    THEN (boundary.first_state ->> 'temp_blocks_written')::bigint
                        - (boundary.previous_chunk_state ->> 'temp_blocks_written')::bigint
                ELSE (boundary.first_state ->> 'temp_blocks_written')::bigint
            END
            ELSE 0
        END)::bigint AS temp_blocks_written,
        sum(boundary.current_wal_bytes + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.current_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'wal_bytes')::numeric
                        >= (boundary.previous_chunk_state ->> 'wal_bytes')::numeric
                    THEN (boundary.first_state ->> 'wal_bytes')::numeric
                        - (boundary.previous_chunk_state ->> 'wal_bytes')::numeric
                ELSE (boundary.first_state ->> 'wal_bytes')::numeric
            END
            ELSE 0
        END)::numeric AS wal_bytes,
        sum(boundary.previous_calls + CASE
            WHEN boundary.first_sample_at >= bound.previous_start
             AND boundary.first_sample_at < bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.previous_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'calls')::bigint
                        >= (boundary.previous_chunk_state ->> 'calls')::bigint
                    THEN (boundary.first_state ->> 'calls')::bigint
                        - (boundary.previous_chunk_state ->> 'calls')::bigint
                ELSE (boundary.first_state ->> 'calls')::bigint
            END
            ELSE 0
        END)::bigint AS previous_calls_raw,
        sum(boundary.previous_total_exec_time_ms + CASE
            WHEN boundary.first_sample_at >= bound.previous_start
             AND boundary.first_sample_at < bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT (
                 boundary.boundary_gap_detected
                 AND boundary.previous_chunk_sample_at < bound.previous_start
             )
            THEN CASE
                WHEN (boundary.first_state ->> 'total_exec_time_ms')::double precision
                        >= (boundary.previous_chunk_state ->> 'total_exec_time_ms')::double precision
                    THEN (boundary.first_state ->> 'total_exec_time_ms')::double precision
                        - (boundary.previous_chunk_state ->> 'total_exec_time_ms')::double precision
                ELSE (boundary.first_state ->> 'total_exec_time_ms')::double precision
            END
            ELSE 0
        END)::double precision AS previous_total_exec_time_ms_raw,
        least(
            min(boundary.internal_observed_from),
            min(greatest(boundary.previous_chunk_sample_at, bound.current_start)) FILTER (
                WHERE boundary.first_sample_at >= bound.current_start
                  AND boundary.boundary_predecessor_available
                  AND NOT boundary.boundary_gap_detected
            )
        ) AS observed_from,
        max(boundary.internal_observed_to) AS observed_to,
        sum(boundary.internal_current_covered_seconds + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.previous_chunk_sample_at < bound.observed_until
             AND boundary.boundary_predecessor_available
             AND NOT boundary.boundary_gap_detected
            THEN greatest(extract(epoch FROM (
                least(boundary.first_sample_at, bound.observed_until)
                - greatest(boundary.previous_chunk_sample_at, bound.current_start)
            )), 0)
            ELSE 0
        END)::double precision AS current_covered_seconds,
        sum(boundary.internal_current_represented_seconds + CASE
            WHEN boundary.first_sample_at >= bound.current_start
             AND boundary.previous_chunk_sample_at < bound.observed_until
             AND boundary.boundary_predecessor_available
            THEN greatest(extract(epoch FROM (
                least(boundary.first_sample_at, bound.observed_until)
                - greatest(boundary.previous_chunk_sample_at, bound.current_start)
            )), 0)
            ELSE 0
        END)::double precision AS current_represented_seconds,
        sum(boundary.internal_previous_covered_seconds + CASE
            WHEN boundary.first_sample_at >= bound.previous_start
             AND boundary.first_sample_at < bound.current_start
             AND boundary.previous_chunk_sample_at < bound.current_start
             AND boundary.boundary_predecessor_available
             AND NOT boundary.boundary_gap_detected
            THEN greatest(extract(epoch FROM (
                least(boundary.first_sample_at, bound.current_start)
                - greatest(boundary.previous_chunk_sample_at, bound.previous_start)
            )), 0)
            ELSE 0
        END)::double precision AS previous_covered_seconds,
        bool_or(
            boundary.internal_reset_detected
            OR (
                boundary.first_sample_at >= bound.previous_start
                AND boundary.boundary_reset_detected
            )
        ) AS query_reset_detected,
        bool_or(
            boundary.internal_gap_detected
            OR (
                boundary.first_sample_at >= bound.previous_start
                AND boundary.boundary_gap_detected
            )
        ) AS query_gap_detected,
        bool_or(
            boundary.internal_predecessor_missing
            OR (
                boundary.first_sample_at >= bound.previous_start
                AND NOT boundary.boundary_predecessor_available
            )
        ) AS predecessor_missing
    FROM chunk_boundaries AS boundary
    CROSS JOIN bounds AS bound
    GROUP BY
        boundary.server_id,
        boundary.database_id,
        boundary.query_id,
        boundary.user_id
), active_multi_user_queries AS MATERIALIZED (
    SELECT
        series.server_id,
        series.database_id,
        series.query_id
    FROM series_rollups AS series
    GROUP BY series.server_id, series.database_id, series.query_id
    HAVING count(DISTINCT series.user_id) > 1
       AND COALESCE(sum(series.calls), 0) > 0
), multi_user_samples AS (
    SELECT
        raw.server_id,
        raw.database_id,
        raw.query_id,
        raw.user_id,
        (sample_record).ts AS sample_at
    FROM raw_chunks AS raw
    JOIN active_multi_user_queries AS active
      ON active.server_id = raw.server_id
     AND active.database_id = raw.database_id
     AND active.query_id = raw.query_id
    CROSS JOIN LATERAL unnest(raw.records) AS sample_record
    CROSS JOIN bounds AS bound
    WHERE (sample_record).ts <= bound.observed_until
), multi_user_ordered AS (
    SELECT
        sample.*,
        lag(sample_at) OVER metric_window AS previous_sample_at,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
            AS frequency_seconds
    FROM multi_user_samples AS sample
    JOIN "PoWA".powa_servers AS source ON source.id = sample.server_id
    WINDOW metric_window AS (
        PARTITION BY
            sample.server_id,
            sample.database_id,
            sample.query_id,
            sample.user_id
        ORDER BY sample.sample_at
    )
), multi_user_temporal_samples AS (
    SELECT
        sample.server_id,
        sample.database_id,
        sample.query_id,
        sample.sample_at,
        max(sample.previous_sample_at) AS previous_sample_at,
        bool_and(sample.previous_sample_at IS NOT NULL)
            AS predecessor_available,
        bool_or(
            sample.previous_sample_at IS NOT NULL
            AND sample.sample_at - sample.previous_sample_at
                > make_interval(secs => sample.frequency_seconds * 3)
        ) AS gap_detected
    FROM multi_user_ordered AS sample
    GROUP BY
        sample.server_id,
        sample.database_id,
        sample.query_id,
        sample.sample_at
), multi_user_temporal_rollups AS (
    SELECT
        sample.server_id,
        sample.database_id,
        sample.query_id,
        min(greatest(sample.previous_sample_at, bound.current_start)) FILTER (
            WHERE sample.sample_at >= bound.current_start
              AND sample.predecessor_available
              AND NOT sample.gap_detected
        ) AS observed_from,
        max(least(sample.sample_at, bound.observed_until)) FILTER (
            WHERE sample.sample_at >= bound.current_start
        ) AS observed_to,
        sum(CASE
            WHEN sample.sample_at >= bound.current_start
             AND sample.previous_sample_at < bound.observed_until
             AND sample.predecessor_available
             AND NOT sample.gap_detected
            THEN greatest(extract(epoch FROM (
                least(sample.sample_at, bound.observed_until)
                - greatest(sample.previous_sample_at, bound.current_start)
            )), 0)
            ELSE 0
        END)::double precision AS current_covered_seconds,
        sum(CASE
            WHEN sample.sample_at >= bound.current_start
             AND sample.previous_sample_at < bound.observed_until
             AND sample.predecessor_available
            THEN greatest(extract(epoch FROM (
                least(sample.sample_at, bound.observed_until)
                - greatest(sample.previous_sample_at, bound.current_start)
            )), 0)
            ELSE 0
        END)::double precision AS current_represented_seconds,
        sum(CASE
            WHEN sample.sample_at >= bound.previous_start
             AND sample.sample_at < bound.current_start
             AND sample.previous_sample_at < bound.current_start
             AND sample.predecessor_available
             AND NOT sample.gap_detected
            THEN greatest(extract(epoch FROM (
                least(sample.sample_at, bound.current_start)
                - greatest(sample.previous_sample_at, bound.previous_start)
            )), 0)
            ELSE 0
        END)::double precision AS previous_covered_seconds,
        bool_or(sample.gap_detected) FILTER (
            WHERE sample.sample_at >= bound.previous_start
        ) AS query_gap_detected,
        bool_or(NOT sample.predecessor_available) FILTER (
            WHERE sample.sample_at >= bound.previous_start
        ) AS predecessor_missing
    FROM multi_user_temporal_samples AS sample
    CROSS JOIN bounds AS bound
    WHERE sample.sample_at >= bound.previous_start
    GROUP BY sample.server_id, sample.database_id, sample.query_id
), query_rollups AS (
    SELECT
        series.server_id,
        series.database_id,
        series.query_id,
        CASE WHEN count(DISTINCT series.user_id) = 1
            THEN min(series.user_id::bigint)::oid
            ELSE NULL::oid
        END AS user_id,
        sum(series.calls)::bigint AS calls,
        sum(series.rows)::bigint AS rows,
        sum(series.total_exec_time_ms)::double precision AS total_exec_time_ms,
        sum(series.shared_blocks_hit)::bigint AS shared_blocks_hit,
        sum(series.shared_blocks_read)::bigint AS shared_blocks_read,
        sum(series.temp_blocks_written)::bigint AS temp_blocks_written,
        sum(series.wal_bytes)::numeric AS wal_bytes,
        sum(series.previous_calls_raw)::bigint AS previous_calls_raw,
        sum(series.previous_total_exec_time_ms_raw)::double precision
            AS previous_total_exec_time_ms_raw,
        COALESCE(
            multi_user.observed_from,
            min(series.observed_from)
        ) AS observed_from,
        COALESCE(
            multi_user.observed_to,
            max(series.observed_to)
        ) AS observed_to,
        COALESCE(
            multi_user.current_covered_seconds,
            max(series.current_covered_seconds)
        )::double precision AS current_covered_seconds,
        COALESCE(
            multi_user.current_represented_seconds,
            max(series.current_represented_seconds)
        )::double precision AS current_represented_seconds,
        COALESCE(
            multi_user.previous_covered_seconds,
            max(series.previous_covered_seconds)
        )::double precision AS previous_covered_seconds,
        bool_or(series.query_reset_detected) AS query_reset_detected,
        COALESCE(
            multi_user.query_gap_detected,
            bool_or(series.query_gap_detected)
        ) AS query_gap_detected,
        COALESCE(
            multi_user.predecessor_missing,
            bool_or(series.predecessor_missing)
        ) AS predecessor_missing
    FROM series_rollups AS series
    LEFT JOIN multi_user_temporal_rollups AS multi_user
      ON multi_user.server_id = series.server_id
     AND multi_user.database_id = series.database_id
     AND multi_user.query_id = series.query_id
    GROUP BY series.server_id, series.database_id, series.query_id
        , multi_user.observed_from
        , multi_user.observed_to
        , multi_user.current_covered_seconds
        , multi_user.current_represented_seconds
        , multi_user.previous_covered_seconds
        , multi_user.query_gap_detected
        , multi_user.predecessor_missing
)
SELECT *
FROM query_rollups
WHERE COALESCE(calls, 0) > 0;
$$;

CREATE OR REPLACE FUNCTION advisor.kcache_rollups_for_queries(
    p_start timestamptz,
    p_keys jsonb
)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    cpu_user_time_ms double precision,
    cpu_system_time_ms double precision,
    filesystem_reads_bytes bigint,
    filesystem_writes_bytes bigint,
    data_available boolean,
    reset_detected boolean,
    reliability_issue boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH active_keys AS MATERIALIZED (
    SELECT DISTINCT
        key.server_id,
        key.database_id,
        key.query_id
    FROM jsonb_to_recordset(COALESCE(p_keys, '[]'::jsonb)) AS key(
        server_id integer,
        database_id oid,
        query_id bigint
    )
), samples AS (
    SELECT
        history.srvid AS server_id,
        history.dbid AS database_id,
        history.queryid AS query_id,
        history.userid AS user_id,
        history.top AS toplevel,
        (sample_record).ts AS sample_at,
        (sample_record).exec_user_time AS exec_user_time_seconds,
        (sample_record).exec_system_time AS exec_system_time_seconds,
        (sample_record).exec_reads AS filesystem_reads_bytes,
        (sample_record).exec_writes AS filesystem_writes_bytes
    FROM active_keys AS active
    JOIN "PoWA".powa_kcache_metrics AS history
      ON history.srvid = active.server_id
     AND history.dbid = active.database_id
     AND history.queryid = active.query_id
     AND history.coalesce_range
            && tstzrange(p_start - interval '1 hour', now(), '[]')
    CROSS JOIN LATERAL unnest(history.metrics) AS sample_record
    WHERE (sample_record).ts >= p_start - interval '1 hour'
      AND (sample_record).ts <= now()
    UNION ALL
    SELECT
        current_sample.srvid AS server_id,
        current_sample.dbid AS database_id,
        current_sample.queryid AS query_id,
        current_sample.userid,
        current_sample.top,
        (current_sample.metrics).ts,
        (current_sample.metrics).exec_user_time,
        (current_sample.metrics).exec_system_time,
        (current_sample.metrics).exec_reads,
        (current_sample.metrics).exec_writes
    FROM active_keys AS active
    JOIN "PoWA".powa_kcache_metrics_current AS current_sample
      ON current_sample.srvid = active.server_id
     AND current_sample.dbid = active.database_id
     AND current_sample.queryid = active.query_id
    WHERE (current_sample.metrics).ts >= p_start - interval '1 hour'
      AND (current_sample.metrics).ts <= now()
), ordered AS (
    SELECT
        samples.*,
        lag(sample_at) OVER metric_window AS previous_sample_at,
        lag(exec_user_time_seconds) OVER metric_window AS previous_user_time,
        lag(exec_system_time_seconds) OVER metric_window AS previous_system_time,
        lag(filesystem_reads_bytes) OVER metric_window AS previous_reads,
        lag(filesystem_writes_bytes) OVER metric_window AS previous_writes,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
            AS frequency_seconds
    FROM samples
    JOIN "PoWA".powa_servers AS source ON source.id = samples.server_id
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, query_id, user_id, toplevel
        ORDER BY sample_at
    )
), deltas AS (
    SELECT
        ordered.*,
        CASE
            WHEN previous_user_time IS NULL THEN 0
            WHEN exec_user_time_seconds >= previous_user_time
                THEN exec_user_time_seconds - previous_user_time
            ELSE COALESCE(exec_user_time_seconds, 0)
        END AS exec_user_time_delta,
        CASE
            WHEN previous_system_time IS NULL THEN 0
            WHEN exec_system_time_seconds >= previous_system_time
                THEN exec_system_time_seconds - previous_system_time
            ELSE COALESCE(exec_system_time_seconds, 0)
        END AS exec_system_time_delta,
        CASE
            WHEN filesystem_reads_bytes IS NULL THEN NULL
            WHEN previous_reads IS NULL THEN 0
            WHEN filesystem_reads_bytes >= previous_reads
                THEN filesystem_reads_bytes - previous_reads
            ELSE filesystem_reads_bytes
        END::bigint AS filesystem_reads_delta,
        CASE
            WHEN filesystem_writes_bytes IS NULL THEN NULL
            WHEN previous_writes IS NULL THEN 0
            WHEN filesystem_writes_bytes >= previous_writes
                THEN filesystem_writes_bytes - previous_writes
            ELSE filesystem_writes_bytes
        END::bigint AS filesystem_writes_delta,
        previous_sample_at IS NOT NULL AS predecessor_available,
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
        previous_sample_at IS NOT NULL
            AND sample_at - previous_sample_at
                > make_interval(secs => frequency_seconds * 3) AS gap_detected
    FROM ordered
)
SELECT
    delta.server_id,
    delta.database_id,
    delta.query_id,
    sum(delta.exec_user_time_delta) FILTER (
        WHERE delta.predecessor_available
          AND NOT (
              delta.gap_detected
              AND delta.previous_sample_at < p_start
          )
    ) * 1000.0 AS cpu_user_time_ms,
    sum(delta.exec_system_time_delta) FILTER (
        WHERE delta.predecessor_available
          AND NOT (
              delta.gap_detected
              AND delta.previous_sample_at < p_start
          )
    ) * 1000.0 AS cpu_system_time_ms,
    sum(delta.filesystem_reads_delta) FILTER (
        WHERE delta.predecessor_available
          AND NOT (
              delta.gap_detected
              AND delta.previous_sample_at < p_start
          )
    )::bigint AS filesystem_reads_bytes,
    sum(delta.filesystem_writes_delta) FILTER (
        WHERE delta.predecessor_available
          AND NOT (
              delta.gap_detected
              AND delta.previous_sample_at < p_start
          )
    )::bigint AS filesystem_writes_bytes,
    bool_or(
        delta.predecessor_available
        AND NOT (
            delta.gap_detected
            AND delta.previous_sample_at < p_start
        )
    ) AS data_available,
    bool_or(delta.reset_detected) AS reset_detected,
    bool_or(delta.gap_detected) AS reliability_issue
FROM deltas AS delta
WHERE delta.sample_at >= p_start
  AND delta.toplevel
GROUP BY delta.server_id, delta.database_id, delta.query_id;
$$;

CREATE OR REPLACE FUNCTION advisor.wait_rollups_for_queries(
    p_start timestamptz,
    p_keys jsonb
)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    event_type text,
    event text,
    samples bigint,
    reset_detected boolean,
    reliability_issue boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, advisor
AS $$
WITH active_keys AS MATERIALIZED (
    SELECT DISTINCT
        key.server_id,
        key.database_id,
        key.query_id
    FROM jsonb_to_recordset(COALESCE(p_keys, '[]'::jsonb)) AS key(
        server_id integer,
        database_id oid,
        query_id bigint
    )
), history_chunks AS (
    SELECT
        history.srvid AS server_id,
        history.dbid AS database_id,
        history.queryid AS query_id,
        history.event_type,
        history.event,
        chunk.first_sample_at,
        chunk.first_count,
        chunk.last_sample_at,
        chunk.last_count,
        chunk.internal_samples,
        chunk.internal_reset_detected,
        chunk.internal_gap_detected
    FROM active_keys AS active
    JOIN "PoWA".powa_wait_sampling_history AS history
      ON history.srvid = active.server_id
     AND history.dbid = active.database_id
     AND history.queryid = active.query_id
     AND history.coalesce_range
            && tstzrange(p_start - interval '1 hour', now(), '[]')
    JOIN "PoWA".powa_servers AS source ON source.id = history.srvid
    CROSS JOIN LATERAL (
        -- PoWA does not promise physical array ordinality to be chronological.
        -- Summarize each coalesced chunk by record timestamp, then only carry
        -- its boundary values into the global window below.
        SELECT
            (array_agg(point.sample_at ORDER BY point.sample_at))[1]
                AS first_sample_at,
            (array_agg(point.sample_count ORDER BY point.sample_at))[1]
                AS first_count,
            (array_agg(point.sample_at ORDER BY point.sample_at DESC))[1]
                AS last_sample_at,
            (array_agg(point.sample_count ORDER BY point.sample_at DESC))[1]
                AS last_count,
            COALESCE(sum(
                CASE
                    WHEN point.sample_at >= p_start
                     AND point.previous_count IS NOT NULL
                     AND NOT (
                         point.sample_at - point.previous_sample_at
                            > make_interval(
                                secs => CASE
                                    WHEN source.frequency > 0
                                        THEN source.frequency
                                    ELSE 300
                                END * 3
                            )
                         AND point.previous_sample_at < p_start
                     )
                    THEN CASE
                        WHEN point.sample_count >= point.previous_count
                            THEN point.sample_count - point.previous_count
                        ELSE point.sample_count
                    END
                    ELSE 0
                END
            ), 0)::bigint AS internal_samples,
            COALESCE(bool_or(
                point.sample_at >= p_start
                AND point.previous_count IS NOT NULL
                AND point.sample_count < point.previous_count
            ), false) AS internal_reset_detected,
            COALESCE(bool_or(
                point.sample_at >= p_start
                AND point.previous_sample_at IS NOT NULL
                AND point.sample_at - point.previous_sample_at
                    > make_interval(
                        secs => CASE
                            WHEN source.frequency > 0 THEN source.frequency
                            ELSE 300
                        END * 3
                    )
            ), false) AS internal_gap_detected
        FROM (
            SELECT
                record_value.ts AS sample_at,
                record_value.count::numeric AS sample_count,
                lag(record_value.ts) OVER (
                    ORDER BY record_value.ts
                ) AS previous_sample_at,
                lag(record_value.count::numeric) OVER (
                    ORDER BY record_value.ts
                ) AS previous_count
            FROM unnest(history.records) WITH ORDINALITY
                AS record_value(ts, count, ordinality)
            WHERE record_value.ts >= p_start - interval '1 hour'
              AND record_value.ts <= now()
        ) AS point
    ) AS chunk
    WHERE history.queryid <> 0
      AND history.event_type IS NOT NULL
      AND history.event IS NOT NULL
      AND chunk.first_sample_at IS NOT NULL
), current_points AS (
    SELECT
        current_sample.srvid AS server_id,
        current_sample.dbid AS database_id,
        current_sample.queryid AS query_id,
        current_sample.event_type,
        current_sample.event,
        (current_sample.record).ts AS sample_at,
        (current_sample.record).count::numeric AS sample_count,
        lag((current_sample.record).ts) OVER metric_window
            AS previous_sample_at,
        lag((current_sample.record).count::numeric) OVER metric_window
            AS previous_count,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
            AS frequency_seconds
    FROM active_keys AS active
    JOIN "PoWA".powa_wait_sampling_history_current AS current_sample
      ON current_sample.srvid = active.server_id
     AND current_sample.dbid = active.database_id
     AND current_sample.queryid = active.query_id
    JOIN "PoWA".powa_servers AS source ON source.id = current_sample.srvid
    WHERE current_sample.queryid <> 0
      AND current_sample.event_type IS NOT NULL
      AND current_sample.event IS NOT NULL
      AND (current_sample.record).ts >= p_start - interval '1 hour'
      AND (current_sample.record).ts <= now()
    WINDOW metric_window AS (
        PARTITION BY
            current_sample.srvid,
            current_sample.dbid,
            current_sample.queryid,
            current_sample.event_type,
            current_sample.event
        ORDER BY (current_sample.record).ts
    )
), current_chunks AS (
    SELECT
        server_id,
        database_id,
        query_id,
        event_type,
        event,
        (array_agg(sample_at ORDER BY sample_at))[1] AS first_sample_at,
        (array_agg(sample_count ORDER BY sample_at))[1] AS first_count,
        (array_agg(sample_at ORDER BY sample_at DESC))[1] AS last_sample_at,
        (array_agg(sample_count ORDER BY sample_at DESC))[1] AS last_count,
        COALESCE(sum(
            CASE
                WHEN sample_at >= p_start
                 AND previous_count IS NOT NULL
                 AND NOT (
                     sample_at - previous_sample_at
                        > make_interval(secs => frequency_seconds * 3)
                     AND previous_sample_at < p_start
                 )
                THEN CASE
                    WHEN sample_count >= previous_count
                        THEN sample_count - previous_count
                    ELSE sample_count
                END
                ELSE 0
            END
        ), 0)::bigint AS internal_samples,
        COALESCE(bool_or(
            sample_at >= p_start
            AND previous_count IS NOT NULL
            AND sample_count < previous_count
        ), false) AS internal_reset_detected,
        COALESCE(bool_or(
            sample_at >= p_start
            AND previous_sample_at IS NOT NULL
            AND sample_at - previous_sample_at
                > make_interval(secs => frequency_seconds * 3)
        ), false) AS internal_gap_detected
    FROM current_points
    GROUP BY server_id, database_id, query_id, event_type, event
), chunks AS (
    SELECT * FROM history_chunks
    UNION ALL
    SELECT * FROM current_chunks
), ordered_chunks AS (
    SELECT
        chunks.*,
        lag(last_sample_at) OVER metric_window AS previous_chunk_sample_at,
        lag(last_count) OVER metric_window AS previous_chunk_count,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
            AS frequency_seconds
    FROM chunks
    JOIN "PoWA".powa_servers AS source ON source.id = chunks.server_id
    WINDOW metric_window AS (
        PARTITION BY server_id, database_id, query_id, event_type, event
        ORDER BY first_sample_at
    )
), event_rollups AS (
    SELECT
        server_id,
        database_id,
        query_id,
        event_type,
        event,
        sum(
            internal_samples
            + CASE
                WHEN first_sample_at >= p_start
                 AND previous_chunk_count IS NOT NULL
                 AND NOT (
                     first_sample_at - previous_chunk_sample_at
                        > make_interval(secs => frequency_seconds * 3)
                     AND previous_chunk_sample_at < p_start
                 )
                THEN CASE
                    WHEN first_count >= previous_chunk_count
                        THEN first_count - previous_chunk_count
                    ELSE first_count
                END
                ELSE 0
              END
        )::bigint AS samples,
        bool_or(
            internal_reset_detected
            OR (
                first_sample_at >= p_start
                AND previous_chunk_count IS NOT NULL
                AND first_count < previous_chunk_count
            )
        ) AS reset_detected,
        bool_or(
            internal_gap_detected
            OR (
                first_sample_at >= p_start
                AND previous_chunk_sample_at IS NOT NULL
                AND first_sample_at - previous_chunk_sample_at
                    > make_interval(secs => frequency_seconds * 3)
            )
        ) AS reliability_issue
    FROM ordered_chunks
    GROUP BY server_id, database_id, query_id, event_type, event
)
SELECT *
FROM event_rollups
WHERE query_id <> 0
  AND event_type IS NOT NULL
  AND event IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION advisor.query_rollups_for_metrics(interval)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor.kcache_rollups_for_queries(timestamptz, jsonb)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor.wait_rollups_for_queries(timestamptz, jsonb)
    FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advisor.query_rollups_for_metrics(interval)
    TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.kcache_rollups_for_queries(timestamptz, jsonb)
    TO advisor_api;
GRANT EXECUTE ON FUNCTION advisor.wait_rollups_for_queries(timestamptz, jsonb)
    TO advisor_api;

CREATE OR REPLACE FUNCTION advisor.query_metrics(p_window interval DEFAULT interval '24 hours')
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
), metric_rollups AS MATERIALIZED (
    SELECT *
    FROM advisor.query_rollups_for_metrics(p_window)
), optimized_period AS (
    SELECT
        rollup.server_id,
        rollup.database_id,
        rollup.query_id,
        rollup.user_id,
        rollup.calls,
        rollup.rows,
        rollup.total_exec_time_ms,
        rollup.shared_blocks_hit,
        rollup.shared_blocks_read,
        rollup.temp_blocks_written,
        rollup.wal_bytes,
        rollup.previous_calls_raw,
        rollup.previous_total_exec_time_ms_raw
    FROM metric_rollups AS rollup
), optimized_query_quality AS (
    SELECT
        rollup.server_id,
        rollup.database_id,
        rollup.query_id,
        rollup.observed_from,
        rollup.observed_to,
        rollup.current_covered_seconds,
        rollup.current_represented_seconds,
        rollup.previous_covered_seconds,
        rollup.query_reset_detected,
        rollup.query_gap_detected,
        rollup.predecessor_missing,
        100.0 * rollup.current_covered_seconds
            / NULLIF(bound.window_seconds, 0) AS coverage_percent,
        rollup.previous_covered_seconds > 0 AS previous_period_available,
        greatest(
            rollup.current_represented_seconds,
            CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
                ::double precision
        ) / 3600.0 AS observation_hours,
        CASE WHEN source.frequency > 0 THEN source.frequency ELSE 300 END
            ::double precision AS frequency_seconds,
        (
            rollup.current_covered_seconds >= greatest(
                bound.window_seconds
                    - 6.0 * CASE
                        WHEN source.frequency > 0 THEN source.frequency
                        ELSE 300
                    END,
                0
            )
            AND rollup.previous_covered_seconds >= greatest(
                bound.window_seconds
                    - 6.0 * CASE
                        WHEN source.frequency > 0 THEN source.frequency
                        ELSE 300
                    END,
                0
            )
        ) AS coverage_sufficient,
        (
            (
                NOT (rollup.previous_covered_seconds > 0)
                OR COALESCE(rollup.predecessor_missing, false)
            )
            AND NOT COALESCE(rollup.query_gap_detected, false)
        ) AS warming_up
    FROM metric_rollups AS rollup
    JOIN "PoWA".powa_servers AS source ON source.id = rollup.server_id
    CROSS JOIN bounds AS bound
), optimized_active_query_keys AS MATERIALIZED (
    SELECT server_id, database_id, query_id
    FROM optimized_period
), optimized_active_query_key_set AS MATERIALIZED (
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'server_id', active.server_id,
                'database_id', active.database_id,
                'query_id', active.query_id
            )
            ORDER BY active.server_id, active.database_id, active.query_id
        ),
        '[]'::jsonb
    ) AS keys
    FROM optimized_active_query_keys AS active
), kcache_period AS MATERIALIZED (
    SELECT rollup.*
    FROM optimized_active_query_key_set AS active
    CROSS JOIN LATERAL advisor.kcache_rollups_for_queries(
        now() - p_window,
        active.keys
    ) AS rollup
), kcache_capability AS (
    SELECT
        config.srvid AS server_id,
        bool_or(config.enabled) AS available,
        max(config.version)::text AS version
    FROM "PoWA".powa_extension_config AS config
    WHERE config.extname = 'pg_stat_kcache'
    GROUP BY config.srvid
), wait_event_rollups AS MATERIALIZED (
    SELECT rollup.*
    FROM optimized_active_query_key_set AS active
    CROSS JOIN LATERAL advisor.wait_rollups_for_queries(
        now() - p_window,
        active.keys
    ) AS rollup
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
        w.samples
    FROM wait_event_rollups AS w
    WHERE w.samples > 0
), wait_quality AS (
    SELECT
        w.server_id,
        w.database_id,
        w.query_id,
        bool_or(w.reset_detected) AS reset_detected,
        bool_or(w.reliability_issue) AS reliability_issue
    FROM wait_event_rollups AS w
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
    FROM optimized_period AS p
    JOIN optimized_query_quality AS quality
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
