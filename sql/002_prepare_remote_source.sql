\set ON_ERROR_STOP on

-- Bu dosya scripts/register-source.sh --prepare tarafindan psql degiskenleriyle
-- calistirilir. Parola dosyada veya komut satirinda bulunmaz; script onu yalniz
-- calisan psql surecinin environment'ina verir ve \getenv ile alir.
\getenv collector_password ADVISOR_SOURCE_COLLECTOR_PASSWORD

DO $check$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(required.name, ', ' ORDER BY required.name)
      INTO missing
      FROM (VALUES
          ('pg_stat_statements'),
          ('pg_qualstats'),
          ('pg_stat_kcache'),
          ('btree_gist'),
          ('powa')
      ) AS required(name)
     WHERE NOT EXISTS (
         SELECT 1
           FROM pg_available_extensions AS available
          WHERE available.name = required.name
     );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION
          'Kaynak clusterda extension paketleri eksik: %. PostgreSQL major surumune uygun PoWA paketini once isletim sistemine kurun.',
          missing;
    END IF;

    IF NOT ('pg_stat_statements' = ANY (
        string_to_array(replace(current_setting('shared_preload_libraries'), ' ', ''), ',')
    )) THEN
        RAISE EXCEPTION
          'pg_stat_statements shared_preload_libraries icinde degil. Ayari ekleyip PostgreSQL clusterini yeniden baslatin.';
    END IF;

    IF NOT ('pg_qualstats' = ANY (
        string_to_array(replace(current_setting('shared_preload_libraries'), ' ', ''), ',')
    )) THEN
        RAISE EXCEPTION
          'pg_qualstats shared_preload_libraries icinde degil. Ayari ekleyip PostgreSQL clusterini yeniden baslatin.';
    END IF;

    IF NOT ('pg_stat_kcache' = ANY (
        string_to_array(replace(current_setting('shared_preload_libraries'), ' ', ''), ',')
    )) THEN
        RAISE EXCEPTION
          'pg_stat_kcache shared_preload_libraries icinde degil. Ayari ekleyip PostgreSQL clusterini yeniden baslatin.';
    END IF;

    IF current_setting('compute_query_id', true) = 'off' THEN
        RAISE EXCEPTION
          'compute_query_id=off. Degeri auto veya on yapip konfigurasyonu yeniden yukleyin.';
    END IF;
END
$check$;

SELECT format('CREATE ROLE %I LOGIN', :'collector_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'collector_user')
\gexec

SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'collector_user', :'collector_password')
\gexec

SELECT format('GRANT pg_read_all_stats TO %I', :'collector_user')
\gexec

SELECT format('CREATE DATABASE %I', :'monitoring_db')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'monitoring_db')
\gexec

-- Per-database katalog ve tablo metrikleri icin collector'in connectable tum
-- uygulama DB'lerine baglanabilmesi gerekir. Bu yalnız CONNECT verir; tablo
-- verisine SELECT yetkisi vermez.
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', datname, :'collector_user')
  FROM pg_database
 WHERE datallowconn
   AND NOT datistemplate
\gexec

\connect -reuse-previous=on :monitoring_db

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_qualstats;
CREATE EXTENSION IF NOT EXISTS pg_stat_kcache;
CREATE SCHEMA IF NOT EXISTS "PoWA";
CREATE EXTENSION IF NOT EXISTS powa WITH SCHEMA "PoWA";
SELECT "PoWA".powa_activate_extension(0, 'pg_qualstats');
SELECT "PoWA".powa_activate_extension(0, 'pg_stat_kcache');

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'collector_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA %I TO %I', 'PoWA', :'collector_user')
\gexec
SELECT format('GRANT powa_snapshot TO %I', :'collector_user')
\gexec
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', 'PoWA', :'collector_user')
\gexec

-- Remote collector snapshot sonrasinda pg_qualstats_reset() cagirir. Bu
-- fonksiyon PUBLIC'ten revoke edildigi icin collector'a acik yetki gerekir.
SELECT format(
    'GRANT EXECUTE ON FUNCTION %I.pg_qualstats(), %I.pg_qualstats_reset() TO %I',
    n.nspname,
    n.nspname,
    :'collector_user'
)
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_qualstats'
\gexec

SELECT current_setting('track_io_timing') = 'on' AS track_io_timing_enabled
\gset
\if :track_io_timing_enabled
\else
\warn 'UYARI: track_io_timing=off; fiziksel I/O sure metrikleri eksik kalabilir.'
\endif

SELECT current_database() AS monitoring_database,
       (SELECT extversion FROM pg_extension WHERE extname = 'powa') AS powa_version,
       (SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements') AS pgss_version,
       (SELECT extversion FROM pg_extension WHERE extname = 'pg_qualstats') AS pg_qualstats_version,
       (SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_kcache') AS pg_stat_kcache_version,
       pg_has_role(current_user, 'pg_read_all_stats', 'member') AS admin_can_read_stats;
