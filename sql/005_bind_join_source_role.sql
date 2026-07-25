\set ON_ERROR_STOP on

-- Runs after 001_advisor_schema.sql on a fresh repository.  Existing-volume
-- migrations perform the same bind explicitly after reapplying the schema.
-- If demo registration is disabled and the external alias is not registered
-- yet, the role remains intentionally unusable until the DBA binds it.
\getenv join_source_alias JOIN_SOURCE_ALIAS
\if :{?join_source_alias}
SELECT advisor_ingest.bind_join_source_role('advisor_join_ingest', :'join_source_alias')
WHERE EXISTS (
    SELECT 1
      FROM "PoWA".powa_servers
     WHERE alias = :'join_source_alias'
);
\endif
