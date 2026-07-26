\set ON_ERROR_STOP on

-- Repository fixture: raw transport positions remain one-to-one while final
-- natural-key duplicates are deterministically aggregated.  All rows roll back.
BEGIN;
SELECT pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
        'postgresql-advisor:join-duplicate-aggregation-test',
        0
    )
);

DO $constraint_removed$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM pg_constraint AS constraint_record
         WHERE constraint_record.conrelid =
                   'advisor_ingest.join_predicate_staging'::regclass
           AND constraint_record.contype = 'u'
           AND (
               SELECT array_agg(attribute.attname ORDER BY key_column.ordinality)
                 FROM unnest(constraint_record.conkey) WITH ORDINALITY
                      AS key_column(attnum, ordinality)
                 JOIN pg_attribute AS attribute
                   ON attribute.attrelid = constraint_record.conrelid
                  AND attribute.attnum = key_column.attnum
           ) = ARRAY[
               'server_id', 'batch_id', 'dbid', 'userid', 'queryid',
               'qualnodeid', 'opno', 'lrelid', 'lattnum', 'rrelid', 'rattnum'
           ]::name[]
    ) THEN
        RAISE EXCEPTION 'staging natural-key UNIQUE constraint still exists';
    END IF;
END
$constraint_removed$;

SET SESSION AUTHORIZATION advisor_join_ingest;

SELECT advisor_ingest.ingest_join_chunk(
    'test-source',
    9100000000000000011,
    '2026-07-26 01:00:00+00'::timestamptz,
    6,
    1,
    0,
    false,
    '[
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9002,"qualnodeid":1001,"lrelid":20001,"lattnum":2,"opno":98,"operatorName":"zeta","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":2,"executionCount":10,"nbfiltered":4,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9001,"qualnodeid":1001,"lrelid":20001,"lattnum":2,"opno":98,"operatorName":"alpha","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":3,"executionCount":20,"nbfiltered":6,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9102,"qualnodeid":1002,"lrelid":20001,"lattnum":3,"opno":96,"operatorName":"equal","operatorCommutator":96,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":7,"executionCount":40,"nbfiltered":9,"evalType":"f","isJoin":false}
    ]'::jsonb
);

SELECT advisor_ingest.ingest_join_chunk(
    'test-source',
    9100000000000000011,
    '2026-07-26 01:00:00+00'::timestamptz,
    6,
    2,
    3,
    true,
    '[
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9003,"qualnodeid":1001,"lrelid":20001,"lattnum":2,"opno":98,"operatorName":"middle","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":5,"executionCount":30,"nbfiltered":8,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9101,"qualnodeid":1002,"lrelid":20001,"lattnum":3,"opno":96,"operatorName":"equal","operatorCommutator":96,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":11,"executionCount":50,"nbfiltered":10,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9201,"qualnodeid":1003,"lrelid":20001,"lattnum":4,"opno":521,"operatorName":"greater","operatorCommutator":97,"btreeStrategy":5,"rrelid":null,"rattnum":null,"occurences":13,"executionCount":60,"nbfiltered":12,"evalType":"f","isJoin":false}
    ]'::jsonb
);

RESET SESSION AUTHORIZATION;

DO $raw_transport$
DECLARE
    v_server_id integer;
BEGIN
    SELECT id INTO STRICT v_server_id
      FROM "PoWA".powa_servers
     WHERE alias = 'test-source';

    IF (SELECT count(*)
          FROM advisor_ingest.join_predicate_staging
         WHERE join_predicate_staging.server_id = v_server_id
           AND batch_id = 9100000000000000011) <> 6 THEN
        RAISE EXCEPTION 'raw staging row count was not preserved';
    END IF;
    IF (SELECT array_agg(
                   pg_catalog.format('%s:%s', chunk_no, row_in_chunk)
                   ORDER BY chunk_no, row_in_chunk
               )
          FROM advisor_ingest.join_predicate_staging
         WHERE join_predicate_staging.server_id = v_server_id
           AND batch_id = 9100000000000000011)
       IS DISTINCT FROM ARRAY[
           '1:1', '1:2', '1:3', '2:1', '2:2', '2:3'
       ]::text[] THEN
        RAISE EXCEPTION 'raw staging positions are incomplete or non-deterministic';
    END IF;
END
$raw_transport$;

SET SESSION AUTHORIZATION advisor_join_ingest;
SELECT advisor_ingest.finalize_join_batch(
    'test-source', 9100000000000000011
) AS finalized \gset
\if :finalized
\else
\quit 1
\endif
RESET SESSION AUTHORIZATION;

DO $deduplicated_result$
DECLARE
    v_server_id integer;
    aggregate_row record;
BEGIN
    SELECT id INTO STRICT v_server_id
      FROM "PoWA".powa_servers
     WHERE alias = 'test-source';

    IF (SELECT row_count
          FROM advisor_ingest.join_snapshot_batches
         WHERE join_snapshot_batches.server_id = v_server_id
           AND batch_id = 9100000000000000011) <> 6 THEN
        RAISE EXCEPTION 'final batch no longer reports raw transport row count';
    END IF;
    IF (SELECT count(*)
          FROM advisor_ingest.join_predicate_samples
         WHERE join_predicate_samples.server_id = v_server_id
           AND batch_id = 9100000000000000011) <> 3 THEN
        RAISE EXCEPTION 'final natural-key deduplication did not produce three rows';
    END IF;

    SELECT sample.* INTO STRICT aggregate_row
      FROM advisor_ingest.join_predicate_samples AS sample
     WHERE sample.server_id = v_server_id
       AND sample.batch_id = 9100000000000000011
       AND sample.qualnodeid = 1001;
    IF aggregate_row.qualid <> 9001
       OR aggregate_row.operator_name <> 'alpha'
       OR aggregate_row.occurences <> 10
       OR aggregate_row.execution_count <> 60
       OR aggregate_row.nbfiltered <> 18 THEN
        RAISE EXCEPTION 'duplicate metrics/metadata were not deterministically merged';
    END IF;

    IF EXISTS (
        SELECT 1 FROM advisor_ingest.join_batch_staging
         WHERE join_batch_staging.server_id = v_server_id
           AND batch_id = 9100000000000000011
        UNION ALL
        SELECT 1 FROM advisor_ingest.join_chunk_receipts
         WHERE join_chunk_receipts.server_id = v_server_id
           AND batch_id = 9100000000000000011
        UNION ALL
        SELECT 1 FROM advisor_ingest.join_predicate_staging
         WHERE join_predicate_staging.server_id = v_server_id
           AND batch_id = 9100000000000000011
    ) THEN
        RAISE EXCEPTION 'finalized batch left private staging rows behind';
    END IF;
END
$deduplicated_result$;

-- Retry after an unknown ACK outcome remains a metadata-checked no-op.
SET SESSION AUTHORIZATION advisor_join_ingest;
SELECT NOT advisor_ingest.ingest_join_chunk(
    'test-source',
    9100000000000000011,
    '2026-07-26 01:00:00+00'::timestamptz,
    6,
    1,
    0,
    false,
    '[
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9002,"qualnodeid":1001,"lrelid":20001,"lattnum":2,"opno":98,"operatorName":"zeta","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":2,"executionCount":10,"nbfiltered":4,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9001,"qualnodeid":1001,"lrelid":20001,"lattnum":2,"opno":98,"operatorName":"alpha","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":3,"executionCount":20,"nbfiltered":6,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":101,"qualid":9102,"qualnodeid":1002,"lrelid":20001,"lattnum":3,"opno":96,"operatorName":"equal","operatorCommutator":96,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":7,"executionCount":40,"nbfiltered":9,"evalType":"f","isJoin":false}
    ]'::jsonb
) AS retry_chunk_noop \gset
\if :retry_chunk_noop
\else
\quit 1
\endif
SELECT NOT advisor_ingest.finalize_join_batch(
    'test-source', 9100000000000000011
) AS retry_finalize_noop \gset
\if :retry_finalize_noop
\else
\quit 1
\endif

-- The retained pre-chunk API is used during rolling upgrades and must apply
-- the same lossless duplicate aggregation instead of ON CONFLICT data loss.
SELECT advisor_ingest.ingest_join_batch(
    'test-source',
    9100000000000000013,
    '2026-07-26 01:02:00+00'::timestamptz,
    '[
      {"dbid":16384,"userid":19000,"queryid":103,"qualid":9403,"qualnodeid":1201,"lrelid":20001,"lattnum":6,"opno":98,"operatorName":"zeta","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":17,"executionCount":70,"nbfiltered":14,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":103,"qualid":9401,"qualnodeid":1201,"lrelid":20001,"lattnum":6,"opno":98,"operatorName":"alpha","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":19,"executionCount":80,"nbfiltered":16,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":103,"qualid":9501,"qualnodeid":1202,"lrelid":20001,"lattnum":7,"opno":96,"operatorName":"equal","operatorCommutator":96,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":23,"executionCount":90,"nbfiltered":18,"evalType":"f","isJoin":false}
    ]'::jsonb
) AS legacy_finalized \gset
\if :legacy_finalized
\else
\quit 1
\endif

RESET SESSION AUTHORIZATION;

DO $legacy_deduplicated_result$
DECLARE
    v_server_id integer;
    aggregate_row record;
BEGIN
    SELECT id INTO STRICT v_server_id
      FROM "PoWA".powa_servers
     WHERE alias = 'test-source';

    IF (SELECT row_count
          FROM advisor_ingest.join_snapshot_batches
         WHERE join_snapshot_batches.server_id = v_server_id
           AND batch_id = 9100000000000000013) <> 3
       OR (SELECT count(*)
             FROM advisor_ingest.join_predicate_samples
            WHERE join_predicate_samples.server_id = v_server_id
              AND batch_id = 9100000000000000013) <> 2 THEN
        RAISE EXCEPTION 'legacy path did not preserve raw/final cardinalities';
    END IF;

    SELECT sample.* INTO STRICT aggregate_row
      FROM advisor_ingest.join_predicate_samples AS sample
     WHERE sample.server_id = v_server_id
       AND sample.batch_id = 9100000000000000013
       AND sample.qualnodeid = 1201;
    IF aggregate_row.qualid <> 9401
       OR aggregate_row.operator_name <> 'alpha'
       OR aggregate_row.occurences <> 36
       OR aggregate_row.execution_count <> 150
       OR aggregate_row.nbfiltered <> 30 THEN
        RAISE EXCEPTION 'legacy duplicate metrics/metadata were not merged';
    END IF;
END
$legacy_deduplicated_result$;

-- Two individually valid bigint counters must fail closed when their natural-
-- key aggregate cannot fit the finalized bigint schema.
SET SESSION AUTHORIZATION advisor_join_ingest;
SELECT advisor_ingest.ingest_join_chunk(
    'test-source',
    9100000000000000012,
    '2026-07-26 01:01:00+00'::timestamptz,
    2,
    1,
    0,
    true,
    '[
      {"dbid":16384,"userid":19000,"queryid":102,"qualid":9301,"qualnodeid":1101,"lrelid":20001,"lattnum":5,"opno":98,"operatorName":"equal","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":9223372036854775807,"executionCount":1,"nbfiltered":1,"evalType":"f","isJoin":false},
      {"dbid":16384,"userid":19000,"queryid":102,"qualid":9302,"qualnodeid":1101,"lrelid":20001,"lattnum":5,"opno":98,"operatorName":"equal","operatorCommutator":99,"btreeStrategy":3,"rrelid":null,"rattnum":null,"occurences":1,"executionCount":1,"nbfiltered":1,"evalType":"f","isJoin":false}
    ]'::jsonb
);

DO $overflow_is_fail_closed$
DECLARE
    error_message text;
BEGIN
    BEGIN
        PERFORM advisor_ingest.finalize_join_batch(
            'test-source', 9100000000000000012
        );
        RAISE EXCEPTION 'overflowing duplicate metrics were finalized';
    EXCEPTION
        WHEN SQLSTATE '22003' THEN
            GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
            IF error_message NOT LIKE 'JOIN finalization metric overflow%' THEN
                RAISE EXCEPTION 'overflow error is not actionable: %', error_message;
            END IF;
    END;
END
$overflow_is_fail_closed$;

RESET SESSION AUTHORIZATION;

DO $overflow_state$
DECLARE
    v_server_id integer;
BEGIN
    SELECT id INTO STRICT v_server_id
      FROM "PoWA".powa_servers
     WHERE alias = 'test-source';
    IF EXISTS (
        SELECT 1 FROM advisor_ingest.join_snapshot_batches
         WHERE join_snapshot_batches.server_id = v_server_id
           AND batch_id = 9100000000000000012
    ) OR (SELECT count(*)
            FROM advisor_ingest.join_predicate_staging
           WHERE join_predicate_staging.server_id = v_server_id
             AND batch_id = 9100000000000000012) <> 2 THEN
        RAISE EXCEPTION 'overflow did not preserve retryable raw staging state';
    END IF;
END
$overflow_state$;

-- Keep the previously proven 25,001-row transport boundary in this regression
-- fixture: two full 10k chunks plus a 5,001-row tail must remain lossless.
SET SESSION AUTHORIZATION advisor_join_ingest;
DO $large_chunk_transport$
DECLARE
    c_total_rows constant integer := 25001;
    v_batch_id constant bigint := 9100000000000000015;
    v_chunk_no integer := 1;
    v_offset integer := 0;
    v_chunk_size integer;
    v_rows jsonb;
BEGIN
    WHILE v_offset < c_total_rows LOOP
        v_chunk_size := LEAST(10000, c_total_rows - v_offset);
        SELECT jsonb_agg(
                   jsonb_build_object(
                       'dbid', 16384,
                       'userid', 19000,
                       'queryid', 200,
                       'qualid', raw_row,
                       'qualnodeid', raw_row,
                       'lrelid', 20001,
                       'lattnum', 2,
                       'opno', 98,
                       'operatorName', 'equal',
                       'operatorCommutator', 99,
                       'btreeStrategy', 3,
                       'rrelid', NULL,
                       'rattnum', NULL,
                       'occurences', 1,
                       'executionCount', 1,
                       'nbfiltered', 0,
                       'evalType', 'f',
                       'isJoin', false
                   ) ORDER BY raw_row
               )
          INTO v_rows
          FROM generate_series(
              v_offset + 1,
              v_offset + v_chunk_size
          ) AS generated(raw_row);

        IF NOT advisor_ingest.ingest_join_chunk(
            'test-source',
            v_batch_id,
            '2026-07-26 02:00:00+00'::timestamptz,
            c_total_rows,
            v_chunk_no,
            v_offset,
            v_offset + v_chunk_size = c_total_rows,
            v_rows
        ) THEN
            RAISE EXCEPTION 'large JOIN chunk unexpectedly became a no-op';
        END IF;
        v_offset := v_offset + v_chunk_size;
        v_chunk_no := v_chunk_no + 1;
    END LOOP;

    IF NOT advisor_ingest.finalize_join_batch('test-source', v_batch_id) THEN
        RAISE EXCEPTION 'large JOIN batch unexpectedly became a no-op';
    END IF;
END
$large_chunk_transport$;
RESET SESSION AUTHORIZATION;

DO $large_chunk_result$
DECLARE
    v_server_id integer;
BEGIN
    SELECT id INTO STRICT v_server_id
      FROM "PoWA".powa_servers
     WHERE alias = 'test-source';
    IF (SELECT row_count
          FROM advisor_ingest.join_snapshot_batches
         WHERE server_id = v_server_id
           AND batch_id = 9100000000000000015) <> 25001
       OR (SELECT count(*)
             FROM advisor_ingest.join_predicate_samples
            WHERE server_id = v_server_id
              AND batch_id = 9100000000000000015) <> 25001
       OR EXISTS (
           SELECT 1
             FROM advisor_ingest.join_batch_staging
            WHERE server_id = v_server_id
              AND batch_id = 9100000000000000015
       ) THEN
        RAISE EXCEPTION '25,001-row JOIN transport/finalization mismatch';
    END IF;
END
$large_chunk_result$;

ROLLBACK;
