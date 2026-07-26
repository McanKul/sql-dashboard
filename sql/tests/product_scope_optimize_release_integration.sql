\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
    result record;
BEGIN
    INSERT INTO "PoWA".powa_all_tables_history_current (srvid, dbid, relid, record)
    VALUES
        (
            1, 4000000000::oid, 4000000001::oid,
            jsonb_populate_record(
                NULL::"PoWA".powa_all_tables_history_record,
                jsonb_build_object(
                    'ts', clock_timestamp() - interval '60 seconds',
                    'n_tup_ins', 100,
                    'n_tup_upd', 40,
                    'n_tup_del', 10
                )
            )
        ),
        (
            1, 4000000000::oid, 4000000001::oid,
            jsonb_populate_record(
                NULL::"PoWA".powa_all_tables_history_record,
                jsonb_build_object(
                    'ts', clock_timestamp(),
                    'n_tup_ins', 130,
                    'n_tup_upd', 60,
                    'n_tup_del', 20
                )
            )
        );

    SELECT * INTO STRICT result
    FROM advisor.table_write_metrics(
        interval '5 minutes',
        1,
        4000000000::oid,
        ARRAY[4000000001::oid]
    );

    IF result.write_rows <> 60 THEN
        RAISE EXCEPTION 'write delta mismatch: %', result.write_rows;
    END IF;
    IF result.observed_to - result.observed_from < interval '59 seconds' THEN
        RAISE EXCEPTION 'single delta observation window was inflated: % - %',
            result.observed_from, result.observed_to;
    END IF;
    IF result.writes_per_hour NOT BETWEEN 3500 AND 3700 THEN
        RAISE EXCEPTION 'writes/hour did not use predecessor interval: %',
            result.writes_per_hour;
    END IF;

    INSERT INTO "PoWA".powa_all_tables_history_current (srvid, dbid, relid, record)
    VALUES
        (
            1, 4000000000::oid, 4000000002::oid,
            jsonb_populate_record(
                NULL::"PoWA".powa_all_tables_history_record,
                jsonb_build_object(
                    'ts', clock_timestamp() - interval '60 seconds',
                    'n_tup_ins', 100, 'n_tup_upd', 0, 'n_tup_del', 0
                )
            )
        ),
        (
            1, 4000000000::oid, 4000000002::oid,
            jsonb_populate_record(
                NULL::"PoWA".powa_all_tables_history_record,
                jsonb_build_object(
                    'ts', clock_timestamp(),
                    'n_tup_ins', 5, 'n_tup_upd', 0, 'n_tup_del', 0
                )
            )
        );

    SELECT * INTO STRICT result
    FROM advisor.table_write_metrics(
        interval '5 minutes', 1, 4000000000::oid,
        ARRAY[4000000002::oid]
    );
    IF result.write_rows <> 5 OR NOT result.reset_detected THEN
        RAISE EXCEPTION 'counter reset was not preserved: rows=%, reset=%',
            result.write_rows, result.reset_detected;
    END IF;
END
$test$;

SET LOCAL ROLE advisor_api;
DO $grant_test$
BEGIN
    IF NOT has_function_privilege(
        current_user,
        'advisor.query_trend(timestamp with time zone,interval,integer,oid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'advisor_api cannot execute the scoped query_trend overload';
    END IF;
END
$grant_test$;

-- A deliberately absent exact scope keeps the assertion deterministic while
-- forcing PostgreSQL to resolve and execute the new four-argument overload.
SELECT count(*) AS scoped_trend_rows
FROM advisor.query_trend(
    clock_timestamp() - interval '5 minutes',
    interval '1 minute',
    2147483647,
    4000000000::oid
);

SELECT current_migration, applied_count, latest_applied_at
FROM advisor.release_info();
RESET ROLE;

ROLLBACK;
