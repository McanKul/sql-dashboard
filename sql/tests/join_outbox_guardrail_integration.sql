\set ON_ERROR_STOP on

-- This fixture is safe on an existing source volume: every synthetic row and
-- every SET LOCAL value is rolled back.  The fixed high batch id avoids a
-- non-transactional identity-sequence increment.
BEGIN;
SELECT pg_advisory_xact_lock(
    pg_catalog.hashtextextended('postgresql-advisor:join-outbox-guardrail-test', 0)
);

DO $capture_order$
DECLARE
    definition text := pg_get_functiondef(
        'advisor_join.capture_and_reset()'::regprocedure
    );
    guard_position integer;
    insert_position integer;
BEGIN
    guard_position := strpos(
        definition,
        'PERFORM advisor_join.assert_outbox_within_limits()'
    );
    insert_position := strpos(
        definition,
        'INSERT INTO advisor_join.outbox_batches'
    );
    IF guard_position = 0 OR insert_position = 0 OR guard_position >= insert_position THEN
        RAISE EXCEPTION 'outbox guard must run before the first capture insert';
    END IF;
END
$capture_order$;

SET LOCAL advisor_join.max_outbox_rows = 'not-an-integer';
DO $invalid_setting$
BEGIN
    BEGIN
        PERFORM advisor_join.assert_outbox_within_limits();
        RAISE EXCEPTION 'invalid outbox setting was accepted';
    EXCEPTION
        WHEN SQLSTATE '22023' THEN NULL;
    END;
END
$invalid_setting$;

SET LOCAL advisor_join.max_outbox_rows = '1000000';
SET LOCAL advisor_join.max_outbox_bytes = '1073741824';
SET LOCAL advisor_join.max_outbox_age_seconds = '604801';
DO $out_of_range_setting$
BEGIN
    BEGIN
        PERFORM advisor_join.assert_outbox_within_limits();
        RAISE EXCEPTION 'out-of-range outbox setting was accepted';
    EXCEPTION
        WHEN SQLSTATE '22023' THEN NULL;
    END;
END
$out_of_range_setting$;

SET LOCAL advisor_join.max_outbox_rows = '1';
SET LOCAL advisor_join.max_outbox_bytes = '1099511627776';
SET LOCAL advisor_join.max_outbox_age_seconds = '604800';

INSERT INTO advisor_join.outbox_batches (
    batch_id, captured_at, row_count, created_at
) OVERRIDING SYSTEM VALUE
VALUES (9223372036854770000, clock_timestamp(), 1, clock_timestamp());

CREATE TEMP TABLE guardrail_counts ON COMMIT DROP AS
SELECT count(*)::bigint AS before_capture
  FROM advisor_join.outbox_batches;

DO $row_limit$
DECLARE
    error_detail text;
    error_message text;
BEGIN
    BEGIN
        PERFORM advisor_join.capture_and_reset();
        RAISE EXCEPTION 'row watermark did not open the outbox circuit breaker';
    EXCEPTION
        WHEN SQLSTATE '54000' THEN
            GET STACKED DIAGNOSTICS
                error_detail = PG_EXCEPTION_DETAIL,
                error_message = MESSAGE_TEXT;
            IF error_detail NOT LIKE '%no JOIN rows were inserted and pg_qualstats was not reset%' THEN
                RAISE EXCEPTION 'outbox circuit-breaker detail is incomplete: %', error_detail;
            END IF;
            IF error_message NOT LIKE
               '%pending_batches=%pending_rows=%storage_bytes=%oldest_age_seconds=%' THEN
                RAISE EXCEPTION 'outbox circuit-breaker message lacks backlog metrics: %',
                    error_message;
            END IF;
    END;
END
$row_limit$;

DO $no_insert$
BEGIN
    IF (SELECT count(*) FROM advisor_join.outbox_batches)
       <> (SELECT before_capture FROM guardrail_counts) THEN
        RAISE EXCEPTION 'blocked capture changed the outbox';
    END IF;
END
$no_insert$;

SET LOCAL advisor_join.max_outbox_rows = '1000000000';
SET LOCAL advisor_join.max_outbox_bytes = '1';
DO $storage_limit$
BEGIN
    BEGIN
        PERFORM advisor_join.assert_outbox_within_limits();
        RAISE EXCEPTION 'storage watermark did not open the outbox circuit breaker';
    EXCEPTION
        WHEN SQLSTATE '54000' THEN NULL;
    END;
END
$storage_limit$;

SET LOCAL advisor_join.max_outbox_bytes = '1099511627776';
SET LOCAL advisor_join.max_outbox_age_seconds = '1';
UPDATE advisor_join.outbox_batches
   SET captured_at = clock_timestamp() - interval '2 seconds'
 WHERE batch_id = 9223372036854770000;
DO $age_limit$
BEGIN
    BEGIN
        PERFORM advisor_join.assert_outbox_within_limits();
        RAISE EXCEPTION 'age watermark did not open the outbox circuit breaker';
    EXCEPTION
        WHEN SQLSTATE '54000' THEN NULL;
    END;
END
$age_limit$;

-- Simulate the snapshotter ack boundary.  Physical table files may remain
-- allocated, but an empty live queue must close the circuit automatically.
DELETE FROM advisor_join.outbox_batches
 WHERE batch_id = 9223372036854770000;
SET LOCAL advisor_join.max_outbox_age_seconds = '604800';
SELECT advisor_join.assert_outbox_within_limits();

ROLLBACK;
