\set ON_ERROR_STOP on

-- Run after the repository schema migrations.  All fixtures live in one
-- transaction and are rolled back, so the test is safe against a developer or
-- CI repository database.
BEGIN;

INSERT INTO "PoWA".powa_servers (
    id, hostname, alias, port, username, dbname, frequency, powa_coalesce,
    retention, allow_ui_connection
)
VALUES (
    2147483000, 'reset-coverage-fixture.invalid', 'reset-coverage-fixture',
    5432, 'fixture', 'fixture', 10, 100, interval '7 days', false
);

INSERT INTO "PoWA".powa_databases(srvid, oid, datname)
VALUES (2147483000, 2147483000::oid, 'reset_coverage_fixture');

INSERT INTO "PoWA".powa_statements(srvid, queryid, dbid, userid, query)
VALUES
    (2147483000, 9001, 2147483000::oid, 10::oid, 'SELECT reset_inside_chunk'),
    (2147483000, 9002, 2147483000::oid, 10::oid, 'SELECT collector_gap'),
    (2147483000, 9003, 2147483000::oid, 10::oid, 'SELECT missing_previous_period'),
    (2147483000, 9004, 2147483000::oid, 10::oid, 'SELECT normal_coalesced_chunk');

-- The middle record resets to five.  The final value (120) is higher than the
-- first value (100), proving that endpoint-only delta logic would miss it.
WITH fixture AS (
    SELECT ARRAY[
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object(
                'ts', now() - interval '40 minutes', 'calls', 100,
                'total_exec_time', 1000, 'rows', 1000,
                'shared_blks_hit', 100, 'shared_blks_read', 50,
                'temp_blks_written', 20, 'wal_bytes', 10000
            )
        ),
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object(
                'ts', now() - interval '39 minutes 50 seconds', 'calls', 5,
                'total_exec_time', 50, 'rows', 50,
                'shared_blks_hit', 5, 'shared_blks_read', 2,
                'temp_blks_written', 1, 'wal_bytes', 500
            )
        ),
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object(
                'ts', now() - interval '39 minutes 40 seconds', 'calls', 120,
                'total_exec_time', 1200, 'rows', 1200,
                'shared_blks_hit', 120, 'shared_blks_read', 60,
                'temp_blks_written', 24, 'wal_bytes', 12000
            )
        )
    ]::"PoWA".powa_statements_history_record[] AS records
)
INSERT INTO "PoWA".powa_statements_history (
    srvid, queryid, dbid, toplevel, userid, coalesce_range,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000, 9001, 2147483000::oid, true, 10::oid,
    tstzrange(now() - interval '40 minutes', now() - interval '39 minutes 40 seconds', '[]'),
    records, records[1], records[3]
FROM fixture;

-- A healthy coalesced chunk must not be mistaken for a collector gap.
WITH fixture AS (
    SELECT ARRAY[
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object('ts', now() - interval '30 minutes', 'calls', 1,
                'total_exec_time', 10, 'rows', 1, 'shared_blks_hit', 1,
                'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)
        ),
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object('ts', now() - interval '29 minutes 50 seconds', 'calls', 2,
                'total_exec_time', 20, 'rows', 2, 'shared_blks_hit', 2,
                'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)
        ),
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object('ts', now() - interval '29 minutes 40 seconds', 'calls', 3,
                'total_exec_time', 30, 'rows', 3, 'shared_blks_hit', 3,
                'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)
        )
    ]::"PoWA".powa_statements_history_record[] AS records
)
INSERT INTO "PoWA".powa_statements_history (
    srvid, queryid, dbid, toplevel, userid, coalesce_range,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000, 9004, 2147483000::oid, true, 10::oid,
    tstzrange(now() - interval '30 minutes', now() - interval '29 minutes 40 seconds', '[]'),
    records, records[1], records[3]
FROM fixture;

WITH fixture AS (
    SELECT ARRAY[
        jsonb_populate_record(
            NULL::"PoWA".powa_kcache_history_record,
            jsonb_build_object('ts', now() - interval '40 minutes',
                'exec_reads', 1000, 'exec_writes', 500,
                'exec_user_time', 10, 'exec_system_time', 5)
        ),
        jsonb_populate_record(
            NULL::"PoWA".powa_kcache_history_record,
            jsonb_build_object('ts', now() - interval '39 minutes 50 seconds',
                'exec_reads', 10, 'exec_writes', 5,
                'exec_user_time', 0.5, 'exec_system_time', 0.25)
        ),
        jsonb_populate_record(
            NULL::"PoWA".powa_kcache_history_record,
            jsonb_build_object('ts', now() - interval '39 minutes 40 seconds',
                'exec_reads', 1200, 'exec_writes', 600,
                'exec_user_time', 12, 'exec_system_time', 6)
        )
    ]::"PoWA".powa_kcache_history_record[] AS records
)
INSERT INTO "PoWA".powa_kcache_metrics (
    srvid, coalesce_range, queryid, dbid, userid, metrics,
    mins_in_range, maxs_in_range, top
)
SELECT
    2147483000,
    tstzrange(now() - interval '40 minutes', now() - interval '39 minutes 40 seconds', '[]'),
    9001, 2147483000::oid, 10::oid, records, records[1], records[3], true
FROM fixture;

WITH fixture AS (
    SELECT ARRAY[
        ROW(now() - interval '40 minutes', 100)::"PoWA".powa_wait_sampling_history_record,
        ROW(now() - interval '39 minutes 50 seconds', 3)::"PoWA".powa_wait_sampling_history_record,
        ROW(now() - interval '39 minutes 40 seconds', 120)::"PoWA".powa_wait_sampling_history_record
    ] AS records
)
INSERT INTO "PoWA".powa_wait_sampling_history (
    srvid, coalesce_range, queryid, dbid, event_type, event,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000,
    tstzrange(now() - interval '40 minutes', now() - interval '39 minutes 40 seconds', '[]'),
    9001, 2147483000::oid, 'IO', 'DataFileRead', records, records[1], records[3]
FROM fixture;

-- The predecessor and resume samples intentionally share one coalesced row.
-- maxs_in_range is component-wise/synthetic, so the delta code must select a
-- real element from records rather than treating maxs_in_range as a snapshot.
WITH fixture AS (
    SELECT
        ARRAY[
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '3 hours 30 minutes', 'calls', 10,
                    'total_exec_time', 100, 'rows', 10, 'shared_blks_hit', 10,
                    'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '30 minutes', 'calls', 20,
                    'total_exec_time', 200, 'rows', 20, 'shared_blks_hit', 20,
                    'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '29 minutes 50 seconds', 'calls', 25,
                    'total_exec_time', 250, 'rows', 25, 'shared_blks_hit', 25,
                    'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)
            )
        ]::"PoWA".powa_statements_history_record[] AS records,
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object('ts', now() - interval '29 minutes 50 seconds', 'calls', 999,
                'total_exec_time', 9999, 'rows', 999, 'shared_blks_hit', 999,
                'shared_blks_read', 999, 'temp_blks_written', 999, 'wal_bytes', 9999)
        ) AS synthetic_max
)
INSERT INTO "PoWA".powa_statements_history (
    srvid, queryid, dbid, toplevel, userid, coalesce_range,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000, 9002, 2147483000::oid, true, 10::oid,
    tstzrange(now() - interval '3 hours 30 minutes', now() - interval '29 minutes 50 seconds', '[]'),
    records, records[1], synthetic_max
FROM fixture;

-- Auxiliary counters have the same boundary-crossing rule: the gap delta is
-- excluded from the selected hour, while the first healthy resume delta stays.
INSERT INTO "PoWA".powa_kcache_metrics_current (
    srvid, queryid, dbid, userid, metrics, top
)
VALUES
    (2147483000, 9002, 2147483000::oid, 10::oid,
     jsonb_populate_record(NULL::"PoWA".powa_kcache_history_record,
        jsonb_build_object('ts', now() - interval '1 hour 30 minutes',
            'exec_reads', 10, 'exec_writes', 10,
            'exec_user_time', 10, 'exec_system_time', 5)), true),
    (2147483000, 9002, 2147483000::oid, 10::oid,
     jsonb_populate_record(NULL::"PoWA".powa_kcache_history_record,
        jsonb_build_object('ts', now() - interval '30 minutes',
            'exec_reads', 20, 'exec_writes', 20,
            'exec_user_time', 20, 'exec_system_time', 10)), true),
    (2147483000, 9002, 2147483000::oid, 10::oid,
     jsonb_populate_record(NULL::"PoWA".powa_kcache_history_record,
        jsonb_build_object('ts', now() - interval '29 minutes 50 seconds',
            'exec_reads', 21, 'exec_writes', 21,
            'exec_user_time', 21, 'exec_system_time', 11)), true);

INSERT INTO "PoWA".powa_wait_sampling_history_current (
    srvid, queryid, dbid, event_type, event, record
)
VALUES
    (2147483000, 9002, 2147483000::oid, 'IO', 'DataFileRead',
     ROW(now() - interval '1 hour 30 minutes', 10)::"PoWA".powa_wait_sampling_history_record),
    (2147483000, 9002, 2147483000::oid, 'IO', 'DataFileRead',
     ROW(now() - interval '30 minutes', 20)::"PoWA".powa_wait_sampling_history_record),
    (2147483000, 9002, 2147483000::oid, 'IO', 'DataFileRead',
     ROW(now() - interval '29 minutes 50 seconds', 25)::"PoWA".powa_wait_sampling_history_record);

-- A current-only series exercises missing previous-period/warm-up state.
INSERT INTO "PoWA".powa_statements_history_current (
    srvid, queryid, dbid, toplevel, userid, record
)
VALUES
    (2147483000, 9003, 2147483000::oid, true, 10::oid,
     jsonb_populate_record(NULL::"PoWA".powa_statements_history_record,
        jsonb_build_object('ts', now() - interval '30 minutes', 'calls', 10,
            'total_exec_time', 100, 'rows', 10, 'shared_blks_hit', 10,
            'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0))),
    (2147483000, 9003, 2147483000::oid, true, 10::oid,
     jsonb_populate_record(NULL::"PoWA".powa_statements_history_record,
        jsonb_build_object('ts', now() - interval '29 minutes 50 seconds', 'calls', 20,
            'total_exec_time', 200, 'rows', 20, 'shared_blks_hit', 20,
            'shared_blks_read', 0, 'temp_blks_written', 0, 'wal_bytes', 0)));

DO $assert$
DECLARE
    query_reset record;
    kcache_reset record;
    wait_reset record;
    gap_row record;
    gap_quality record;
    missing_comparison record;
BEGIN
    IF NOT has_table_privilege('advisor_api', 'advisor.v_query_summary', 'SELECT')
       OR NOT has_table_privilege('advisor_api', 'advisor.v_query_regression', 'SELECT')
       OR NOT has_table_privilege('advisor_api', 'advisor.v_query_impact', 'SELECT') THEN
        RAISE EXCEPTION 'advisor_api query view SELECT grants are missing';
    END IF;

    SELECT calls, reset_detected, predecessor_available, gap_detected
      INTO STRICT query_reset
      FROM advisor.query_deltas(now() - interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9001
       AND reset_detected;

    IF query_reset.calls <> 5 OR NOT query_reset.predecessor_available
       OR query_reset.gap_detected THEN
        RAISE EXCEPTION 'query reset delta assertion failed: %', query_reset;
    END IF;

    SELECT exec_user_time_seconds, exec_system_time_seconds,
           filesystem_reads_bytes, filesystem_writes_bytes,
           reset_detected, gap_detected
      INTO STRICT kcache_reset
      FROM advisor.kcache_deltas(now() - interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9001
       AND reset_detected;

    IF kcache_reset.exec_user_time_seconds <> 0.5
       OR kcache_reset.exec_system_time_seconds <> 0.25
       OR kcache_reset.filesystem_reads_bytes <> 10
       OR kcache_reset.filesystem_writes_bytes <> 5
       OR kcache_reset.gap_detected THEN
        RAISE EXCEPTION 'kcache reset delta assertion failed: %', kcache_reset;
    END IF;

    SELECT samples, reset_detected, gap_detected
      INTO STRICT wait_reset
      FROM advisor.wait_deltas(now() - interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9001
       AND reset_detected;

    IF wait_reset.samples <> 3 OR wait_reset.gap_detected THEN
        RAISE EXCEPTION 'wait reset delta assertion failed: %', wait_reset;
    END IF;

    IF EXISTS (
        SELECT 1
          FROM advisor.query_deltas(now() - interval '1 hour')
         WHERE server_id = 2147483000 AND query_id = 9004 AND gap_detected
    ) THEN
        RAISE EXCEPTION 'healthy coalesced records produced a false gap';
    END IF;

    SELECT calls, reset_detected, gap_detected, predecessor_available
      INTO STRICT gap_row
      FROM advisor.query_deltas(now() - interval '4 hours')
     WHERE server_id = 2147483000 AND query_id = 9002
       AND sample_at = now() - interval '30 minutes';

    IF gap_row.calls <> 10
       OR gap_row.reset_detected
       OR NOT gap_row.gap_detected
       OR NOT gap_row.predecessor_available THEN
        RAISE EXCEPTION 'collector gap assertion failed: %', gap_row;
    END IF;

    SELECT calls, cpu_user_time_ms, cpu_system_time_ms, wait_total_samples,
           comparison_reliable, warming_up, coverage_percent,
           (score_details #>> '{callFrequency,volumeFactor}')::double precision
               AS call_frequency_volume_factor
      INTO STRICT gap_quality
      FROM advisor.query_metrics(interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9002;

    IF gap_quality.calls <> 5
       OR gap_quality.cpu_user_time_ms <> 1000
       OR gap_quality.cpu_system_time_ms <> 1000
       OR gap_quality.wait_total_samples <> 5
       OR gap_quality.comparison_reliable
       OR gap_quality.warming_up
       OR gap_quality.coverage_percent >= 100
       OR gap_quality.call_frequency_volume_factor >= 0.02 THEN
        RAISE EXCEPTION 'collector gap quality assertion failed: %', gap_quality;
    END IF;

    SELECT previous_period_available, previous_calls, comparison_reliable,
           warming_up, coverage_percent
      INTO STRICT missing_comparison
      FROM advisor.query_metrics(interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9003;

    IF missing_comparison.previous_period_available
       OR missing_comparison.previous_calls IS NOT NULL
       OR missing_comparison.comparison_reliable
       OR NOT missing_comparison.warming_up
       OR missing_comparison.coverage_percent >= 100 THEN
        RAISE EXCEPTION 'missing previous-period assertion failed: %', missing_comparison;
    END IF;
END
$assert$;

ROLLBACK;
