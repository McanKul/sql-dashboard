-- PoWA REL_5_2_0 ships one pg_qualstats purge call with a stale two-argument
-- powa_prevent_concurrent_snapshot signature.  The helper has accepted only
-- the server id since PoWA 5.0, so the purge fails only when retention runs.
--
-- Fresh images patch the extension artifact before installation.  This
-- guarded migration repairs already initialized named volumes without
-- changing any table, history row, ownership, ACL, or extension membership.
DO $compat$
DECLARE
    v_extension_version text;
    v_function_oid oid;
    v_definition text;
    v_fixed_definition text;
BEGIN
    SELECT e.extversion
      INTO v_extension_version
      FROM pg_extension AS e
      JOIN pg_namespace AS n ON n.oid = e.extnamespace
     WHERE e.extname = 'powa'
       AND n.nspname = 'PoWA';

    IF v_extension_version IS DISTINCT FROM '5.2.0' THEN
        RAISE EXCEPTION
            'Expected PoWA 5.2.0 in schema PoWA, found %',
            coalesce(v_extension_version, 'not installed');
    END IF;

    SELECT p.oid
      INTO v_function_oid
      FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'PoWA'
       AND p.proname = 'powa_qualstats_purge'
       AND p.proargtypes = '23'::oidvector;

    IF v_function_oid IS NULL THEN
        RAISE EXCEPTION 'PoWA.powa_qualstats_purge(integer) is missing';
    END IF;

    v_definition := pg_get_functiondef(v_function_oid);

    IF position(
        'powa_prevent_concurrent_snapshot(_srvid,''pg_qualstats'')'
        IN v_definition
    ) > 0 THEN
        v_fixed_definition := replace(
            v_definition,
            'powa_prevent_concurrent_snapshot(_srvid,''pg_qualstats'')',
            'powa_prevent_concurrent_snapshot(_srvid)'
        );
        EXECUTE v_fixed_definition;
    ELSIF position(
        'powa_prevent_concurrent_snapshot(_srvid)'
        IN v_definition
    ) = 0 THEN
        RAISE EXCEPTION
            'Unexpected PoWA.powa_qualstats_purge(integer) definition; refusing an unsafe rewrite';
    END IF;

    SELECT pg_get_functiondef(p.oid)
      INTO v_definition
      FROM pg_proc AS p
      JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'PoWA'
       AND p.proname = 'powa_qualstats_purge'
       AND p.proargtypes = '23'::oidvector;

    IF position(
        'powa_prevent_concurrent_snapshot(_srvid,''pg_qualstats'')'
        IN v_definition
    ) > 0 OR position(
        'powa_prevent_concurrent_snapshot(_srvid)'
        IN v_definition
    ) = 0 THEN
        RAISE EXCEPTION 'PoWA 5.2.0 pg_qualstats purge compatibility repair failed';
    END IF;
END
$compat$;
