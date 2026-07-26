\set ON_ERROR_STOP on

-- pg_qualstats may expose multiple raw rows with the same repository natural
-- key in one reset boundary.  Transport identity is the immutable raw
-- (chunk_no, row_in_chunk) position; natural-key uniqueness belongs only to
-- the finalized evidence table after deterministic metric aggregation.
DO $drop_staging_natural_key$
DECLARE
    constraint_name name;
BEGIN
    FOR constraint_name IN
        SELECT constraint_record.conname
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
    LOOP
        EXECUTE format(
            'ALTER TABLE advisor_ingest.join_predicate_staging DROP CONSTRAINT %I',
            constraint_name
        );
    END LOOP;
END
$drop_staging_natural_key$;

CREATE OR REPLACE FUNCTION advisor_ingest.finalize_join_batch(
    p_server_alias text,
    p_batch_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
    v_header advisor_ingest.join_batch_staging%ROWTYPE;
    v_receipt_count bigint;
    v_received_rows bigint;
    v_ranges_complete boolean;
    v_last_count bigint;
    v_last_is_final boolean;
    v_staged_rows bigint;
    v_batch_inserted integer;
    v_expected_deduplicated_rows bigint;
    v_inserted_rows bigint;
    v_final_captured_at timestamptz;
    v_final_row_count integer;
BEGIN
    IF p_batch_id IS NULL OR p_batch_id < 1 THEN
        RAISE EXCEPTION 'invalid JOIN batch id';
    END IF;
    v_server_id := advisor_ingest.bound_join_server(p_server_alias);

    SELECT final_batch.captured_at, final_batch.row_count
      INTO v_final_captured_at, v_final_row_count
      FROM advisor_ingest.join_snapshot_batches AS final_batch
     WHERE final_batch.server_id = v_server_id
       AND final_batch.batch_id = p_batch_id;
    IF FOUND THEN
        DELETE FROM advisor_ingest.join_batch_staging
         WHERE server_id = v_server_id AND batch_id = p_batch_id;
        RETURN false;
    END IF;

    SELECT staged.* INTO v_header
      FROM advisor_ingest.join_batch_staging AS staged
     WHERE staged.server_id = v_server_id
       AND staged.batch_id = p_batch_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOIN batch has no staged chunks';
    END IF;

    WITH ordered AS (
        SELECT
            receipt.*,
            row_number() OVER (ORDER BY receipt.chunk_no) AS ordinal_chunk,
            COALESCE(
                lag(receipt.row_offset + receipt.row_count)
                    OVER (ORDER BY receipt.chunk_no),
                0
            ) AS expected_offset,
            max(receipt.chunk_no) OVER () AS final_chunk_no
        FROM advisor_ingest.join_chunk_receipts AS receipt
        WHERE receipt.server_id = v_server_id
          AND receipt.batch_id = p_batch_id
    )
    SELECT
        count(*),
        COALESCE(sum(row_count), 0),
        COALESCE(bool_and(
            chunk_no = ordinal_chunk
            AND row_offset = expected_offset
        ), false),
        count(*) FILTER (WHERE is_last),
        COALESCE(bool_and(
            NOT is_last OR (
                chunk_no = final_chunk_no
                AND row_offset + row_count = v_header.expected_row_count
            )
        ), false)
      INTO v_receipt_count, v_received_rows, v_ranges_complete,
           v_last_count, v_last_is_final
      FROM ordered;

    SELECT count(*) INTO v_staged_rows
      FROM advisor_ingest.join_predicate_staging AS staged
     WHERE staged.server_id = v_server_id
       AND staged.batch_id = p_batch_id;

    IF v_receipt_count < 1
       OR v_received_rows <> v_header.expected_row_count
       OR v_staged_rows <> v_header.expected_row_count
       OR NOT v_ranges_complete
       OR v_last_count <> 1
       OR NOT v_last_is_final THEN
        RAISE EXCEPTION 'JOIN batch is incomplete or has non-contiguous chunks';
    END IF;

    INSERT INTO advisor_ingest.join_snapshot_batches (
        server_id, batch_id, captured_at, row_count
    ) VALUES (
        v_server_id, p_batch_id, v_header.captured_at,
        v_header.expected_row_count
    ) ON CONFLICT (server_id, batch_id) DO NOTHING;
    GET DIAGNOSTICS v_batch_inserted = ROW_COUNT;
    IF v_batch_inserted = 0 THEN
        SELECT final_batch.captured_at, final_batch.row_count
          INTO STRICT v_final_captured_at, v_final_row_count
          FROM advisor_ingest.join_snapshot_batches AS final_batch
         WHERE final_batch.server_id = v_server_id
           AND final_batch.batch_id = p_batch_id;
        IF v_final_captured_at IS DISTINCT FROM v_header.captured_at
           OR v_final_row_count IS DISTINCT FROM v_header.expected_row_count THEN
            RAISE EXCEPTION 'finalized JOIN batch metadata conflict';
        END IF;
        DELETE FROM advisor_ingest.join_batch_staging
         WHERE server_id = v_server_id AND batch_id = p_batch_id;
        RETURN false;
    END IF;

    -- GROUP BY uses NULLS NOT DISTINCT semantics for the nullable relation
    -- columns, matching the final table's natural UNIQUE key.  Transport row
    -- count remains raw evidence cardinality; only the finalized samples are
    -- deduplicated.  Metadata representatives use stable minima and all three
    -- non-negative counters are summed, never arbitrarily discarded.
    BEGIN
        WITH aggregated AS MATERIALIZED (
            SELECT
                staged.server_id,
                staged.batch_id,
                staged.dbid,
                staged.userid,
                staged.queryid,
                min(staged.qualid) AS qualid,
                staged.qualnodeid,
                staged.lrelid,
                staged.lattnum,
                staged.opno,
                min(staged.operator_name) AS operator_name,
                min(staged.operator_commutator) AS operator_commutator,
                min(staged.btree_strategy) AS btree_strategy,
                staged.rrelid,
                staged.rattnum,
                sum(staged.occurences::numeric) AS occurences,
                sum(staged.execution_count::numeric) AS execution_count,
                sum(staged.nbfiltered::numeric) AS nbfiltered,
                min(staged.eval_type) AS eval_type,
                bool_or(staged.is_join) AS is_join
            FROM advisor_ingest.join_predicate_staging AS staged
            WHERE staged.server_id = v_server_id
              AND staged.batch_id = p_batch_id
            GROUP BY
                staged.server_id, staged.batch_id, staged.dbid, staged.userid,
                staged.queryid, staged.qualnodeid, staged.lrelid,
                staged.lattnum, staged.opno, staged.rrelid, staged.rattnum
        ), inserted AS (
            INSERT INTO advisor_ingest.join_predicate_samples (
                server_id, batch_id, dbid, userid, queryid, qualid, qualnodeid,
                lrelid, lattnum, opno, operator_name, operator_commutator,
                btree_strategy, rrelid, rattnum, occurences, execution_count,
                nbfiltered, eval_type, is_join
            )
            SELECT
                aggregated.server_id,
                aggregated.batch_id,
                aggregated.dbid,
                aggregated.userid,
                aggregated.queryid,
                aggregated.qualid,
                aggregated.qualnodeid,
                aggregated.lrelid,
                aggregated.lattnum,
                aggregated.opno,
                aggregated.operator_name,
                aggregated.operator_commutator,
                aggregated.btree_strategy,
                aggregated.rrelid,
                aggregated.rattnum,
                aggregated.occurences::bigint,
                aggregated.execution_count::bigint,
                aggregated.nbfiltered::bigint,
                aggregated.eval_type,
                aggregated.is_join
            FROM aggregated
            ORDER BY
                aggregated.dbid, aggregated.userid, aggregated.queryid,
                aggregated.qualnodeid, aggregated.opno,
                aggregated.lrelid NULLS FIRST, aggregated.lattnum NULLS FIRST,
                aggregated.rrelid NULLS FIRST, aggregated.rattnum NULLS FIRST
            RETURNING 1
        )
        SELECT
            (SELECT count(*) FROM aggregated),
            (SELECT count(*) FROM inserted)
          INTO v_expected_deduplicated_rows, v_inserted_rows;
    EXCEPTION
        WHEN numeric_value_out_of_range THEN
            RAISE EXCEPTION
                'JOIN finalization metric overflow for source %, batch %',
                p_server_alias,
                p_batch_id
                USING ERRCODE = '22003';
    END;

    IF v_expected_deduplicated_rows > v_header.expected_row_count
       OR v_inserted_rows <> v_expected_deduplicated_rows THEN
        RAISE EXCEPTION
            'JOIN finalization deduplicated row count mismatch: expected %, inserted %',
            v_expected_deduplicated_rows,
            v_inserted_rows;
    END IF;

    PERFORM advisor_ingest.refresh_candidates(v_server_id, p_batch_id);

    INSERT INTO advisor_ingest.join_source_status (
        server_id, status, last_capture_at, last_ingest_at,
        last_batch_id, last_row_count, last_error, updated_at
    ) VALUES (
        v_server_id, 'HEALTHY', v_header.captured_at, clock_timestamp(),
        p_batch_id, v_header.expected_row_count, NULL, clock_timestamp()
    ) ON CONFLICT (server_id) DO UPDATE
       SET status = 'HEALTHY',
           last_capture_at = GREATEST(
               advisor_ingest.join_source_status.last_capture_at,
               EXCLUDED.last_capture_at
           ),
           last_ingest_at = EXCLUDED.last_ingest_at,
           last_batch_id = GREATEST(
               advisor_ingest.join_source_status.last_batch_id,
               EXCLUDED.last_batch_id
           ),
           last_row_count = CASE
               WHEN advisor_ingest.join_source_status.last_batch_id IS NULL
                 OR EXCLUDED.last_batch_id
                    >= advisor_ingest.join_source_status.last_batch_id
                   THEN EXCLUDED.last_row_count
               ELSE advisor_ingest.join_source_status.last_row_count
           END,
           last_error = NULL,
           updated_at = EXCLUDED.updated_at;

    DELETE FROM advisor_ingest.join_batch_staging
     WHERE server_id = v_server_id AND batch_id = p_batch_id;
    RETURN true;
END;
$$;

ALTER FUNCTION advisor_ingest.finalize_join_batch(text, bigint) OWNER TO CURRENT_USER;
REVOKE ALL ON FUNCTION advisor_ingest.finalize_join_batch(text, bigint) FROM PUBLIC;

-- Keep the rolling-upgrade entry point lossless as well.  Older daemons send
-- one atomic JSON array instead of chunks, but pg_qualstats can expose the
-- same final natural key more than once there too.  The parent row_count
-- remains the raw array cardinality while public samples contain one summed,
-- deterministic row per natural key.
CREATE OR REPLACE FUNCTION advisor_ingest.ingest_join_batch(
    p_server_alias text,
    p_batch_id bigint,
    p_captured_at timestamptz,
    p_rows jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
    v_batch_inserted integer;
    v_row_count integer;
    v_valid_rows bigint;
    v_expected_deduplicated_rows bigint;
    v_inserted_rows bigint;
    v_final_captured_at timestamptz;
    v_final_row_count integer;
BEGIN
    IF p_batch_id IS NULL
       OR p_batch_id < 1
       OR p_captured_at IS NULL
       OR p_rows IS NULL
       OR jsonb_typeof(p_rows) <> 'array' THEN
        RAISE EXCEPTION 'invalid join snapshot batch';
    END IF;
    v_row_count := jsonb_array_length(p_rows);
    IF v_row_count > 50000 THEN
        RAISE EXCEPTION 'join snapshot batch exceeds 50000 rows';
    END IF;

    v_server_id := advisor_ingest.bound_join_server(p_server_alias);

    INSERT INTO advisor_ingest.join_snapshot_batches (
        server_id, batch_id, captured_at, row_count
    ) VALUES (
        v_server_id, p_batch_id, p_captured_at, v_row_count
    ) ON CONFLICT (server_id, batch_id) DO NOTHING;
    GET DIAGNOSTICS v_batch_inserted = ROW_COUNT;

    IF v_batch_inserted = 0 THEN
        SELECT final_batch.captured_at, final_batch.row_count
          INTO STRICT v_final_captured_at, v_final_row_count
          FROM advisor_ingest.join_snapshot_batches AS final_batch
         WHERE final_batch.server_id = v_server_id
           AND final_batch.batch_id = p_batch_id;
        IF v_final_captured_at IS DISTINCT FROM p_captured_at
           OR v_final_row_count IS DISTINCT FROM v_row_count THEN
            RAISE EXCEPTION 'finalized JOIN batch metadata conflict';
        END IF;
        RETURN false;
    END IF;

    BEGIN
        WITH parsed AS MATERIALIZED (
            SELECT parsed_row.*
            FROM jsonb_to_recordset(p_rows) AS parsed_row(
                dbid oid, userid oid, queryid bigint, qualid bigint,
                qualnodeid bigint, lrelid oid, lattnum smallint, opno oid,
                "operatorName" text, "operatorCommutator" oid,
                "btreeStrategy" smallint, rrelid oid, rattnum smallint,
                occurences bigint, "executionCount" bigint,
                nbfiltered bigint, "evalType" text, "isJoin" boolean
            )
        ), valid AS MATERIALIZED (
            SELECT parsed.*
            FROM parsed
            WHERE parsed.queryid <> 0
              AND parsed.opno IS NOT NULL
              AND parsed.occurences >= 0
              AND parsed."executionCount" >= 0
              AND parsed.nbfiltered >= 0
        ), aggregated AS MATERIALIZED (
            SELECT
                valid.dbid,
                valid.userid,
                valid.queryid,
                min(valid.qualid) AS qualid,
                valid.qualnodeid,
                valid.lrelid,
                valid.lattnum,
                valid.opno,
                min(valid."operatorName") AS operator_name,
                min(valid."operatorCommutator") AS operator_commutator,
                min(valid."btreeStrategy") AS btree_strategy,
                valid.rrelid,
                valid.rattnum,
                sum(valid.occurences::numeric) AS occurences,
                sum(valid."executionCount"::numeric) AS execution_count,
                sum(valid.nbfiltered::numeric) AS nbfiltered,
                min(substring(COALESCE(valid."evalType", 'f'), 1, 1)::"char")
                    AS eval_type,
                bool_or(valid."isJoin") AS is_join
            FROM valid
            GROUP BY
                valid.dbid, valid.userid, valid.queryid, valid.qualnodeid,
                valid.lrelid, valid.lattnum, valid.opno,
                valid.rrelid, valid.rattnum
        ), inserted AS (
            INSERT INTO advisor_ingest.join_predicate_samples (
                server_id, batch_id, dbid, userid, queryid, qualid, qualnodeid,
                lrelid, lattnum, opno, operator_name, operator_commutator,
                btree_strategy, rrelid, rattnum, occurences, execution_count,
                nbfiltered, eval_type, is_join
            )
            SELECT
                v_server_id,
                p_batch_id,
                aggregated.dbid,
                aggregated.userid,
                aggregated.queryid,
                aggregated.qualid,
                aggregated.qualnodeid,
                aggregated.lrelid,
                aggregated.lattnum,
                aggregated.opno,
                aggregated.operator_name,
                aggregated.operator_commutator,
                aggregated.btree_strategy,
                aggregated.rrelid,
                aggregated.rattnum,
                aggregated.occurences::bigint,
                aggregated.execution_count::bigint,
                aggregated.nbfiltered::bigint,
                aggregated.eval_type,
                aggregated.is_join
            FROM aggregated
            ORDER BY
                aggregated.dbid, aggregated.userid, aggregated.queryid,
                aggregated.qualnodeid, aggregated.opno,
                aggregated.lrelid NULLS FIRST, aggregated.lattnum NULLS FIRST,
                aggregated.rrelid NULLS FIRST, aggregated.rattnum NULLS FIRST
            RETURNING 1
        )
        SELECT
            (SELECT count(*) FROM valid),
            (SELECT count(*) FROM aggregated),
            (SELECT count(*) FROM inserted)
          INTO v_valid_rows, v_expected_deduplicated_rows, v_inserted_rows;
    EXCEPTION
        WHEN numeric_value_out_of_range THEN
            RAISE EXCEPTION
                'JOIN legacy finalization metric overflow for source %, batch %',
                p_server_alias,
                p_batch_id
                USING ERRCODE = '22003';
    END;

    IF v_valid_rows <> v_row_count THEN
        RAISE EXCEPTION 'JOIN batch contains invalid rows';
    END IF;
    IF v_expected_deduplicated_rows > v_row_count
       OR v_inserted_rows <> v_expected_deduplicated_rows THEN
        RAISE EXCEPTION
            'JOIN legacy finalization deduplicated row count mismatch: expected %, inserted %',
            v_expected_deduplicated_rows,
            v_inserted_rows;
    END IF;

    PERFORM advisor_ingest.refresh_candidates(v_server_id, p_batch_id);

    INSERT INTO advisor_ingest.join_source_status (
        server_id, status, last_capture_at, last_ingest_at,
        last_batch_id, last_row_count, last_error, updated_at
    ) VALUES (
        v_server_id, 'HEALTHY', p_captured_at, clock_timestamp(),
        p_batch_id, v_row_count, NULL, clock_timestamp()
    ) ON CONFLICT (server_id) DO UPDATE
       SET status = 'HEALTHY',
           last_capture_at = GREATEST(
               advisor_ingest.join_source_status.last_capture_at,
               EXCLUDED.last_capture_at
           ),
           last_ingest_at = EXCLUDED.last_ingest_at,
           last_batch_id = GREATEST(
               advisor_ingest.join_source_status.last_batch_id,
               EXCLUDED.last_batch_id
           ),
           last_row_count = CASE
               WHEN advisor_ingest.join_source_status.last_batch_id IS NULL
                 OR EXCLUDED.last_batch_id
                    >= advisor_ingest.join_source_status.last_batch_id
                   THEN EXCLUDED.last_row_count
               ELSE advisor_ingest.join_source_status.last_row_count
           END,
           last_error = NULL,
           updated_at = EXCLUDED.updated_at;

    RETURN true;
END;
$$;

ALTER FUNCTION advisor_ingest.ingest_join_batch(
    text, bigint, timestamptz, jsonb
) OWNER TO CURRENT_USER;
REVOKE ALL ON FUNCTION advisor_ingest.ingest_join_batch(
    text, bigint, timestamptz, jsonb
) FROM PUBLIC;
