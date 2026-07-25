\set ON_ERROR_STOP on

-- Forward-only correctness fix for the checksum-frozen 0007 migration.
--
-- A chunk-local lag is NULL for the first record of every chunk.  That does
-- not mean the series lacks a predecessor when the prior chunk supplies one.
-- Also retain the legacy temporal coverage cap for single- and multi-user
-- query series.
-- Replacing the function leaves its signature, ownership and grants intact.
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
        least(
            greatest(extract(epoch FROM p_window), 0),
            sum(boundary.internal_current_covered_seconds + CASE
                WHEN boundary.first_sample_at >= bound.current_start
                 AND boundary.previous_chunk_sample_at < bound.observed_until
                 AND boundary.boundary_predecessor_available
                 AND NOT boundary.boundary_gap_detected
                THEN greatest(extract(epoch FROM (
                    least(boundary.first_sample_at, bound.observed_until)
                    - greatest(
                        boundary.previous_chunk_sample_at,
                        bound.current_start
                    )
                )), 0)
                ELSE 0
            END)
        )::double precision AS current_covered_seconds,
        least(
            greatest(extract(epoch FROM p_window), 0),
            sum(boundary.internal_current_represented_seconds + CASE
                WHEN boundary.first_sample_at >= bound.current_start
                 AND boundary.previous_chunk_sample_at < bound.observed_until
                 AND boundary.boundary_predecessor_available
                THEN greatest(extract(epoch FROM (
                    least(boundary.first_sample_at, bound.observed_until)
                    - greatest(
                        boundary.previous_chunk_sample_at,
                        bound.current_start
                    )
                )), 0)
                ELSE 0
            END)
        )::double precision AS current_represented_seconds,
        least(
            greatest(extract(epoch FROM p_window), 0),
            sum(boundary.internal_previous_covered_seconds + CASE
                WHEN boundary.first_sample_at >= bound.previous_start
                 AND boundary.first_sample_at < bound.current_start
                 AND boundary.previous_chunk_sample_at < bound.current_start
                 AND boundary.boundary_predecessor_available
                 AND NOT boundary.boundary_gap_detected
                THEN greatest(extract(epoch FROM (
                    least(boundary.first_sample_at, bound.current_start)
                    - greatest(
                        boundary.previous_chunk_sample_at,
                        bound.previous_start
                    )
                )), 0)
                ELSE 0
            END)
        )::double precision AS previous_covered_seconds,
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
        -- PoWA normally writes strictly ordered, non-overlapping chunks.  If
        -- manually loaded or corrupt chunks overlap, their chunk-local counter
        -- sums cannot represent one global ordering.  Mark that unsupported
        -- shape as missing quality coverage so comparisons fail closed.
        bool_or(
            (
                boundary.internal_predecessor_missing
                AND NOT boundary.boundary_predecessor_available
            )
            OR (
                boundary.last_sample_at >= bound.previous_start
                AND boundary.boundary_predecessor_available
                AND boundary.first_sample_at
                    <= boundary.previous_chunk_sample_at
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
        least(
            greatest(extract(epoch FROM p_window), 0),
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
            END)
        )::double precision AS current_covered_seconds,
        least(
            greatest(extract(epoch FROM p_window), 0),
            sum(CASE
                WHEN sample.sample_at >= bound.current_start
                 AND sample.previous_sample_at < bound.observed_until
                 AND sample.predecessor_available
                THEN greatest(extract(epoch FROM (
                    least(sample.sample_at, bound.observed_until)
                    - greatest(sample.previous_sample_at, bound.current_start)
                )), 0)
                ELSE 0
            END)
        )::double precision AS current_represented_seconds,
        least(
            greatest(extract(epoch FROM p_window), 0),
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
            END)
        )::double precision AS previous_covered_seconds,
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
        (
            COALESCE(multi_user.predecessor_missing, false)
            OR bool_or(series.predecessor_missing)
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
