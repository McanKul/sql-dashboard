\set ON_ERROR_STOP on

-- Transport staging is deliberately separate from the public evidence tables.
-- A multi-chunk snapshot therefore becomes visible only after every chunk has
-- committed and the final completeness check succeeds.
CREATE TABLE IF NOT EXISTS advisor_ingest.join_batch_staging (
    server_id integer NOT NULL,
    batch_id bigint NOT NULL,
    captured_at timestamptz NOT NULL,
    expected_row_count integer NOT NULL
        CHECK (expected_row_count BETWEEN 0 AND 1000000),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (server_id, batch_id)
);

CREATE TABLE IF NOT EXISTS advisor_ingest.join_chunk_receipts (
    server_id integer NOT NULL,
    batch_id bigint NOT NULL,
    chunk_no integer NOT NULL CHECK (chunk_no BETWEEN 1 AND 1000000),
    row_offset integer NOT NULL CHECK (row_offset >= 0),
    row_count integer NOT NULL CHECK (row_count BETWEEN 0 AND 10000),
    is_last boolean NOT NULL,
    payload_bytes integer NOT NULL CHECK (payload_bytes BETWEEN 1 AND 8388608),
    payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (server_id, batch_id, chunk_no),
    UNIQUE (server_id, batch_id, row_offset),
    FOREIGN KEY (server_id, batch_id)
        REFERENCES advisor_ingest.join_batch_staging(server_id, batch_id)
        ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS join_chunk_receipts_last_idx
    ON advisor_ingest.join_chunk_receipts (server_id, batch_id)
    WHERE is_last;

CREATE TABLE IF NOT EXISTS advisor_ingest.join_predicate_staging (
    server_id integer NOT NULL,
    batch_id bigint NOT NULL,
    chunk_no integer NOT NULL,
    row_in_chunk integer NOT NULL CHECK (row_in_chunk BETWEEN 1 AND 10000),
    dbid oid NOT NULL,
    userid oid NOT NULL,
    queryid bigint NOT NULL,
    qualid bigint NOT NULL,
    qualnodeid bigint NOT NULL,
    lrelid oid,
    lattnum smallint,
    opno oid NOT NULL,
    operator_name text,
    operator_commutator oid,
    btree_strategy smallint,
    rrelid oid,
    rattnum smallint,
    occurences bigint NOT NULL CHECK (occurences >= 0),
    execution_count bigint NOT NULL CHECK (execution_count >= 0),
    nbfiltered bigint NOT NULL CHECK (nbfiltered >= 0),
    eval_type "char" NOT NULL,
    is_join boolean NOT NULL,
    PRIMARY KEY (server_id, batch_id, chunk_no, row_in_chunk),
    UNIQUE NULLS NOT DISTINCT (
        server_id, batch_id, dbid, userid, queryid, qualnodeid,
        opno, lrelid, lattnum, rrelid, rattnum
    ),
    FOREIGN KEY (server_id, batch_id, chunk_no)
        REFERENCES advisor_ingest.join_chunk_receipts(server_id, batch_id, chunk_no)
        ON DELETE CASCADE,
    CHECK (is_join = (lrelid IS NOT NULL AND rrelid IS NOT NULL)),
    CHECK (lrelid IS NOT NULL OR rrelid IS NOT NULL)
);

ALTER TABLE advisor_ingest.join_batch_staging OWNER TO CURRENT_USER;
ALTER TABLE advisor_ingest.join_chunk_receipts OWNER TO CURRENT_USER;
ALTER TABLE advisor_ingest.join_predicate_staging OWNER TO CURRENT_USER;
REVOKE ALL ON advisor_ingest.join_batch_staging FROM PUBLIC;
REVOKE ALL ON advisor_ingest.join_chunk_receipts FROM PUBLIC;
REVOKE ALL ON advisor_ingest.join_predicate_staging FROM PUBLIC;

-- The scoped purge is the daemon path.  Global indexes keep the administrative
-- purge bounded as well; neither path should require a full history scan.
CREATE INDEX IF NOT EXISTS join_snapshot_batches_source_retention_idx
    ON advisor_ingest.join_snapshot_batches (server_id, captured_at, batch_id);
CREATE INDEX IF NOT EXISTS join_snapshot_batches_retention_idx
    ON advisor_ingest.join_snapshot_batches (captured_at, server_id, batch_id);
CREATE INDEX IF NOT EXISTS join_predicate_samples_batch_purge_idx
    ON advisor_ingest.join_predicate_samples (server_id, batch_id);
CREATE INDEX IF NOT EXISTS join_batch_staging_retention_idx
    ON advisor_ingest.join_batch_staging (captured_at, server_id, batch_id);
CREATE INDEX IF NOT EXISTS join_batch_staging_source_retention_idx
    ON advisor_ingest.join_batch_staging (server_id, captured_at, batch_id);
CREATE INDEX IF NOT EXISTS index_candidate_evidence_source_retention_idx
    ON advisor.index_candidate_evidence (server_id, captured_at, candidate_id);
CREATE INDEX IF NOT EXISTS index_candidate_evidence_retention_idx
    ON advisor.index_candidate_evidence (captured_at, server_id, candidate_id);
CREATE INDEX IF NOT EXISTS index_candidates_source_retention_idx
    ON advisor.index_candidates (server_id, last_supported_at, candidate_id);
CREATE INDEX IF NOT EXISTS index_candidates_retention_idx
    ON advisor.index_candidates (last_supported_at, server_id, candidate_id);

CREATE OR REPLACE FUNCTION advisor_ingest.ingest_join_chunk(
    p_server_alias text,
    p_batch_id bigint,
    p_captured_at timestamptz,
    p_total_row_count integer,
    p_chunk_no integer,
    p_row_offset integer,
    p_is_last boolean,
    p_rows jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
    v_chunk_row_count integer;
    v_payload_bytes integer;
    v_payload_hash text;
    v_inserted integer;
    v_inserted_rows integer;
    v_final_captured_at timestamptz;
    v_final_row_count integer;
    v_staged advisor_ingest.join_batch_staging%ROWTYPE;
    v_receipt advisor_ingest.join_chunk_receipts%ROWTYPE;
BEGIN
    IF p_batch_id IS NULL OR p_batch_id < 1
       OR p_captured_at IS NULL
       OR p_total_row_count IS NULL
       OR p_total_row_count < 0 OR p_total_row_count > 1000000
       OR p_chunk_no IS NULL OR p_chunk_no < 1 OR p_chunk_no > 1000000
       OR p_row_offset IS NULL OR p_row_offset < 0
       OR p_is_last IS NULL
       OR p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
        RAISE EXCEPTION 'invalid JOIN snapshot chunk metadata';
    END IF;

    v_chunk_row_count := jsonb_array_length(p_rows);
    v_payload_bytes := octet_length(p_rows::text);
    IF v_chunk_row_count > 10000 OR v_payload_bytes > 8388608 THEN
        RAISE EXCEPTION 'JOIN snapshot chunk exceeds transport limits';
    END IF;
    IF p_total_row_count = 0 THEN
        IF p_chunk_no <> 1 OR p_row_offset <> 0
           OR v_chunk_row_count <> 0 OR NOT p_is_last THEN
            RAISE EXCEPTION 'invalid empty JOIN snapshot chunk';
        END IF;
    ELSIF v_chunk_row_count < 1
          OR p_row_offset + v_chunk_row_count > p_total_row_count
          OR p_is_last IS DISTINCT FROM (
              p_row_offset + v_chunk_row_count = p_total_row_count
          ) THEN
        RAISE EXCEPTION 'invalid JOIN snapshot chunk range';
    END IF;

    v_server_id := advisor_ingest.bound_join_server(p_server_alias);

    SELECT final_batch.captured_at, final_batch.row_count
      INTO v_final_captured_at, v_final_row_count
      FROM advisor_ingest.join_snapshot_batches AS final_batch
     WHERE final_batch.server_id = v_server_id
       AND final_batch.batch_id = p_batch_id;
    IF FOUND THEN
        IF v_final_captured_at IS DISTINCT FROM p_captured_at
           OR v_final_row_count IS DISTINCT FROM p_total_row_count THEN
            RAISE EXCEPTION 'finalized JOIN batch metadata conflict';
        END IF;
        RETURN false;
    END IF;

    INSERT INTO advisor_ingest.join_batch_staging (
        server_id, batch_id, captured_at, expected_row_count
    ) VALUES (
        v_server_id, p_batch_id, p_captured_at, p_total_row_count
    ) ON CONFLICT (server_id, batch_id) DO NOTHING;

    SELECT staged.* INTO STRICT v_staged
      FROM advisor_ingest.join_batch_staging AS staged
     WHERE staged.server_id = v_server_id
       AND staged.batch_id = p_batch_id
     FOR UPDATE;
    IF v_staged.captured_at IS DISTINCT FROM p_captured_at
       OR v_staged.expected_row_count IS DISTINCT FROM p_total_row_count THEN
        RAISE EXCEPTION 'staged JOIN batch metadata conflict';
    END IF;

    v_payload_hash := encode(
        sha256(convert_to(p_rows::text, 'UTF8')),
        'hex'
    );
    INSERT INTO advisor_ingest.join_chunk_receipts (
        server_id, batch_id, chunk_no, row_offset, row_count,
        is_last, payload_bytes, payload_hash
    ) VALUES (
        v_server_id, p_batch_id, p_chunk_no, p_row_offset,
        v_chunk_row_count, p_is_last, v_payload_bytes, v_payload_hash
    ) ON CONFLICT (server_id, batch_id, chunk_no) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT receipt.* INTO STRICT v_receipt
          FROM advisor_ingest.join_chunk_receipts AS receipt
         WHERE receipt.server_id = v_server_id
           AND receipt.batch_id = p_batch_id
           AND receipt.chunk_no = p_chunk_no;
        IF v_receipt.row_offset IS DISTINCT FROM p_row_offset
           OR v_receipt.row_count IS DISTINCT FROM v_chunk_row_count
           OR v_receipt.is_last IS DISTINCT FROM p_is_last
           OR v_receipt.payload_bytes IS DISTINCT FROM v_payload_bytes
           OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
            RAISE EXCEPTION 'staged JOIN chunk payload conflict';
        END IF;
        RETURN false;
    END IF;

    INSERT INTO advisor_ingest.join_predicate_staging (
        server_id, batch_id, chunk_no, row_in_chunk,
        dbid, userid, queryid, qualid, qualnodeid,
        lrelid, lattnum, opno, operator_name, operator_commutator,
        btree_strategy, rrelid, rattnum, occurences, execution_count,
        nbfiltered, eval_type, is_join
    )
    SELECT
        v_server_id, p_batch_id, p_chunk_no, element.ordinality::integer,
        item.dbid, item.userid, item.queryid, item.qualid, item.qualnodeid,
        item.lrelid, item.lattnum, item.opno,
        item."operatorName", item."operatorCommutator", item."btreeStrategy",
        item.rrelid, item.rattnum, item.occurences, item."executionCount",
        item.nbfiltered, substring(COALESCE(item."evalType", 'f'), 1, 1)::"char",
        item."isJoin"
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS element(value, ordinality)
    CROSS JOIN LATERAL jsonb_to_record(element.value) AS item(
        dbid oid, userid oid, queryid bigint, qualid bigint, qualnodeid bigint,
        lrelid oid, lattnum smallint, opno oid, "operatorName" text,
        "operatorCommutator" oid, "btreeStrategy" smallint,
        rrelid oid, rattnum smallint, occurences bigint,
        "executionCount" bigint, nbfiltered bigint, "evalType" text,
        "isJoin" boolean
    )
    WHERE item.queryid <> 0
      AND item.opno IS NOT NULL
      AND item.occurences >= 0
      AND item."executionCount" >= 0
      AND item.nbfiltered >= 0;
    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;
    IF v_inserted_rows <> v_chunk_row_count THEN
        RAISE EXCEPTION 'JOIN chunk contains invalid or duplicate rows';
    END IF;

    UPDATE advisor_ingest.join_batch_staging
       SET updated_at = clock_timestamp()
     WHERE server_id = v_server_id AND batch_id = p_batch_id;
    RETURN true;
END;
$$;

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
    v_inserted integer;
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
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted = 0 THEN
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

    INSERT INTO advisor_ingest.join_predicate_samples (
        server_id, batch_id, dbid, userid, queryid, qualid, qualnodeid,
        lrelid, lattnum, opno, operator_name, operator_commutator,
        btree_strategy, rrelid, rattnum, occurences, execution_count,
        nbfiltered, eval_type, is_join
    )
    SELECT
        staged.server_id, staged.batch_id, staged.dbid, staged.userid,
        staged.queryid, staged.qualid, staged.qualnodeid, staged.lrelid,
        staged.lattnum, staged.opno, staged.operator_name,
        staged.operator_commutator, staged.btree_strategy, staged.rrelid,
        staged.rattnum, staged.occurences, staged.execution_count,
        staged.nbfiltered, staged.eval_type, staged.is_join
    FROM advisor_ingest.join_predicate_staging AS staged
    WHERE staged.server_id = v_server_id
      AND staged.batch_id = p_batch_id
    ORDER BY staged.chunk_no, staged.row_in_chunk;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted <> v_header.expected_row_count THEN
        RAISE EXCEPTION 'JOIN finalization row count mismatch';
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

ALTER FUNCTION advisor_ingest.ingest_join_chunk(
    text, bigint, timestamptz, integer, integer, integer, boolean, jsonb
) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_ingest.finalize_join_batch(text, bigint) OWNER TO CURRENT_USER;
REVOKE ALL ON FUNCTION advisor_ingest.ingest_join_chunk(
    text, bigint, timestamptz, integer, integer, integer, boolean, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_ingest.finalize_join_batch(text, bigint) FROM PUBLIC;

-- Reapply the binder with the two new entry points so later credential
-- rotations receive exactly the same fail-closed envelope as existing roles.
CREATE OR REPLACE FUNCTION advisor_ingest.bind_join_source_role(
    p_role name,
    p_server_alias text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
BEGIN
    IF p_role IS NULL OR btrim(p_role::text) = '' THEN
        RAISE EXCEPTION 'join ingest role is required';
    END IF;
    IF p_server_alias IS NULL OR btrim(p_server_alias) = '' THEN
        RAISE EXCEPTION 'join source alias is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'join ingest role % does not exist', p_role;
    END IF;

    SELECT server.id INTO STRICT v_server_id
      FROM "PoWA".powa_servers AS server
     WHERE server.alias = p_server_alias;

    INSERT INTO advisor_ingest.join_source_role_bindings (
        role_name, server_id, bound_at
    ) VALUES (
        p_role, v_server_id, clock_timestamp()
    ) ON CONFLICT (role_name) DO UPDATE
       SET server_id = EXCLUDED.server_id,
           bound_at = EXCLUDED.bound_at;

    EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), p_role);
    EXECUTE format('REVOKE ALL ON SCHEMA advisor, advisor_ingest FROM %I', p_role);
    EXECUTE format(
        'REVOKE ALL ON ALL TABLES IN SCHEMA advisor, advisor_ingest FROM %I', p_role
    );
    EXECUTE format(
        'REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor, advisor_ingest FROM %I', p_role
    );
    EXECUTE format(
        'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA advisor, advisor_ingest FROM %I', p_role
    );
    EXECUTE format('GRANT USAGE ON SCHEMA advisor_ingest TO %I', p_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.ingest_join_batch(text,bigint,timestamptz,jsonb) TO %I',
        p_role
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.ingest_join_chunk(text,bigint,timestamptz,integer,integer,integer,boolean,jsonb) TO %I',
        p_role
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.finalize_join_batch(text,bigint) TO %I',
        p_role
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.record_join_error(text,text) TO %I',
        p_role
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION advisor_ingest.purge_join_source_history(text,interval) TO %I',
        p_role
    );
    RETURN v_server_id;
END;
$$;

-- Existing bindings predate this migration.  Grant only the two new entry
-- points; the original binder already constrained every other privilege.
DO $grant_existing_join_bindings$
DECLARE
    binding record;
BEGIN
    FOR binding IN
        SELECT source_binding.role_name
          FROM advisor_ingest.join_source_role_bindings AS source_binding
          JOIN pg_roles AS role ON role.rolname = source_binding.role_name
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION advisor_ingest.ingest_join_chunk(text,bigint,timestamptz,integer,integer,integer,boolean,jsonb) TO %I',
            binding.role_name
        );
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION advisor_ingest.finalize_join_batch(text,bigint) TO %I',
            binding.role_name
        );
    END LOOP;
END
$grant_existing_join_bindings$;

CREATE OR REPLACE FUNCTION advisor_ingest.purge_join_source_history(
    p_server_alias text,
    p_retention interval DEFAULT interval '30 days'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_server_id integer;
    v_deleted bigint;
BEGIN
    IF p_retention IS NULL
       OR p_retention < interval '1 day'
       OR p_retention > interval '365 days' THEN
        RAISE EXCEPTION 'join retention must be between 1 and 365 days';
    END IF;
    v_server_id := advisor_ingest.bound_join_server(p_server_alias);

    DELETE FROM advisor_ingest.join_batch_staging
     WHERE server_id = v_server_id
       AND captured_at < now() - p_retention;
    DELETE FROM advisor.index_candidate_evidence
     WHERE server_id = v_server_id
       AND captured_at < now() - p_retention;
    DELETE FROM advisor_ingest.join_snapshot_batches
     WHERE server_id = v_server_id
       AND captured_at < now() - p_retention;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    DELETE FROM advisor.index_candidates
     WHERE server_id = v_server_id
       AND last_supported_at < now() - p_retention;
    RETURN v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_ingest.purge_join_history(
    p_retention interval DEFAULT interval '30 days'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_deleted bigint;
BEGIN
    IF p_retention IS NULL
       OR p_retention < interval '1 day'
       OR p_retention > interval '365 days' THEN
        RAISE EXCEPTION 'join retention must be between 1 and 365 days';
    END IF;
    DELETE FROM advisor_ingest.join_batch_staging
     WHERE captured_at < now() - p_retention;
    DELETE FROM advisor.index_candidate_evidence
     WHERE captured_at < now() - p_retention;
    DELETE FROM advisor_ingest.join_snapshot_batches
     WHERE captured_at < now() - p_retention;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    DELETE FROM advisor.index_candidates
     WHERE last_supported_at < now() - p_retention;
    RETURN v_deleted;
END;
$$;

ALTER FUNCTION advisor_ingest.bind_join_source_role(name, text) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_ingest.purge_join_source_history(text, interval) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_ingest.purge_join_history(interval) OWNER TO CURRENT_USER;
REVOKE ALL ON FUNCTION advisor_ingest.bind_join_source_role(name, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_ingest.purge_join_history(interval) FROM PUBLIC;
