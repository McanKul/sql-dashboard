\set ON_ERROR_STOP on

-- Safe for a developer/CI repository: fixture rows are rolled back.  Sequence
-- values may advance, as PostgreSQL sequences are intentionally nontransactional.
BEGIN;

DO $acl_assert$
DECLARE
    function_definition text;
BEGIN
    IF has_table_privilege('advisor_api', 'advisor.query_annotations', 'INSERT')
       OR has_table_privilege('advisor_api', 'advisor.query_annotations', 'UPDATE')
       OR has_table_privilege('advisor_api', 'advisor.audit_log', 'INSERT') THEN
        RAISE EXCEPTION 'advisor_api still has direct annotation/audit DML';
    END IF;

    IF NOT has_function_privilege(
        'advisor_api',
        'advisor.upsert_query_annotation(integer,oid,bigint,text,text,text)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'advisor_api',
        'advisor.record_query_export_audit(text,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'advisor_api wrapper EXECUTE grant is missing';
    END IF;

    IF has_function_privilege(
        'advisor_join_ingest',
        'advisor.upsert_query_annotation(integer,oid,bigint,text,text,text)',
        'EXECUTE'
    ) OR has_function_privilege(
        'advisor_join_ingest',
        'advisor.record_query_export_audit(text,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'annotation/export wrapper leaked through PUBLIC';
    END IF;

    IF has_sequence_privilege('advisor_api', 'advisor.audit_log_id_seq', 'USAGE') THEN
        RAISE EXCEPTION 'advisor_api still has audit sequence USAGE';
    END IF;

    SELECT pg_get_functiondef('advisor.audit_annotation_change()'::regprocedure)
      INTO STRICT function_definition;
    IF position('app.actor' IN function_definition) > 0
       OR position('NEW.updated_by' IN function_definition) = 0 THEN
        RAISE EXCEPTION 'annotation trigger still trusts app.actor';
    END IF;

    BEGIN
        EXECUTE 'SET LOCAL ROLE advisor_api';
        INSERT INTO advisor.query_annotations (
            server_id, database_id, query_id, status, note, updated_by
        ) VALUES (
            2147482997, 4294967000::oid, -9223372036854770000,
            'NEW', 'must fail', 'direct-client'
        );
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'direct query_annotations INSERT unexpectedly succeeded';
    EXCEPTION
        WHEN insufficient_privilege THEN
            EXECUTE 'RESET ROLE';
    END;

    BEGIN
        EXECUTE 'SET LOCAL ROLE advisor_api';
        UPDATE advisor.query_annotations
           SET note = 'must fail'
         WHERE server_id = 2147482997;
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'direct query_annotations UPDATE unexpectedly succeeded';
    EXCEPTION
        WHEN insufficient_privilege THEN
            EXECUTE 'RESET ROLE';
    END;

    BEGIN
        EXECUTE 'SET LOCAL ROLE advisor_api';
        INSERT INTO advisor.audit_log(actor, action, object_type, object_key)
        VALUES ('direct-client', 'SPOOFED', 'query', 'must-fail');
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'direct audit_log INSERT unexpectedly succeeded';
    EXCEPTION
        WHEN insufficient_privilege THEN
            EXECUTE 'RESET ROLE';
    END;
END;
$acl_assert$;

-- A client-controlled custom GUC remains syntactically settable but is no
-- longer an audit identity source.  Only the authenticated subject parameter
-- reaches updated_by and the trigger audit row.
SET LOCAL ROLE advisor_api;
SELECT pg_catalog.set_config('app.actor', 'spoofed-client-actor-fixture', true);
SELECT * FROM advisor.upsert_query_annotation(
    2147482997,
    4294967000::oid,
    -9223372036854770000,
    'IN_REVIEW',
    'initial authenticated note',
    'fixture-service-subject'
);
SELECT * FROM advisor.upsert_query_annotation(
    2147482997,
    4294967000::oid,
    -9223372036854770000,
    'COMPLETED',
    'completed authenticated note',
    'fixture-service-subject'
);
SELECT advisor.record_query_export_audit(
    'fixture-service-subject',
    'REQUESTED',
    '{"requestId":"authenticated-actor-fixture","window":"24h"}'::jsonb
);
SELECT advisor.record_query_export_audit(
    'fixture-service-subject',
    'COMPLETED',
    '{"requestId":"authenticated-actor-fixture","window":"24h","rows":3}'::jsonb
);
RESET ROLE;

DO $validation_assert$
BEGIN
    BEGIN
        PERFORM advisor.upsert_query_annotation(
            2147482997, 4294967000::oid, -9223372036854770000,
            'completed', NULL, 'fixture-service-subject'
        );
        RAISE EXCEPTION 'lowercase annotation status unexpectedly accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM advisor.upsert_query_annotation(
            2147482997, 4294967000::oid, -9223372036854770000,
            'COMPLETED', repeat('x', 4001), 'fixture-service-subject'
        );
        RAISE EXCEPTION 'oversized annotation note unexpectedly accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM advisor.upsert_query_annotation(
            2147482997, 4294967000::oid, -9223372036854770000,
            'COMPLETED', NULL, ' fixture-service-subject'
        );
        RAISE EXCEPTION 'invalid authenticated actor unexpectedly accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;

    BEGIN
        PERFORM advisor.record_query_export_audit(
            'fixture-service-subject', 'EXPORTED', '{}'::jsonb
        );
        RAISE EXCEPTION 'unapproved export phase unexpectedly accepted';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
END;
$validation_assert$;

DO $result_assert$
DECLARE
    annotation_row advisor.query_annotations%ROWTYPE;
    annotation_created_count bigint;
    annotation_updated_count bigint;
    export_requested_count bigint;
    export_completed_count bigint;
BEGIN
    SELECT *
      INTO STRICT annotation_row
      FROM advisor.query_annotations
     WHERE server_id = 2147482997
       AND database_id = 4294967000::oid
       AND query_id = -9223372036854770000;

    IF annotation_row.status <> 'COMPLETED'
       OR annotation_row.note <> 'completed authenticated note'
       OR annotation_row.updated_by <> 'fixture-service-subject' THEN
        RAISE EXCEPTION 'annotation row does not contain authenticated actor/result: %',
            row_to_json(annotation_row);
    END IF;

    SELECT
        count(*) FILTER (WHERE action = 'ANNOTATION_CREATED'),
        count(*) FILTER (WHERE action = 'ANNOTATION_UPDATED')
      INTO annotation_created_count, annotation_updated_count
      FROM advisor.audit_log
     WHERE object_type = 'query'
       AND object_key = '2147482997:4294967000:-9223372036854770000'
       AND actor = 'fixture-service-subject';

    IF annotation_created_count <> 1 OR annotation_updated_count <> 1 THEN
        RAISE EXCEPTION 'annotation audit actions are incomplete: created=%, updated=%',
            annotation_created_count, annotation_updated_count;
    END IF;

    IF EXISTS (
        SELECT 1 FROM advisor.audit_log
         WHERE actor = 'spoofed-client-actor-fixture'
           AND object_type = 'query'
           AND object_key = '2147482997:4294967000:-9223372036854770000'
    ) THEN
        RAISE EXCEPTION 'app.actor spoof reached audit_log';
    END IF;

    SELECT
        count(*) FILTER (WHERE action = 'QUERIES_EXPORT_REQUESTED'),
        count(*) FILTER (WHERE action = 'QUERIES_EXPORT_COMPLETED')
      INTO export_requested_count, export_completed_count
      FROM advisor.audit_log
     WHERE actor = 'fixture-service-subject'
       AND object_type = 'query_collection'
       AND object_key = 'queries.csv'
       AND details ->> 'requestId' = 'authenticated-actor-fixture';

    IF export_requested_count <> 1 OR export_completed_count <> 1 THEN
        RAISE EXCEPTION 'export audit actions are incomplete: requested=%, completed=%',
            export_requested_count, export_completed_count;
    END IF;

    IF EXISTS (
        SELECT 1 FROM advisor.audit_log
         WHERE actor = 'fixture-service-subject'
           AND action = 'QUERIES_EXPORTED'
           AND details ->> 'requestId' = 'authenticated-actor-fixture'
    ) THEN
        RAISE EXCEPTION 'legacy QUERIES_EXPORTED action was written';
    END IF;
END;
$result_assert$;

ROLLBACK;

DO $rollback_assert$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM advisor.query_annotations
         WHERE server_id = 2147482997
           AND database_id = 4294967000::oid
           AND query_id = -9223372036854770000
    ) OR EXISTS (
        SELECT 1
          FROM advisor.audit_log
         WHERE (
                   object_type = 'query'
               AND object_key = '2147482997:4294967000:-9223372036854770000'
         ) OR (
                   object_type = 'query_collection'
               AND object_key = 'queries.csv'
               AND details ->> 'requestId' = 'authenticated-actor-fixture'
         )
    ) THEN
        RAISE EXCEPTION 'authenticated actor fixture was not rolled back';
    END IF;
END;
$rollback_assert$;
