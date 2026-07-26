\set ON_ERROR_STOP on

-- PoWA's current history table is timestamp-interleaved across every tracked
-- query.  The previous rollup executed two index probes for every series,
-- which becomes prohibitively expensive once an ERP produces thousands of
-- query fingerprints.  Patch the checksum-frozen 0009 function forward: read
-- current samples once, rank the one pre-window predecessor per series, and
-- aggregate the same ordered record arrays set-wise.
--
-- The replacement is deliberately fail-closed.  A repository whose function
-- body does not contain the exact 0009 fragment must be reviewed instead of
-- receiving a best-effort rewrite.
DO $query_rollup_scale_guard$
DECLARE
    function_definition text;
    patched_definition text;
    fragment_count integer;
    old_fragment constant text := $old_fragment$
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
$old_fragment$;
    new_fragment constant text := $new_fragment$
), current_ranked AS (
    SELECT
        series.server_id,
        series.database_id,
        series.query_id,
        series.user_id,
        current_sample.record,
        (current_sample.record).ts AS sample_at,
        bound.lower_bound,
        row_number() OVER (
            PARTITION BY
                series.server_id,
                series.database_id,
                series.query_id,
                series.user_id,
                ((current_sample.record).ts < bound.lower_bound)
            ORDER BY (current_sample.record).ts DESC
        ) AS boundary_rank
    FROM "PoWA".powa_statements_history_current AS current_sample
    JOIN valid_series AS series
      ON series.server_id = current_sample.srvid
     AND series.database_id = current_sample.dbid
     AND series.query_id = current_sample.queryid
     AND series.user_id = current_sample.userid
    CROSS JOIN bounds AS bound
    WHERE current_sample.toplevel
      AND (current_sample.record).ts <= bound.observed_until
), current_chunks AS (
    SELECT
        candidate.server_id,
        candidate.database_id,
        candidate.query_id,
        candidate.user_id,
        array_agg(candidate.record ORDER BY candidate.sample_at)
            ::"PoWA".powa_statements_history_record[] AS records
    FROM current_ranked AS candidate
    WHERE candidate.sample_at >= candidate.lower_bound
       OR candidate.boundary_rank = 1
    GROUP BY
        candidate.server_id,
        candidate.database_id,
        candidate.query_id,
        candidate.user_id
), raw_chunks AS (
$new_fragment$;
    old_series_fragment constant text := $old_series_fragment$
    FROM "PoWA".powa_statements AS statement
    WHERE statement.query
$old_series_fragment$;
    new_series_fragment constant text := $new_series_fragment$
    FROM "PoWA".powa_statements AS statement
    CROSS JOIN bounds AS series_bound
    WHERE statement.last_present_ts >= series_bound.current_start
      AND statement.query
$new_series_fragment$;
BEGIN
    SELECT pg_get_functiondef(
        'advisor.query_rollups_for_metrics(interval)'::regprocedure
    )
    INTO STRICT function_definition;

    fragment_count := (
        length(function_definition)
        - length(replace(function_definition, old_fragment, ''))
    ) / length(old_fragment);

    IF fragment_count <> 1 THEN
        RAISE EXCEPTION
            'Expected exactly one checksum-frozen current_chunks fragment, found %',
            fragment_count;
    END IF;

    patched_definition := replace(
        function_definition,
        old_fragment,
        new_fragment
    );

    fragment_count := (
        length(patched_definition)
        - length(replace(patched_definition, old_series_fragment, ''))
    ) / length(old_series_fragment);
    IF fragment_count <> 1 THEN
        RAISE EXCEPTION
            'Expected exactly one checksum-frozen valid-series fragment, found %',
            fragment_count;
    END IF;
    patched_definition := replace(
        patched_definition,
        old_series_fragment,
        new_series_fragment
    );

    EXECUTE patched_definition;
END
$query_rollup_scale_guard$;

-- PostgreSQL severely underestimates the set-returning telemetry helpers at
-- ERP cardinalities and otherwise selects nested-loop joins that perform
-- millions of rejected comparisons.  This setting is scoped to the function
-- invocation and PostgreSQL restores the caller's setting afterwards.
ALTER FUNCTION advisor.query_metrics(interval) SET enable_nestloop = off;

COMMENT ON FUNCTION advisor.query_rollups_for_metrics(interval) IS
    'Reset/gap-aware PoWA query rollups with set-wise current-sample scanning.';
