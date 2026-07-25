\set ON_ERROR_STOP on

-- Runtime EXPLAIN ANALYZE never reuses production bind values. A DBA must
-- explicitly approve a small synthetic/anonymized fixture for the exact
-- persisted candidate and exact normalized SQL hash.
CREATE OR REPLACE FUNCTION advisor_ingest.runtime_bind_values_valid(p_values jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
SELECT CASE
    WHEN p_values IS NULL OR jsonb_typeof(p_values) <> 'array' THEN false
    WHEN jsonb_array_length(p_values) > 16 THEN false
    WHEN pg_column_size(p_values) > 8192 THEN false
    ELSE NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_values) AS item(value)
        WHERE jsonb_typeof(item.value) NOT IN ('string', 'number', 'boolean', 'null')
           OR (jsonb_typeof(item.value) = 'string' AND length(item.value #>> '{}') > 2048)
           OR (jsonb_typeof(item.value) = 'number' AND length(item.value::text) > 100)
    )
END;
$$;

REVOKE ALL ON FUNCTION advisor_ingest.runtime_bind_values_valid(jsonb) FROM PUBLIC;

CREATE TABLE IF NOT EXISTS advisor_ingest.runtime_replay_fixtures (
    candidate_id uuid PRIMARY KEY
        REFERENCES advisor.index_candidates(candidate_id) ON DELETE CASCADE,
    server_id integer NOT NULL,
    database_id oid NOT NULL,
    query_id bigint NOT NULL,
    normalized_sql_sha256 text NOT NULL
        CHECK (normalized_sql_sha256 ~ '^[0-9a-f]{64}$'),
    bind_values jsonb NOT NULL
        CHECK (advisor_ingest.runtime_bind_values_valid(bind_values)),
    value_class text NOT NULL CHECK (value_class IN ('SYNTHETIC', 'ANONYMIZED')),
    approved_by text NOT NULL CHECK (length(btrim(approved_by)) BETWEEN 1 AND 200),
    approval_ticket text NOT NULL CHECK (length(btrim(approval_ticket)) BETWEEN 1 AND 200),
    approved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz,
    enabled boolean NOT NULL DEFAULT true,
    note text CHECK (note IS NULL OR length(note) <= 1000),
    CHECK (expires_at IS NULL OR expires_at > approved_at),
    UNIQUE (server_id, database_id, query_id, candidate_id)
);

REVOKE ALL ON TABLE advisor_ingest.runtime_replay_fixtures FROM PUBLIC;

CREATE OR REPLACE FUNCTION advisor_ingest.upsert_runtime_replay_fixture(
    p_candidate_id uuid,
    p_normalized_sql text,
    p_bind_values jsonb,
    p_value_class text,
    p_approved_by text,
    p_approval_ticket text,
    p_expires_at timestamptz DEFAULT NULL,
    p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
DECLARE
    v_candidate advisor.index_candidates%ROWTYPE;
BEGIN
    SELECT *
      INTO v_candidate
      FROM advisor.index_candidates
     WHERE candidate_id = p_candidate_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Persisted candidate % not found', p_candidate_id;
    END IF;
    IF NOT advisor_ingest.runtime_bind_values_valid(p_bind_values) THEN
        RAISE EXCEPTION 'Replay bind values must be an <=8KiB array of <=16 JSON scalars';
    END IF;
    IF p_value_class NOT IN ('SYNTHETIC', 'ANONYMIZED') THEN
        RAISE EXCEPTION 'Replay fixture value class must be SYNTHETIC or ANONYMIZED';
    END IF;
    IF p_expires_at IS NOT NULL AND p_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Replay fixture expiry must be in the future';
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM "PoWA".powa_statements AS statement
         WHERE statement.srvid = v_candidate.server_id
           AND statement.dbid = v_candidate.database_id
           AND statement.queryid = v_candidate.query_id
           AND statement.query = p_normalized_sql
    ) THEN
        RAISE EXCEPTION 'Normalized SQL does not exactly match repository query identity';
    END IF;

    INSERT INTO advisor_ingest.runtime_replay_fixtures (
        candidate_id, server_id, database_id, query_id,
        normalized_sql_sha256, bind_values, value_class,
        approved_by, approval_ticket, approved_at, expires_at, enabled, note
    ) VALUES (
        p_candidate_id,
        v_candidate.server_id,
        v_candidate.database_id,
        v_candidate.query_id,
        encode(sha256(convert_to(p_normalized_sql, 'UTF8')), 'hex'),
        p_bind_values,
        p_value_class,
        btrim(p_approved_by),
        btrim(p_approval_ticket),
        clock_timestamp(),
        p_expires_at,
        true,
        p_note
    )
    ON CONFLICT (candidate_id) DO UPDATE
       SET normalized_sql_sha256 = EXCLUDED.normalized_sql_sha256,
           bind_values = EXCLUDED.bind_values,
           value_class = EXCLUDED.value_class,
           approved_by = EXCLUDED.approved_by,
           approval_ticket = EXCLUDED.approval_ticket,
           approved_at = EXCLUDED.approved_at,
           expires_at = EXCLUDED.expires_at,
           enabled = true,
           note = EXCLUDED.note;
END;
$$;

REVOKE ALL ON FUNCTION advisor_ingest.upsert_runtime_replay_fixture(
    uuid, text, jsonb, text, text, text, timestamptz, text
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION advisor.runtime_replay_fixture_status(
    p_candidate_ids uuid[],
    p_server_id integer,
    p_database_id oid,
    p_query_id bigint,
    p_normalized_sql text
)
RETURNS TABLE (candidate_id uuid, available boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
SELECT requested.candidate_id,
       EXISTS (
           SELECT 1
             FROM advisor_ingest.runtime_replay_fixtures AS fixture
            WHERE fixture.candidate_id = requested.candidate_id
              AND fixture.server_id = p_server_id
              AND fixture.database_id = p_database_id
              AND fixture.query_id = p_query_id
              AND fixture.normalized_sql_sha256 =
                  encode(sha256(convert_to(p_normalized_sql, 'UTF8')), 'hex')
              AND fixture.enabled
              AND (fixture.expires_at IS NULL OR fixture.expires_at > now())
       ) AS available
FROM unnest(coalesce(p_candidate_ids, ARRAY[]::uuid[])) AS requested(candidate_id);
$$;

CREATE OR REPLACE FUNCTION advisor.runtime_replay_fixture(
    p_candidate_id uuid,
    p_server_id integer,
    p_database_id oid,
    p_query_id bigint,
    p_normalized_sql text
)
RETURNS TABLE (
    bind_values jsonb,
    value_class text,
    approved_by text,
    approval_ticket text,
    approved_at timestamptz,
    expires_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, advisor, advisor_ingest
AS $$
SELECT fixture.bind_values,
       fixture.value_class,
       fixture.approved_by,
       fixture.approval_ticket,
       fixture.approved_at,
       fixture.expires_at
  FROM advisor_ingest.runtime_replay_fixtures AS fixture
 WHERE fixture.candidate_id = p_candidate_id
   AND fixture.server_id = p_server_id
   AND fixture.database_id = p_database_id
   AND fixture.query_id = p_query_id
   AND fixture.normalized_sql_sha256 =
       encode(sha256(convert_to(p_normalized_sql, 'UTF8')), 'hex')
   AND fixture.enabled
   AND (fixture.expires_at IS NULL OR fixture.expires_at > now())
 ORDER BY fixture.approved_at DESC
 LIMIT 1;
$$;

REVOKE ALL ON FUNCTION advisor.runtime_replay_fixture_status(
    uuid[], integer, oid, bigint, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION advisor.runtime_replay_fixture(
    uuid, integer, oid, bigint, text
) FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_api') THEN
        GRANT EXECUTE ON FUNCTION advisor.runtime_replay_fixture_status(
            uuid[], integer, oid, bigint, text
        ) TO advisor_api;
        GRANT EXECUTE ON FUNCTION advisor.runtime_replay_fixture(
            uuid, integer, oid, bigint, text
        ) TO advisor_api;
    END IF;
END
$$;

COMMENT ON TABLE advisor_ingest.runtime_replay_fixtures IS
'Operator-approved synthetic/anonymized bind fixtures; values are private and exact-query scoped.';
