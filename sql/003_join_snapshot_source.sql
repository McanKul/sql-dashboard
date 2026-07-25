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

ALTER TABLE advisor_join.outbox_batches OWNER TO CURRENT_USER;
ALTER TABLE advisor_join.outbox_rows OWNER TO CURRENT_USER;
REVOKE ALL ON ALL TABLES IN SCHEMA advisor_join FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor_join FROM PUBLIC;

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

    -- Bound an abandoned outbox without hiding current delivery failures.
    DELETE FROM advisor_join.outbox_batches
     WHERE captured_at < now() - interval '7 days';

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
ALTER FUNCTION advisor_join.fetch_batches(integer) OWNER TO CURRENT_USER;
ALTER FUNCTION advisor_join.ack_batch(bigint) OWNER TO CURRENT_USER;

REVOKE ALL ON FUNCTION advisor_join.capture_and_reset() FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor_join.fetch_batches(integer) FROM PUBLIC;
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
