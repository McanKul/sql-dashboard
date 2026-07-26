\set ON_ERROR_STOP on

\if :{?collector_user}
\else
\set collector_user powa_collector
\endif
\if :{?join_reader_user}
\else
\set join_reader_user advisor_join_reader
\endif

-- Source-side durable outbox for pg_qualstats rows that stock PoWA does not
-- persist.  The PoWA collector calls capture_and_reset() as its query_cleanup,
-- so capture and pg_qualstats_reset() share one source transaction.
CREATE SCHEMA IF NOT EXISTS advisor_join;
ALTER SCHEMA advisor_join OWNER TO CURRENT_USER;
REVOKE ALL ON SCHEMA advisor_join FROM PUBLIC;

-- Keep future outbox objects fail-closed as this schema evolves.  Current
-- objects are revoked explicitly below; default privileges cover later
-- migrations created by the same bootstrap owner.
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor_join
    REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor_join
    REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA advisor_join
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE IF NOT EXISTS advisor_join.outbox_batches (
    batch_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    row_count integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS advisor_join.outbox_rows (
    batch_id bigint NOT NULL REFERENCES advisor_join.outbox_batches(batch_id) ON DELETE CASCADE,
    row_no bigint GENERATED ALWAYS AS IDENTITY,
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
    occurences bigint NOT NULL,
    execution_count bigint NOT NULL,
    nbfiltered bigint NOT NULL,
    eval_type "char" NOT NULL,
    is_join boolean NOT NULL,
    PRIMARY KEY (batch_id, row_no),
    CHECK (is_join = (lrelid IS NOT NULL AND rrelid IS NOT NULL)),
    CHECK (lrelid IS NOT NULL OR rrelid IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS outbox_rows_query_idx
    ON advisor_join.outbox_rows (dbid, queryid, batch_id);

CREATE INDEX IF NOT EXISTS outbox_batches_retention_idx
    ON advisor_join.outbox_batches (captured_at, batch_id);

ALTER TABLE advisor_join.outbox_batches OWNER TO CURRENT_USER;
ALTER TABLE advisor_join.outbox_rows OWNER TO CURRENT_USER;
REVOKE ALL ON ALL TABLES IN SCHEMA advisor_join FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor_join FROM PUBLIC;

-- Protect the monitored primary from an indefinitely growing telemetry outbox.
-- The guard runs before every capture/reset boundary.  A failed repository or
-- snapshotter can therefore make JOIN evidence incomplete, but can never keep
-- consuming source disk without an explicit, visible collector error.
CREATE OR REPLACE FUNCTION advisor_join.assert_outbox_within_limits()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_join
AS $$
DECLARE
    v_max_rows_raw text := COALESCE(
        current_setting('advisor_join.max_outbox_rows', true),
        '1000000'
    );
    v_max_bytes_raw text := COALESCE(
        current_setting('advisor_join.max_outbox_bytes', true),
        '1073741824'
    );
    v_max_age_raw text := COALESCE(
        current_setting('advisor_join.max_outbox_age_seconds', true),
        '300'
    );
    v_max_rows bigint;
    v_max_bytes bigint;
    v_max_age_seconds bigint;
    v_pending_batches bigint;
    v_pending_rows bigint;
    v_storage_bytes bigint := 0;
    v_oldest_captured_at timestamptz;
    v_oldest_age_seconds double precision := 0;
    v_reason text;
BEGIN
    IF v_max_rows_raw !~ '^[0-9]{1,19}$' THEN
        RAISE EXCEPTION 'advisor_join.max_outbox_rows must be a base-10 integer'
            USING ERRCODE = '22023';
    END IF;
    IF v_max_bytes_raw !~ '^[0-9]{1,19}$' THEN
        RAISE EXCEPTION 'advisor_join.max_outbox_bytes must be a base-10 integer'
            USING ERRCODE = '22023';
    END IF;
    IF v_max_age_raw !~ '^[0-9]{1,19}$' THEN
        RAISE EXCEPTION 'advisor_join.max_outbox_age_seconds must be a base-10 integer'
            USING ERRCODE = '22023';
    END IF;

    BEGIN
        v_max_rows := v_max_rows_raw::bigint;
        v_max_bytes := v_max_bytes_raw::bigint;
        v_max_age_seconds := v_max_age_raw::bigint;
    EXCEPTION
        WHEN numeric_value_out_of_range THEN
            RAISE EXCEPTION 'advisor_join outbox limit is outside bigint range'
                USING ERRCODE = '22023';
    END;

    IF v_max_rows NOT BETWEEN 1 AND 1000000000 THEN
        RAISE EXCEPTION 'advisor_join.max_outbox_rows must be between 1 and 1000000000'
            USING ERRCODE = '22023';
    END IF;
    IF v_max_bytes NOT BETWEEN 1 AND 1099511627776 THEN
        RAISE EXCEPTION 'advisor_join.max_outbox_bytes must be between 1 and 1099511627776'
            USING ERRCODE = '22023';
    END IF;
    IF v_max_age_seconds NOT BETWEEN 1 AND 604800 THEN
        RAISE EXCEPTION 'advisor_join.max_outbox_age_seconds must be between 1 and 604800'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        count(*)::bigint,
        COALESCE(sum(queued.row_count::bigint), 0),
        min(queued.captured_at)
      INTO v_pending_batches, v_pending_rows, v_oldest_captured_at
      FROM advisor_join.outbox_batches AS queued;

    -- Relation size includes indexes and dead space, which is exactly the disk
    -- pressure that matters on the source.  Once every live batch is acked the
    -- effective backlog size becomes zero, so a drained queue always recovers
    -- without requiring VACUUM FULL merely to close the circuit breaker.
    IF v_pending_batches > 0 THEN
        v_storage_bytes :=
            pg_total_relation_size('advisor_join.outbox_batches'::regclass)
            + pg_total_relation_size('advisor_join.outbox_rows'::regclass);
    END IF;
    IF v_oldest_captured_at IS NOT NULL THEN
        v_oldest_age_seconds := GREATEST(
            extract(epoch FROM clock_timestamp() - v_oldest_captured_at),
            0
        );
    END IF;

    v_reason := concat_ws(
        ', ',
        CASE WHEN v_pending_rows >= v_max_rows
            THEN format('rows=%s limit=%s', v_pending_rows, v_max_rows) END,
        CASE WHEN v_storage_bytes >= v_max_bytes
            THEN format('bytes=%s limit=%s', v_storage_bytes, v_max_bytes) END,
        CASE WHEN v_oldest_age_seconds >= v_max_age_seconds
            THEN format(
                'oldest_age_seconds=%s limit=%s',
                ceil(v_oldest_age_seconds)::bigint,
                v_max_age_seconds
            ) END
    );

    IF v_reason <> '' THEN
        -- Keep every measurement in MESSAGE because remote collector drivers
        -- do not all preserve PostgreSQL DETAIL/HINT fields verbatim.
        RAISE EXCEPTION
            'JOIN outbox circuit breaker open: %; pending_batches=% pending_rows=% storage_bytes=% oldest_age_seconds=%',
            v_reason,
            v_pending_batches,
            v_pending_rows,
            v_storage_bytes,
            ceil(v_oldest_age_seconds)::bigint
            USING
                ERRCODE = '54000',
                DETAIL = format(
                    'pending_batches=%s pending_rows=%s storage_bytes=%s oldest_age_seconds=%s; no JOIN rows were inserted and pg_qualstats was not reset',
                    v_pending_batches,
                    v_pending_rows,
                    v_storage_bytes,
                    ceil(v_oldest_age_seconds)::bigint
                ),
                HINT = 'Restore the JOIN snapshotter/repository path and let it acknowledge the source backlog.';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_join.capture_and_reset()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_join
AS $$
DECLARE
    v_batch_id bigint;
    v_captured_at timestamptz := clock_timestamp();
    v_extension_schema text;
    v_rows integer;
BEGIN
    PERFORM advisor_join.assert_outbox_within_limits();

    SELECT n.nspname
      INTO STRICT v_extension_schema
      FROM pg_extension AS e
      JOIN pg_namespace AS n ON n.oid = e.extnamespace
     WHERE e.extname = 'pg_qualstats';

    INSERT INTO advisor_join.outbox_batches(captured_at)
    VALUES (v_captured_at)
    RETURNING batch_id INTO v_batch_id;

    EXECUTE format($capture$
        WITH raw AS MATERIALIZED (
            SELECT q.*
              FROM %I.pg_qualstats() AS q
             WHERE q.queryid <> 0
               AND (q.lrelid IS NOT NULL OR q.rrelid IS NOT NULL)
        ), join_queries AS (
            SELECT DISTINCT dbid, userid, queryid
              FROM raw
             WHERE lrelid IS NOT NULL AND rrelid IS NOT NULL
        )
        INSERT INTO advisor_join.outbox_rows (
            batch_id, dbid, userid, queryid, qualid, qualnodeid,
            lrelid, lattnum, opno, operator_name, operator_commutator,
            btree_strategy, rrelid, rattnum, occurences, execution_count,
            nbfiltered, eval_type, is_join
        )
        SELECT
            $1, q.dbid, q.userid, q.queryid, COALESCE(q.qualid, q.qualnodeid), q.qualnodeid,
            q.lrelid, q.lattnum, q.opno, operator.oprname,
            NULLIF(operator.oprcom, 0), strategy.btree_strategy,
            q.rrelid, q.rattnum, q.occurences, q.execution_count,
            q.nbfiltered, q.eval_type,
            q.lrelid IS NOT NULL AND q.rrelid IS NOT NULL
        FROM raw AS q
        JOIN join_queries AS jq USING (dbid, userid, queryid)
        LEFT JOIN pg_operator AS operator ON operator.oid = q.opno
        LEFT JOIN LATERAL (
            SELECT min(amop.amopstrategy)::smallint AS btree_strategy
              FROM pg_amop AS amop
              JOIN pg_opfamily AS family ON family.oid = amop.amopfamily
              JOIN pg_am AS access_method ON access_method.oid = family.opfmethod
             WHERE amop.amopopr = q.opno
               AND access_method.amname = 'btree'
               AND amop.amopstrategy BETWEEN 1 AND 5
        ) AS strategy ON true
    $capture$, v_extension_schema)
    USING v_batch_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    UPDATE advisor_join.outbox_batches
       SET row_count = v_rows
     WHERE batch_id = v_batch_id;

    EXECUTE format('SELECT %I.pg_qualstats_reset()', v_extension_schema);
END;
$$;

CREATE OR REPLACE FUNCTION advisor_join.fetch_batches(p_limit integer DEFAULT 20)
RETURNS TABLE (
    batch_id bigint,
    captured_at timestamptz,
    row_count integer,
    rows jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_join
AS $$
SELECT
    batch.batch_id,
    batch.captured_at,
    batch.row_count,
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'dbid', sample.dbid,
                'userid', sample.userid,
                'queryid', sample.queryid,
                'qualid', sample.qualid,
                'qualnodeid', sample.qualnodeid,
                'lrelid', sample.lrelid,
                'lattnum', sample.lattnum,
                'opno', sample.opno,
                'operatorName', sample.operator_name,
                'operatorCommutator', sample.operator_commutator,
                'btreeStrategy', sample.btree_strategy,
                'rrelid', sample.rrelid,
                'rattnum', sample.rattnum,
                'occurences', sample.occurences,
                'executionCount', sample.execution_count,
                'nbfiltered', sample.nbfiltered,
                'evalType', sample.eval_type,
                'isJoin', sample.is_join
            ) ORDER BY sample.row_no
        ) FILTER (WHERE sample.row_no IS NOT NULL),
        '[]'::jsonb
    ) AS rows
FROM (
    SELECT queued.*
     FROM advisor_join.outbox_batches AS queued
     ORDER BY queued.batch_id
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
) AS batch
LEFT JOIN advisor_join.outbox_rows AS sample USING (batch_id)
GROUP BY batch.batch_id, batch.captured_at, batch.row_count
ORDER BY batch.batch_id;
$$;

-- Metadata-only enumeration lets a worker isolate one broken batch without
-- materializing any payload or blocking later batches in the same poll cycle.
-- Unacknowledged batches are never aged out automatically: deletion remains
-- exclusively the post-finalize ack boundary.
CREATE OR REPLACE FUNCTION advisor_join.list_batch_headers(
    p_limit integer DEFAULT 20
)
RETURNS TABLE (
    batch_id bigint,
    captured_at timestamptz,
    total_row_count integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_join
AS $$
SELECT queued.batch_id, queued.captured_at, queued.row_count
  FROM advisor_join.outbox_batches AS queued
 ORDER BY queued.batch_id
 LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
$$;

-- Chunked transport keeps one capture/reset boundary as one durable source
-- batch while bounding every cross-database payload.  The caller advances the
-- logical row offset only after the preceding repository chunk commits.  Rows
-- in a committed outbox batch are immutable, therefore the same batch/offset
-- always produces the same chunk across retries.
CREATE OR REPLACE FUNCTION advisor_join.fetch_batch_chunk(
    p_batch_id bigint DEFAULT NULL,
    p_row_offset integer DEFAULT 0
)
RETURNS TABLE (
    batch_id bigint,
    captured_at timestamptz,
    total_row_count integer,
    row_offset integer,
    row_count integer,
    is_last boolean,
    payload_bytes integer,
    rows jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_join
AS $$
DECLARE
    v_batch_id bigint;
    v_captured_at timestamptz;
    v_total_row_count integer;
    v_limit integer;
    v_rows jsonb;
    v_payload_bytes integer;
    v_actual_rows integer;
    c_max_chunk_rows constant integer := 10000;
    c_max_chunk_bytes constant integer := 8388608;
BEGIN
    IF p_batch_id IS NOT NULL AND p_batch_id < 1 THEN
        RAISE EXCEPTION 'JOIN batch id must be positive';
    END IF;
    IF p_row_offset IS NULL OR p_row_offset < 0 THEN
        RAISE EXCEPTION 'JOIN row offset must be non-negative';
    END IF;

    IF p_batch_id IS NULL THEN
        SELECT queued.batch_id, queued.captured_at, queued.row_count
          INTO v_batch_id, v_captured_at, v_total_row_count
          FROM advisor_join.outbox_batches AS queued
         ORDER BY queued.batch_id
         LIMIT 1;
    ELSE
        SELECT queued.batch_id, queued.captured_at, queued.row_count
          INTO v_batch_id, v_captured_at, v_total_row_count
          FROM advisor_join.outbox_batches AS queued
         WHERE queued.batch_id = p_batch_id;
    END IF;

    IF NOT FOUND THEN
        RETURN;
    END IF;
    IF v_total_row_count < 0 THEN
        RAISE EXCEPTION 'JOIN batch % has an invalid row count', v_batch_id;
    END IF;
    IF v_total_row_count = 0 THEN
        IF p_row_offset <> 0 THEN
            RAISE EXCEPTION 'JOIN empty batch % only accepts offset zero', v_batch_id;
        END IF;
        RETURN QUERY SELECT
            v_batch_id,
            v_captured_at,
            0,
            0,
            0,
            true,
            octet_length('[]'::text),
            '[]'::jsonb;
        RETURN;
    END IF;
    IF p_row_offset >= v_total_row_count THEN
        RAISE EXCEPTION 'JOIN row offset % is outside batch %',
            p_row_offset, v_batch_id;
    END IF;

    v_limit := LEAST(c_max_chunk_rows, v_total_row_count - p_row_offset);
    LOOP
        SELECT COALESCE(jsonb_agg(candidate.payload ORDER BY candidate.row_no), '[]'::jsonb)
          INTO v_rows
          FROM (
              SELECT
                  sample.row_no,
                  jsonb_build_object(
                      'dbid', sample.dbid,
                      'userid', sample.userid,
                      'queryid', sample.queryid,
                      'qualid', sample.qualid,
                      'qualnodeid', sample.qualnodeid,
                      'lrelid', sample.lrelid,
                      'lattnum', sample.lattnum,
                      'opno', sample.opno,
                      'operatorName', sample.operator_name,
                      'operatorCommutator', sample.operator_commutator,
                      'btreeStrategy', sample.btree_strategy,
                      'rrelid', sample.rrelid,
                      'rattnum', sample.rattnum,
                      'occurences', sample.occurences,
                      'executionCount', sample.execution_count,
                      'nbfiltered', sample.nbfiltered,
                      'evalType', sample.eval_type,
                      'isJoin', sample.is_join
                  ) AS payload
                FROM advisor_join.outbox_rows AS sample
               WHERE sample.batch_id = v_batch_id
               ORDER BY sample.row_no
               OFFSET p_row_offset
               LIMIT v_limit
          ) AS candidate;

        v_actual_rows := jsonb_array_length(v_rows);
        IF v_actual_rows <> v_limit THEN
            RAISE EXCEPTION
                'JOIN batch % metadata mismatch: expected % rows at offset %, found %',
                v_batch_id, v_limit, p_row_offset, v_actual_rows;
        END IF;
        -- Use the canonical JSON text size, not jsonb's internal datum size.
        -- The daemon sends compact UTF-8 JSON, which is no larger than this
        -- representation, so the limit also bounds the wire payload.
        v_payload_bytes := octet_length(v_rows::text);
        EXIT WHEN v_payload_bytes <= c_max_chunk_bytes;
        IF v_limit = 1 THEN
            RAISE EXCEPTION 'JOIN batch % contains a row larger than % bytes',
                v_batch_id, c_max_chunk_bytes;
        END IF;
        -- Halving is deterministic for a fixed batch/offset and bounds the
        -- number of retries needed even for an unexpectedly wide payload.
        v_limit := GREATEST(1, v_limit / 2);
    END LOOP;

    RETURN QUERY SELECT
        v_batch_id,
        v_captured_at,
        v_total_row_count,
        p_row_offset,
        v_limit,
        p_row_offset + v_limit = v_total_row_count,
        v_payload_bytes,
        v_rows;
END;
$$;

CREATE OR REPLACE FUNCTION advisor_join.ack_batch(p_batch_id bigint)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, advisor_join
AS $$
WITH deleted AS (
    DELETE FROM advisor_join.outbox_batches WHERE batch_id = p_batch_id
    RETURNING 1
)
SELECT EXISTS (SELECT 1 FROM deleted);
$$;

ALTER FUNCTION advisor_join.capture_and_reset() OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_join.assert_outbox_within_limits() OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_join.fetch_batches(integer) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_join.list_batch_headers(integer) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_join.fetch_batch_chunk(bigint, integer) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_join.ack_batch(bigint) OWNER TO CURRENT_USER;

REVOKE ALL ON FUNCTION advisor_join.capture_and_reset() FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_join.assert_outbox_within_limits() FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_join.fetch_batches(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_join.list_batch_headers(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_join.fetch_batch_chunk(bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_join.ack_batch(bigint) FROM PUBLIC;

SELECT format('GRANT USAGE ON SCHEMA advisor_join TO %I, %I', :'collector_user', :'join_reader_user')
\gexec
SELECT format(
    'GRANT EXECUTE ON FUNCTION advisor_join.capture_and_reset() TO %I',
    :'collector_user'
)
\gexec
SELECT format(
    'GRANT EXECUTE ON FUNCTION advisor_join.fetch_batches(integer) TO %I',
    :'join_reader_user'
)
\gexec
SELECT format(
    'GRANT EXECUTE ON FUNCTION advisor_join.list_batch_headers(integer) TO %I',
    :'join_reader_user'
)
\gexec
SELECT format(
    'GRANT EXECUTE ON FUNCTION advisor_join.fetch_batch_chunk(bigint,integer) TO %I',
    :'join_reader_user'
)
\gexec
SELECT format(
    'GRANT EXECUTE ON FUNCTION advisor_join.ack_batch(bigint) TO %I',
    :'join_reader_user'
)
\gexec

-- Reset is now reachable by the collector only through the atomic wrapper.
SELECT format(
    'REVOKE EXECUTE ON FUNCTION %I.pg_qualstats_reset() FROM PUBLIC, %I',
    n.nspname,
    :'collector_user'
)
FROM pg_extension AS e
JOIN pg_namespace AS n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_qualstats'
\gexec
