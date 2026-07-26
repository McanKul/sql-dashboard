\set ON_ERROR_STOP on

-- Run after the repository schema migrations.  All fixtures live in one
-- transaction and are rolled back, so the test is safe against a developer or
-- CI repository database.
BEGIN;

INSERT INTO "PoWA".powa_servers (
    id, hostname, alias, port, username, dbname, frequency, powa_coalesce,
    retention, allow_ui_connection
)
VALUES
    (
        2147483000, 'reset-coverage-fixture.invalid',
        'reset-coverage-fixture', 5432, 'fixture', 'fixture',
        10, 100, interval '7 days', false
    ),
    (
        2147483001, 'overlap-fixture.invalid', 'overlap-fixture',
        5432, 'fixture', 'fixture', 600, 100, interval '7 days', false
    );

INSERT INTO "PoWA".powa_databases(srvid, oid, datname)
VALUES
    (2147483000, 2147483000::oid, 'reset_coverage_fixture'),
    (2147483001, 2147483001::oid, 'overlap_fixture');

INSERT INTO "PoWA".powa_statements(srvid, queryid, dbid, userid, query)
VALUES
    (2147483000, 9001, 2147483000::oid, 10::oid, 'SELECT reset_inside_chunk'),
    (2147483000, 9002, 2147483000::oid, 10::oid, 'SELECT collector_gap'),
    (2147483000, 9003, 2147483000::oid, 10::oid, 'SELECT missing_previous_period'),
    (2147483000, 9004, 2147483000::oid, 10::oid, 'SELECT normal_coalesced_chunk'),
    (2147483000, 9005, 2147483000::oid, 10::oid, 'SELECT healthy_chunk_boundaries'),
    (2147483000, 9006, 2147483000::oid, 10::oid, 'SELECT multi_user_coverage_cap'),
    (2147483000, 9006, 2147483000::oid, 11::oid, 'SELECT multi_user_coverage_cap'),
    (2147483001, 9007, 2147483001::oid, 10::oid, 'SELECT overlapping_chunks');

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

-- A continuously sampled series is split across three physical PoWA chunks.
-- Every first record has a NULL chunk-local lag, but chunks two and three have
-- valid boundary predecessors and must not make the query look like warm-up.
WITH chunk_bounds(chunk_number, first_index, last_index) AS (
    VALUES
        (1, 0, 240),
        (2, 241, 480),
        (3, 481, 720)
), samples AS (
    SELECT
        chunk.chunk_number,
        sample_index,
        now() - interval '2 hours 10 seconds'
            + make_interval(secs => sample_index * 10) AS sample_at,
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object(
                'ts', now() - interval '2 hours 10 seconds'
                    + make_interval(secs => sample_index * 10),
                'calls', 1000 + sample_index,
                'total_exec_time', 10000 + sample_index * 10,
                'rows', 2000 + sample_index,
                'shared_blks_hit', 3000 + sample_index,
                'shared_blks_read', 400 + sample_index,
                'temp_blks_written', 50 + sample_index,
                'wal_bytes', 50000 + sample_index * 100
            )
        ) AS sample_record
    FROM chunk_bounds AS chunk
    CROSS JOIN LATERAL generate_series(
        chunk.first_index,
        chunk.last_index
    ) AS generated(sample_index)
), chunks AS (
    SELECT
        chunk_number,
        min(sample_at) AS first_sample_at,
        max(sample_at) AS last_sample_at,
        array_agg(sample_record ORDER BY sample_index)
            ::"PoWA".powa_statements_history_record[] AS records
    FROM samples
    GROUP BY chunk_number
)
INSERT INTO "PoWA".powa_statements_history (
    srvid, queryid, dbid, toplevel, userid, coalesce_range,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000, 9005, 2147483000::oid, true, 10::oid,
    tstzrange(first_sample_at, last_sample_at, '[]'),
    records, records[1], records[array_length(records, 1)]
FROM chunks
ORDER BY chunk_number;

-- Two roles run the same query on interleaved timestamps.  The legacy
-- temporal rollup caps their combined represented intervals at one window;
-- the optimized multi-user fallback must preserve that cap.
WITH users(user_id, offset_seconds) AS (
    VALUES (10::oid, 0), (11::oid, 5)
), samples AS (
    SELECT
        fixture_user.user_id,
        sample_index,
        now() - interval '2 hours 10 seconds'
            + make_interval(
                secs => sample_index * 10 + fixture_user.offset_seconds
            ) AS sample_at,
        jsonb_populate_record(
            NULL::"PoWA".powa_statements_history_record,
            jsonb_build_object(
                'ts', now() - interval '2 hours 10 seconds'
                    + make_interval(
                        secs => sample_index * 10
                            + fixture_user.offset_seconds
                    ),
                'calls', 5000 + sample_index,
                'total_exec_time', 50000 + sample_index * 10,
                'rows', 6000 + sample_index,
                'shared_blks_hit', 7000 + sample_index,
                'shared_blks_read', 800 + sample_index,
                'temp_blks_written', 90 + sample_index,
                'wal_bytes', 90000 + sample_index * 100
            )
        ) AS sample_record
    FROM users AS fixture_user
    CROSS JOIN generate_series(0, 720) AS generated(sample_index)
), user_chunks AS (
    SELECT
        user_id,
        min(sample_at) AS first_sample_at,
        max(sample_at) AS last_sample_at,
        array_agg(sample_record ORDER BY sample_index)
            ::"PoWA".powa_statements_history_record[] AS records
    FROM samples
    GROUP BY user_id
)
INSERT INTO "PoWA".powa_statements_history (
    srvid, queryid, dbid, toplevel, userid, coalesce_range,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000, 9006, 2147483000::oid, true, user_id,
    tstzrange(first_sample_at, last_sample_at, '[]'),
    records, records[1], records[array_length(records, 1)]
FROM user_chunks
ORDER BY user_id;

-- PoWA's writer keeps chunks non-overlapping, but the tables do not enforce
-- that invariant for manual imports.  An overlapping shape must be clamped
-- and marked unreliable rather than silently enabling regression comparison.
WITH chunks(chunk_number, records) AS (
    VALUES
    (
        1,
        ARRAY[
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '2 hours 10 minutes',
                    'calls', 1, 'total_exec_time', 10, 'rows', 1,
                    'shared_blks_hit', 1, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '1 hour 50 minutes',
                    'calls', 2, 'total_exec_time', 20, 'rows', 2,
                    'shared_blks_hit', 2, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '1 hour 30 minutes',
                    'calls', 3, 'total_exec_time', 30, 'rows', 3,
                    'shared_blks_hit', 3, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '1 hour 10 minutes',
                    'calls', 4, 'total_exec_time', 40, 'rows', 4,
                    'shared_blks_hit', 4, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            )
        ]::"PoWA".powa_statements_history_record[]
    ),
    (
        2,
        ARRAY[
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '1 hour 30 minutes',
                    'calls', 3, 'total_exec_time', 30, 'rows', 3,
                    'shared_blks_hit', 3, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '1 hour 10 minutes',
                    'calls', 4, 'total_exec_time', 40, 'rows', 4,
                    'shared_blks_hit', 4, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '50 minutes',
                    'calls', 5, 'total_exec_time', 50, 'rows', 5,
                    'shared_blks_hit', 5, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '30 minutes',
                    'calls', 6, 'total_exec_time', 60, 'rows', 6,
                    'shared_blks_hit', 6, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            ),
            jsonb_populate_record(
                NULL::"PoWA".powa_statements_history_record,
                jsonb_build_object('ts', now() - interval '10 minutes',
                    'calls', 7, 'total_exec_time', 70, 'rows', 7,
                    'shared_blks_hit', 7, 'shared_blks_read', 0,
                    'temp_blks_written', 0, 'wal_bytes', 0)
            )
        ]::"PoWA".powa_statements_history_record[]
    )
)
INSERT INTO "PoWA".powa_statements_history (
    srvid, queryid, dbid, toplevel, userid, coalesce_range,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483001, 9007, 2147483001::oid, true, 10::oid,
    tstzrange((records[1]).ts, (records[array_length(records, 1)]).ts, '[]'),
    records, records[1], records[array_length(records, 1)]
FROM chunks
ORDER BY chunk_number;

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
        -- Physical ordinality is deliberately not chronological.  Optimized
        -- chunk rollups must order by record.ts like the public delta API.
        ROW(now() - interval '39 minutes 40 seconds', 120)::"PoWA".powa_wait_sampling_history_record,
        ROW(now() - interval '40 minutes', 100)::"PoWA".powa_wait_sampling_history_record,
        ROW(now() - interval '39 minutes 50 seconds', 3)::"PoWA".powa_wait_sampling_history_record
    ] AS records,
    ROW(now() - interval '40 minutes', 100)
        ::"PoWA".powa_wait_sampling_history_record AS oldest_record,
    ROW(now() - interval '39 minutes 40 seconds', 120)
        ::"PoWA".powa_wait_sampling_history_record AS newest_record
)
INSERT INTO "PoWA".powa_wait_sampling_history (
    srvid, coalesce_range, queryid, dbid, event_type, event,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000,
    tstzrange(now() - interval '40 minutes', now() - interval '39 minutes 40 seconds', '[]'),
    9001, 2147483000::oid, 'IO', 'DataFileRead', records,
    oldest_record, newest_record
FROM fixture;

-- Wait-only/orphan series model extensions or stale query ids that have no
-- current statement activity.  Active-key pushdown must discard them before
-- expanding their arrays.
INSERT INTO "PoWA".powa_wait_sampling_history (
    srvid, coalesce_range, queryid, dbid, event_type, event,
    records, mins_in_range, maxs_in_range
)
SELECT
    2147483000,
    tstzrange(
        now() - interval '40 minutes',
        now() - interval '39 minutes 50 seconds',
        '[]'
    ),
    910000 + orphan_id,
    2147483000::oid,
    'IO',
    'OrphanDataFileRead',
    ARRAY[
        ROW(now() - interval '40 minutes', 1)
            ::"PoWA".powa_wait_sampling_history_record,
        ROW(now() - interval '39 minutes 50 seconds', 2)
            ::"PoWA".powa_wait_sampling_history_record
    ],
    ROW(now() - interval '40 minutes', 1)
        ::"PoWA".powa_wait_sampling_history_record,
    ROW(now() - interval '39 minutes 50 seconds', 2)
        ::"PoWA".powa_wait_sampling_history_record
FROM generate_series(1, 64) AS orphan(orphan_id);

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

DO $query_rollup_boundary_parity$
DECLARE
    legacy_boundary record;
    optimized_boundary record;
    boundary_quality record;
    legacy_multi_user record;
    optimized_multi_user record;
    multi_user_quality record;
    overlap_quality record;
BEGIN
    WITH delta_source AS MATERIALIZED (
        SELECT *
        FROM advisor.query_deltas(now() - interval '2 hours')
        WHERE server_id = 2147483000
          AND query_id = 9005
          AND toplevel
    ), temporal_samples AS (
        SELECT
            sample_at,
            bool_and(predecessor_available) AS predecessor_available,
            bool_or(reset_detected) AS reset_detected,
            bool_or(gap_detected) AS gap_detected
        FROM delta_source
        GROUP BY sample_at
    )
    SELECT
        sum(calls) FILTER (
            WHERE sample_at >= now() - interval '1 hour'
              AND predecessor_available
              AND NOT (
                  gap_detected
                  AND previous_sample_at < now() - interval '1 hour'
              )
        )::bigint AS calls,
        sum(calls) FILTER (
            WHERE sample_at >= now() - interval '2 hours'
              AND sample_at < now() - interval '1 hour'
              AND predecessor_available
              AND NOT (
                  gap_detected
                  AND previous_sample_at < now() - interval '2 hours'
              )
        )::bigint AS previous_calls_raw,
        COALESCE(bool_or(reset_detected) FILTER (
            WHERE sample_at >= now() - interval '2 hours'
        ), false) AS reset_detected,
        COALESCE((
            SELECT bool_or(sample.gap_detected)
            FROM temporal_samples AS sample
            WHERE sample.sample_at >= now() - interval '2 hours'
        ), false) AS gap_detected,
        COALESCE((
            SELECT bool_or(NOT sample.predecessor_available)
            FROM temporal_samples AS sample
            WHERE sample.sample_at >= now() - interval '2 hours'
        ), false) AS predecessor_missing
      INTO STRICT legacy_boundary
      FROM delta_source;

    SELECT calls, previous_calls_raw, query_reset_detected AS reset_detected,
           query_gap_detected AS gap_detected, predecessor_missing
      INTO STRICT optimized_boundary
      FROM advisor.query_rollups_for_metrics(interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9005;

    IF legacy_boundary.calls <> 360
       OR legacy_boundary.previous_calls_raw <> 360
       OR legacy_boundary.reset_detected
       OR legacy_boundary.gap_detected
       OR legacy_boundary.predecessor_missing
       OR legacy_boundary.calls IS DISTINCT FROM optimized_boundary.calls
       OR legacy_boundary.previous_calls_raw
            IS DISTINCT FROM optimized_boundary.previous_calls_raw
       OR legacy_boundary.reset_detected
            IS DISTINCT FROM optimized_boundary.reset_detected
       OR legacy_boundary.gap_detected
            IS DISTINCT FROM optimized_boundary.gap_detected
       OR legacy_boundary.predecessor_missing
            IS DISTINCT FROM optimized_boundary.predecessor_missing THEN
        RAISE EXCEPTION 'multi-chunk boundary parity failed: legacy=%, optimized=%',
            legacy_boundary, optimized_boundary;
    END IF;

    SELECT calls, previous_calls, coverage_percent,
           previous_period_available, warming_up, comparison_reliable
      INTO STRICT boundary_quality
      FROM advisor.query_metrics(interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9005;

    IF boundary_quality.calls <> 360
       OR boundary_quality.previous_calls <> 360
       OR boundary_quality.coverage_percent < 99
       OR boundary_quality.coverage_percent > 100
       OR NOT boundary_quality.previous_period_available
       OR boundary_quality.warming_up
       OR NOT boundary_quality.comparison_reliable THEN
        RAISE EXCEPTION 'multi-chunk quality parity failed: %', boundary_quality;
    END IF;

    WITH delta_source AS MATERIALIZED (
        SELECT *
        FROM advisor.query_deltas(now() - interval '2 hours')
        WHERE server_id = 2147483000
          AND query_id = 9006
          AND toplevel
    ), temporal_samples AS (
        SELECT
            sample_at,
            max(previous_sample_at) AS previous_sample_at,
            bool_and(predecessor_available) AS predecessor_available,
            bool_or(gap_detected) AS gap_detected
        FROM delta_source
        GROUP BY sample_at
    )
    SELECT
        least(3600, sum(CASE
            WHEN sample_at >= now() - interval '1 hour'
             AND previous_sample_at < now()
             AND predecessor_available
             AND NOT gap_detected
            THEN greatest(extract(epoch FROM (
                least(sample_at, now())
                - greatest(previous_sample_at, now() - interval '1 hour')
            )), 0)
            ELSE 0
        END))::double precision AS current_covered_seconds,
        least(3600, sum(CASE
            WHEN sample_at >= now() - interval '1 hour'
             AND previous_sample_at < now()
             AND predecessor_available
            THEN greatest(extract(epoch FROM (
                least(sample_at, now())
                - greatest(previous_sample_at, now() - interval '1 hour')
            )), 0)
            ELSE 0
        END))::double precision AS current_represented_seconds,
        least(3600, sum(CASE
            WHEN sample_at >= now() - interval '2 hours'
             AND sample_at < now() - interval '1 hour'
             AND previous_sample_at < now() - interval '1 hour'
             AND predecessor_available
             AND NOT gap_detected
            THEN greatest(extract(epoch FROM (
                least(sample_at, now() - interval '1 hour')
                - greatest(previous_sample_at, now() - interval '2 hours')
            )), 0)
            ELSE 0
        END))::double precision AS previous_covered_seconds
      INTO STRICT legacy_multi_user
      FROM temporal_samples;

    SELECT user_id, current_covered_seconds, current_represented_seconds,
           previous_covered_seconds, predecessor_missing,
           query_gap_detected, query_reset_detected
      INTO STRICT optimized_multi_user
      FROM advisor.query_rollups_for_metrics(interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9006;

    IF legacy_multi_user.current_covered_seconds <> 3600
       OR legacy_multi_user.current_represented_seconds <> 3600
       OR legacy_multi_user.previous_covered_seconds <> 3600
       OR optimized_multi_user.user_id IS NOT NULL
       OR abs(legacy_multi_user.current_covered_seconds
            - optimized_multi_user.current_covered_seconds) > 1e-6
       OR abs(legacy_multi_user.current_represented_seconds
            - optimized_multi_user.current_represented_seconds) > 1e-6
       OR abs(legacy_multi_user.previous_covered_seconds
            - optimized_multi_user.previous_covered_seconds) > 1e-6
       OR optimized_multi_user.predecessor_missing
       OR optimized_multi_user.query_gap_detected
       OR optimized_multi_user.query_reset_detected THEN
        RAISE EXCEPTION 'multi-user coverage cap parity failed: legacy=%, optimized=%',
            legacy_multi_user, optimized_multi_user;
    END IF;

    SELECT user_id, coverage_percent, previous_period_available,
           warming_up, comparison_reliable
      INTO STRICT multi_user_quality
      FROM advisor.query_metrics(interval '1 hour')
     WHERE server_id = 2147483000 AND query_id = 9006;

    IF multi_user_quality.user_id IS NOT NULL
       OR abs(multi_user_quality.coverage_percent - 100) > 1e-6
       OR NOT multi_user_quality.previous_period_available
       OR multi_user_quality.warming_up
       OR NOT multi_user_quality.comparison_reliable THEN
        RAISE EXCEPTION 'multi-user quality cap failed: %', multi_user_quality;
    END IF;

    SELECT rollup.current_covered_seconds,
           rollup.current_represented_seconds,
           rollup.previous_covered_seconds,
           rollup.predecessor_missing,
           metric.coverage_percent,
           metric.warming_up,
           metric.comparison_reliable
      INTO STRICT overlap_quality
      FROM advisor.query_rollups_for_metrics(interval '1 hour') AS rollup
      JOIN advisor.query_metrics(interval '1 hour') AS metric
        USING (server_id, database_id, query_id)
     WHERE rollup.server_id = 2147483001
       AND rollup.query_id = 9007;

    IF overlap_quality.current_covered_seconds > 3600
       OR overlap_quality.current_represented_seconds > 3600
       OR overlap_quality.previous_covered_seconds > 3600
       OR NOT overlap_quality.predecessor_missing
       OR overlap_quality.coverage_percent > 100
       OR NOT overlap_quality.warming_up
       OR overlap_quality.comparison_reliable THEN
        RAISE EXCEPTION 'overlapping chunks did not fail closed: %', overlap_quality;
    END IF;
END
$query_rollup_boundary_parity$;

DO $performance_parity$
DECLARE
    selected_window interval;
    active_keys jsonb;
    difference_count bigint;
BEGIN
    -- The optimized helpers intentionally change floating-point aggregation
    -- order. Integer/numeric counters remain exact; double precision values
    -- are compared at a tolerance far below pg_stat_statements precision.
    FOR selected_window IN
        SELECT unnest(ARRAY[interval '1 hour', interval '24 hours'])
    LOOP
        SELECT jsonb_agg(jsonb_build_object(
            'server_id', rollup.server_id,
            'database_id', rollup.database_id,
            'query_id', rollup.query_id
        ))
          INTO active_keys
          FROM advisor.query_rollups_for_metrics(selected_window) AS rollup
         WHERE rollup.server_id = 2147483000;

        WITH legacy AS (
            SELECT
                delta.server_id,
                delta.database_id,
                delta.query_id,
                sum(delta.calls) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS calls,
                sum(delta.rows) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS rows,
                sum(delta.total_exec_time_ms) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::double precision AS total_exec_time_ms,
                sum(delta.shared_blocks_hit) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS shared_blocks_hit,
                sum(delta.shared_blocks_read) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS shared_blocks_read,
                sum(delta.temp_blocks_written) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS temp_blocks_written,
                sum(delta.wal_bytes) FILTER (
                    WHERE delta.sample_at >= now() - selected_window
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::numeric AS wal_bytes
            FROM advisor.query_deltas(now() - (selected_window * 2)) AS delta
            WHERE delta.server_id = 2147483000
              AND delta.query_id BETWEEN 9001 AND 9006
              AND delta.toplevel
            GROUP BY delta.server_id, delta.database_id, delta.query_id
            HAVING COALESCE(sum(delta.calls) FILTER (
                WHERE delta.sample_at >= now() - selected_window
                  AND delta.predecessor_available
                  AND NOT (
                      delta.gap_detected
                      AND delta.previous_sample_at < now() - selected_window
                  )
            ), 0) > 0
        ), optimized AS (
            SELECT
                server_id,
                database_id,
                query_id,
                calls,
                rows,
                total_exec_time_ms,
                shared_blocks_hit,
                shared_blocks_read,
                temp_blocks_written,
                wal_bytes
            FROM advisor.query_rollups_for_metrics(selected_window)
            WHERE server_id = 2147483000
        )
        SELECT count(*)
          INTO difference_count
          FROM legacy
          FULL JOIN optimized USING (server_id, database_id, query_id)
         WHERE legacy.server_id IS NULL
            OR optimized.server_id IS NULL
            OR legacy.calls IS DISTINCT FROM optimized.calls
            OR legacy.rows IS DISTINCT FROM optimized.rows
            OR legacy.shared_blocks_hit IS DISTINCT FROM optimized.shared_blocks_hit
            OR legacy.shared_blocks_read IS DISTINCT FROM optimized.shared_blocks_read
            OR legacy.temp_blocks_written IS DISTINCT FROM optimized.temp_blocks_written
            OR legacy.wal_bytes IS DISTINCT FROM optimized.wal_bytes
            OR abs(legacy.total_exec_time_ms - optimized.total_exec_time_ms) > 1e-6;

        IF difference_count <> 0 THEN
            RAISE EXCEPTION 'query rollup parity failed for %: % rows',
                selected_window, difference_count;
        END IF;

        WITH delta_source AS MATERIALIZED (
            SELECT *
            FROM advisor.query_deltas(now() - (selected_window * 2))
            WHERE server_id = 2147483000
              AND query_id BETWEEN 9001 AND 9006
              AND toplevel
        ), temporal_samples AS (
            SELECT
                server_id,
                database_id,
                query_id,
                sample_at,
                max(previous_sample_at) AS previous_sample_at,
                bool_and(predecessor_available) AS predecessor_available,
                bool_or(gap_detected) AS gap_detected
            FROM delta_source
            GROUP BY server_id, database_id, query_id, sample_at
        ), legacy AS (
            SELECT
                server_id,
                database_id,
                query_id,
                least(extract(epoch FROM selected_window), sum(CASE
                    WHEN sample_at >= now() - selected_window
                     AND previous_sample_at < now()
                     AND predecessor_available
                     AND NOT gap_detected
                    THEN greatest(extract(epoch FROM (
                        least(sample_at, now())
                        - greatest(previous_sample_at, now() - selected_window)
                    )), 0)
                    ELSE 0
                END))::double precision AS current_covered_seconds,
                least(extract(epoch FROM selected_window), sum(CASE
                    WHEN sample_at >= now() - selected_window
                     AND previous_sample_at < now()
                     AND predecessor_available
                    THEN greatest(extract(epoch FROM (
                        least(sample_at, now())
                        - greatest(previous_sample_at, now() - selected_window)
                    )), 0)
                    ELSE 0
                END))::double precision AS current_represented_seconds,
                least(extract(epoch FROM selected_window), sum(CASE
                    WHEN sample_at >= now() - (selected_window * 2)
                     AND sample_at < now() - selected_window
                     AND previous_sample_at < now() - selected_window
                     AND predecessor_available
                     AND NOT gap_detected
                    THEN greatest(extract(epoch FROM (
                        least(sample_at, now() - selected_window)
                        - greatest(
                            previous_sample_at,
                            now() - (selected_window * 2)
                        )
                    )), 0)
                    ELSE 0
                END))::double precision AS previous_covered_seconds
            FROM temporal_samples
            GROUP BY server_id, database_id, query_id
        ), optimized AS (
            SELECT
                server_id,
                database_id,
                query_id,
                current_covered_seconds,
                current_represented_seconds,
                previous_covered_seconds
            FROM advisor.query_rollups_for_metrics(selected_window)
            WHERE server_id = 2147483000
        )
        SELECT count(*)
          INTO difference_count
          FROM legacy
          JOIN optimized USING (server_id, database_id, query_id)
         WHERE abs(
                   legacy.current_covered_seconds
                   - optimized.current_covered_seconds
               ) > 1e-6
            OR abs(
                   legacy.current_represented_seconds
                   - optimized.current_represented_seconds
               ) > 1e-6
            OR abs(
                   legacy.previous_covered_seconds
                   - optimized.previous_covered_seconds
               ) > 1e-6;

        IF difference_count <> 0 THEN
            RAISE EXCEPTION 'coverage rollup parity failed for %: % rows',
                selected_window, difference_count;
        END IF;

        WITH legacy AS (
            SELECT
                delta.server_id,
                delta.database_id,
                delta.query_id,
                delta.event_type,
                delta.event,
                COALESCE(sum(delta.samples) FILTER (
                    WHERE delta.samples > 0
                      AND delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                ), 0)::bigint AS samples,
                COALESCE(bool_or(delta.reset_detected), false) AS reset_detected,
                COALESCE(bool_or(delta.gap_detected), false) AS reliability_issue
            FROM advisor.wait_deltas(now() - selected_window) AS delta
            WHERE delta.server_id = 2147483000
              AND delta.query_id BETWEEN 9001 AND 9006
            GROUP BY
                delta.server_id,
                delta.database_id,
                delta.query_id,
                delta.event_type,
                delta.event
        ), optimized AS (
            SELECT *
            FROM advisor.wait_rollups_for_queries(
                now() - selected_window,
                COALESCE(active_keys, '[]'::jsonb)
            )
            WHERE server_id = 2147483000
        ), differences AS (
            (SELECT * FROM legacy EXCEPT ALL SELECT * FROM optimized)
            UNION ALL
            (SELECT * FROM optimized EXCEPT ALL SELECT * FROM legacy)
        )
        SELECT count(*) INTO difference_count FROM differences;

        IF difference_count <> 0 THEN
            RAISE EXCEPTION 'wait rollup parity failed for %: % rows',
                selected_window, difference_count;
        END IF;

        WITH legacy AS (
            SELECT
                delta.server_id,
                delta.database_id,
                delta.query_id,
                sum(delta.exec_user_time_seconds) FILTER (
                    WHERE delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                ) * 1000.0 AS cpu_user_time_ms,
                sum(delta.exec_system_time_seconds) FILTER (
                    WHERE delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                ) * 1000.0 AS cpu_system_time_ms,
                sum(delta.filesystem_reads_bytes) FILTER (
                    WHERE delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS filesystem_reads_bytes,
                sum(delta.filesystem_writes_bytes) FILTER (
                    WHERE delta.predecessor_available
                      AND NOT (
                          delta.gap_detected
                          AND delta.previous_sample_at < now() - selected_window
                      )
                )::bigint AS filesystem_writes_bytes,
                bool_or(
                    delta.predecessor_available
                    AND NOT (
                        delta.gap_detected
                        AND delta.previous_sample_at < now() - selected_window
                    )
                ) AS data_available,
                bool_or(delta.reset_detected) AS reset_detected,
                bool_or(delta.gap_detected) AS reliability_issue
            FROM advisor.kcache_deltas(now() - selected_window) AS delta
            WHERE delta.server_id = 2147483000
              AND delta.query_id BETWEEN 9001 AND 9006
              AND delta.toplevel
            GROUP BY delta.server_id, delta.database_id, delta.query_id
        ), optimized AS (
            SELECT *
            FROM advisor.kcache_rollups_for_queries(
                now() - selected_window,
                COALESCE(active_keys, '[]'::jsonb)
            )
            WHERE server_id = 2147483000
        )
        SELECT count(*)
          INTO difference_count
          FROM legacy
          FULL JOIN optimized USING (server_id, database_id, query_id)
         WHERE legacy.server_id IS NULL
            OR optimized.server_id IS NULL
            OR legacy.filesystem_reads_bytes IS DISTINCT FROM optimized.filesystem_reads_bytes
            OR legacy.filesystem_writes_bytes IS DISTINCT FROM optimized.filesystem_writes_bytes
            OR legacy.data_available IS DISTINCT FROM optimized.data_available
            OR legacy.reset_detected IS DISTINCT FROM optimized.reset_detected
            OR legacy.reliability_issue IS DISTINCT FROM optimized.reliability_issue
            OR abs(legacy.cpu_user_time_ms - optimized.cpu_user_time_ms) > 1e-6
            OR abs(legacy.cpu_system_time_ms - optimized.cpu_system_time_ms) > 1e-6;

        IF difference_count <> 0 THEN
            RAISE EXCEPTION 'kcache rollup parity failed for %: % rows',
                selected_window, difference_count;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM advisor.query_metrics(selected_window)
            WHERE server_id = 2147483000
              AND query_id BETWEEN 910001 AND 910064
        ) THEN
            RAISE EXCEPTION 'orphan wait-only query leaked into query_metrics for %',
                selected_window;
        END IF;
    END LOOP;
END
$performance_parity$;

-- The API-specific trend helper must remain numerically equivalent to the
-- reset/gap-aware query_deltas adapter.  Exercise both overloads: overview
-- uses the global form, while query detail supplies the complete identity.
DO $trend_parity$
DECLARE
    selected_start timestamptz := now() - interval '1 hour';
    selected_bucket interval := interval '5 minutes';
    selected_query_id bigint;
    difference_count bigint;
BEGIN
    WITH legacy AS (
        SELECT
            date_bin(
                selected_bucket,
                delta.sample_at,
                timestamptz '2000-01-01'
            ) AS bucket_at,
            sum(delta.total_exec_time_ms)::double precision
                AS total_exec_time_ms,
            sum(delta.calls)::bigint AS calls
        FROM advisor.query_deltas(selected_start) AS delta
        JOIN "PoWA".powa_databases AS database
          ON database.srvid = delta.server_id
         AND database.oid = delta.database_id
        WHERE database.datname <> 'powa'
          AND delta.sample_at >= selected_start
          AND delta.toplevel
          AND delta.predecessor_available
          AND NOT (
              delta.gap_detected
              AND delta.previous_sample_at < selected_start
          )
        GROUP BY 1
    ), optimized AS (
        SELECT *
        FROM advisor.query_trend(selected_start, selected_bucket)
    )
    SELECT count(*)
      INTO difference_count
      FROM legacy
      FULL JOIN optimized USING (bucket_at)
     WHERE legacy.bucket_at IS NULL
        OR optimized.bucket_at IS NULL
        OR legacy.calls IS DISTINCT FROM optimized.calls
        OR abs(
            legacy.total_exec_time_ms - optimized.total_exec_time_ms
        ) > 1e-6;

    IF difference_count <> 0 THEN
        RAISE EXCEPTION 'global query_trend parity failed: % buckets',
            difference_count;
    END IF;

    FOREACH selected_query_id IN ARRAY ARRAY[
        9001::bigint,
        9002::bigint,
        9003::bigint,
        9004::bigint,
        9005::bigint,
        9006::bigint
    ] LOOP
        WITH legacy AS (
            SELECT
                date_bin(
                    selected_bucket,
                    delta.sample_at,
                    timestamptz '2000-01-01'
                ) AS bucket_at,
                sum(delta.total_exec_time_ms)::double precision
                    AS total_exec_time_ms,
                sum(delta.calls)::bigint AS calls
            FROM advisor.query_deltas(selected_start) AS delta
            WHERE delta.server_id = 2147483000
              AND delta.database_id = 2147483000::oid
              AND delta.query_id = selected_query_id
              AND delta.sample_at >= selected_start
              AND delta.toplevel
              AND delta.predecessor_available
              AND NOT (
                  delta.gap_detected
                  AND delta.previous_sample_at < selected_start
              )
            GROUP BY 1
        ), optimized AS (
            SELECT *
            FROM advisor.query_trend(
                selected_start,
                selected_bucket,
                2147483000,
                2147483000::oid,
                selected_query_id
            )
        )
        SELECT count(*)
          INTO difference_count
          FROM legacy
          FULL JOIN optimized USING (bucket_at)
         WHERE legacy.bucket_at IS NULL
            OR optimized.bucket_at IS NULL
            OR legacy.calls IS DISTINCT FROM optimized.calls
            OR abs(
                legacy.total_exec_time_ms - optimized.total_exec_time_ms
            ) > 1e-6;

        IF difference_count <> 0 THEN
            RAISE EXCEPTION
                'scoped query_trend parity failed for query %: % buckets',
                selected_query_id,
                difference_count;
        END IF;
    END LOOP;

    IF has_function_privilege(
        'public',
        'advisor.query_trend(timestamptz,interval)',
        'EXECUTE'
    ) OR has_function_privilege(
        'public',
        'advisor.query_trend(timestamptz,interval,integer,oid,bigint)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'query_trend overloads leaked EXECUTE to PUBLIC';
    END IF;

    IF NOT has_function_privilege(
        'advisor_api',
        'advisor.query_trend(timestamptz,interval)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'advisor_api',
        'advisor.query_trend(timestamptz,interval,integer,oid,bigint)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'advisor_api cannot execute query_trend overloads';
    END IF;
END
$trend_parity$;

ROLLBACK;
