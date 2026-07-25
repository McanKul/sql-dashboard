\set ON_ERROR_STOP on

-- Existing installations accepted a client-controlled app.actor GUC and
-- granted advisor_api direct writes to annotation/audit tables.  Move both
-- operations behind narrow SECURITY DEFINER entry points.  The API supplies
-- only the subject resolved by its authenticated principal registry.

DO $constraints$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid = 'advisor.query_annotations'::regclass
           AND conname = 'query_annotations_updated_by_valid'
    ) THEN
        ALTER TABLE advisor.query_annotations
            ADD CONSTRAINT query_annotations_updated_by_valid CHECK (
                updated_by = btrim(updated_by)
                AND char_length(updated_by) BETWEEN 1 AND 120
                AND updated_by !~ '[[:cntrl:]]'
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid = 'advisor.query_annotations'::regclass
           AND conname = 'query_annotations_note_length'
    ) THEN
        ALTER TABLE advisor.query_annotations
            ADD CONSTRAINT query_annotations_note_length CHECK (
                note IS NULL OR char_length(note) <= 4000
            ) NOT VALID;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid = 'advisor.audit_log'::regclass
           AND conname = 'audit_log_actor_valid'
    ) THEN
        ALTER TABLE advisor.audit_log
            ADD CONSTRAINT audit_log_actor_valid CHECK (
                actor = btrim(actor)
                AND char_length(actor) BETWEEN 1 AND 120
                AND actor !~ '[[:cntrl:]]'
            ) NOT VALID;
    END IF;

END;
$constraints$;

-- NOT VALID intentionally avoids a full-table scan or an upgrade failure on
-- historical client-controlled values. PostgreSQL still enforces these CHECK
-- constraints for every row inserted or updated after this migration.

CREATE OR REPLACE FUNCTION advisor.audit_annotation_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    INSERT INTO advisor.audit_log(actor, action, object_type, object_key, details)
    VALUES (
        NEW.updated_by,
        CASE WHEN TG_OP = 'INSERT' THEN 'ANNOTATION_CREATED' ELSE 'ANNOTATION_UPDATED' END,
        'query',
        pg_catalog.concat_ws(':', NEW.server_id, NEW.database_id, NEW.query_id),
        pg_catalog.jsonb_build_object(
            'status', NEW.status,
            'note', NEW.note,
            'previousStatus', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE NULL END
        )
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION advisor.upsert_query_annotation(
    p_server_id integer,
    p_database_id oid,
    p_query_id bigint,
    p_status text,
    p_note text,
    p_actor text
)
RETURNS TABLE (
    server_id integer,
    database_id oid,
    query_id bigint,
    status text,
    note text,
    updated_by text,
    updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    IF p_actor IS NULL
       OR p_actor <> pg_catalog.btrim(p_actor)
       OR pg_catalog.char_length(p_actor) NOT BETWEEN 1 AND 120
       OR p_actor ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'authenticated actor is invalid'
            USING ERRCODE = '22023';
    END IF;

    IF p_status IS NULL
       OR p_status NOT IN ('NEW', 'IN_REVIEW', 'COMPLETED', 'REJECTED') THEN
        RAISE EXCEPTION 'annotation status is invalid'
            USING ERRCODE = '22023';
    END IF;

    IF p_note IS NOT NULL AND pg_catalog.char_length(p_note) > 4000 THEN
        RAISE EXCEPTION 'annotation note exceeds 4000 characters'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    INSERT INTO advisor.query_annotations AS annotation (
        server_id,
        database_id,
        query_id,
        status,
        note,
        updated_by,
        updated_at
    )
    VALUES (
        p_server_id,
        p_database_id,
        p_query_id,
        p_status,
        p_note,
        p_actor,
        pg_catalog.clock_timestamp()
    )
    ON CONFLICT ON CONSTRAINT query_annotations_pkey
    DO UPDATE SET
        status = EXCLUDED.status,
        note = EXCLUDED.note,
        updated_by = EXCLUDED.updated_by,
        updated_at = pg_catalog.clock_timestamp()
    RETURNING
        annotation.server_id,
        annotation.database_id,
        annotation.query_id,
        annotation.status,
        annotation.note,
        annotation.updated_by,
        annotation.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION advisor.record_query_export_audit(
    p_actor text,
    p_phase text,
    p_details jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    audit_action text;
BEGIN
    IF p_actor IS NULL
       OR p_actor <> pg_catalog.btrim(p_actor)
       OR pg_catalog.char_length(p_actor) NOT BETWEEN 1 AND 120
       OR p_actor ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'authenticated actor is invalid'
            USING ERRCODE = '22023';
    END IF;

    audit_action := CASE p_phase
        WHEN 'REQUESTED' THEN 'QUERIES_EXPORT_REQUESTED'
        WHEN 'COMPLETED' THEN 'QUERIES_EXPORT_COMPLETED'
        ELSE NULL
    END;
    IF audit_action IS NULL THEN
        RAISE EXCEPTION 'query export phase is invalid'
            USING ERRCODE = '22023';
    END IF;

    IF p_details IS NULL
       OR pg_catalog.jsonb_typeof(p_details) IS DISTINCT FROM 'object'
       OR pg_catalog.pg_column_size(p_details) > 32768 THEN
        RAISE EXCEPTION 'query export audit details must be a bounded JSON object'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO advisor.audit_log(actor, action, object_type, object_key, details)
    VALUES (
        p_actor,
        audit_action,
        'query_collection',
        'queries.csv',
        p_details
    );
END;
$$;

-- SELECT remains available for dashboard reads.  All writes use the two
-- authenticated-subject wrappers above; the trigger function is not a public
-- callable entry point.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON advisor.query_annotations FROM advisor_api;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON advisor.audit_log FROM advisor_api;
REVOKE USAGE, UPDATE ON SEQUENCE advisor.audit_log_id_seq FROM advisor_api;

REVOKE ALL ON FUNCTION advisor.audit_annotation_change() FROM PUBLIC, advisor_api;
REVOKE ALL ON FUNCTION advisor.upsert_query_annotation(integer, oid, bigint, text, text, text)
    FROM PUBLIC, advisor_api;
GRANT EXECUTE ON FUNCTION advisor.upsert_query_annotation(integer, oid, bigint, text, text, text)
    TO advisor_api;
REVOKE ALL ON FUNCTION advisor.record_query_export_audit(text, text, jsonb)
    FROM PUBLIC, advisor_api;
GRANT EXECUTE ON FUNCTION advisor.record_query_export_audit(text, text, jsonb)
    TO advisor_api;

COMMENT ON FUNCTION advisor.upsert_query_annotation(integer, oid, bigint, text, text, text)
IS 'Upserts a query annotation using only the API-authenticated server-side subject.';
COMMENT ON FUNCTION advisor.record_query_export_audit(text, text, jsonb)
IS 'Records REQUESTED/COMPLETED query CSV export audit events with fixed actions.';
