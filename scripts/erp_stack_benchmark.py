#!/usr/bin/env python3
"""Measure source and PoWA repository cost across one realistic ERP run."""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Mapping, Sequence


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULTS = {
    "quick": (120, 8),
    "normal": (600, 24),
    "stress": (1800, 48),
    "erp": (600, 32),
}
CONTAINER_ID = re.compile(r"^[0-9a-f]{12,64}$")
PROJECT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
SOURCE_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")
SYNC_PROTOCOL_VERSION = 1
SYNC_PHASES = ("start", "end")
SYNC_MAX_PAYLOAD_BYTES = 4096
SUPPORTED_POWA_MAINTENANCE_SEMANTICS = frozenset({"5.2.0"})


SOURCE_SQL = r"""
WITH database_stats AS (
    SELECT * FROM pg_stat_database WHERE datname = 'appdb'
), io_stats AS (
    SELECT
        coalesce(sum(reads), 0)::bigint AS reads,
        coalesce(sum(read_bytes), 0)::numeric AS read_bytes,
        coalesce(sum(read_time), 0)::double precision AS read_time_ms,
        coalesce(sum(writes), 0)::bigint AS writes,
        coalesce(sum(write_bytes), 0)::numeric AS write_bytes,
        coalesce(sum(write_time), 0)::double precision AS write_time_ms,
        coalesce(sum(writebacks), 0)::bigint AS writebacks,
        coalesce(sum(extends), 0)::bigint AS extends,
        coalesce(sum(extend_bytes), 0)::numeric AS extend_bytes,
        coalesce(sum(fsyncs), 0)::bigint AS fsyncs,
        max(stats_reset) AS stats_reset
    FROM pg_stat_io
), query_stats AS (
    SELECT
        count(*) FILTER (WHERE toplevel)::bigint AS query_count,
        coalesce(sum(calls) FILTER (WHERE toplevel), 0)::bigint AS total_calls,
        count(*) FILTER (
            WHERE toplevel AND (
                query LIKE '%advisor-realistic:%'
                OR query LIKE '%advisor-erp:%'
            )
        )::bigint AS tagged_query_count,
        coalesce(sum(calls) FILTER (
            WHERE toplevel AND (
                query LIKE '%advisor-realistic:%'
                OR query LIKE '%advisor-erp:%'
            )
        ), 0)::bigint AS tagged_calls,
        coalesce(
            jsonb_object_agg(
                concat_ws(':', userid::text, dbid::text, queryid::text,
                          CASE WHEN toplevel THEN 't' ELSE 'f' END),
                jsonb_build_array(
                    (extract(epoch FROM stats_since) * 1000000)::bigint,
                    (extract(epoch FROM minmax_stats_since) * 1000000)::bigint
                )
                ORDER BY userid, dbid, queryid, toplevel
            ),
            '{}'::jsonb
        ) AS entries
    FROM pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'appdb')
), observer_roles AS (
    SELECT
        role.oid AS userid,
        role.rolname,
        coalesce((
            SELECT split_part(config.setting, '=', 2)
            FROM unnest(coalesce(role.rolconfig, ARRAY[]::text[])) AS config(setting)
            WHERE split_part(config.setting, '=', 1) = 'pg_stat_statements.track'
            LIMIT 1
        ), current_setting('pg_stat_statements.track')) AS pgss_track,
        coalesce((
            SELECT split_part(config.setting, '=', 2)
            FROM unnest(coalesce(role.rolconfig, ARRAY[]::text[])) AS config(setting)
            WHERE split_part(config.setting, '=', 1) = 'pg_stat_kcache.track'
            LIMIT 1
        ), current_setting('pg_stat_kcache.track')) AS kcache_track
    FROM pg_roles AS role
    WHERE role.rolname IN ('powa_collector', 'advisor_join_reader')
), observer_statement_stats AS (
    SELECT
        observer.userid,
        observer.rolname,
        observer.pgss_track,
        observer.kcache_track,
        count(statement.queryid)::bigint AS statement_count,
        coalesce(sum(statement.calls), 0)::bigint AS calls,
        coalesce(sum(statement.total_plan_time), 0)::double precision AS plan_time_ms,
        coalesce(sum(statement.total_exec_time), 0)::double precision AS exec_time_ms,
        coalesce(
            jsonb_object_agg(
                concat_ws(':', statement.userid::text, statement.dbid::text,
                          statement.queryid::text,
                          CASE WHEN statement.toplevel THEN 't' ELSE 'f' END),
                jsonb_build_array(
                    (extract(epoch FROM statement.stats_since) * 1000000)::bigint,
                    (extract(epoch FROM statement.minmax_stats_since) * 1000000)::bigint
                )
                ORDER BY statement.dbid, statement.queryid, statement.toplevel
            ) FILTER (WHERE statement.queryid IS NOT NULL),
            '{}'::jsonb
        ) AS entry_state
    FROM observer_roles AS observer
    LEFT JOIN pg_stat_statements AS statement ON statement.userid = observer.userid
    GROUP BY observer.userid, observer.rolname, observer.pgss_track,
             observer.kcache_track
), observer_kcache_stats AS (
    SELECT
        observer.userid,
        observer.rolname,
        coalesce(sum(kcache.exec_user_time), 0)::double precision AS cpu_user_seconds,
        coalesce(sum(kcache.exec_system_time), 0)::double precision AS cpu_system_seconds,
        coalesce(sum(kcache.plan_user_time), 0)::double precision AS plan_cpu_user_seconds,
        coalesce(sum(kcache.plan_system_time), 0)::double precision AS plan_cpu_system_seconds,
        coalesce(
            jsonb_object_agg(
                concat_ws(':', kcache.userid::text, kcache.dbid::text,
                          kcache.queryid::text,
                          CASE WHEN kcache.top THEN 't' ELSE 'f' END),
                jsonb_build_array(
                    (extract(epoch FROM kcache.stats_since) * 1000000)::bigint
                )
                ORDER BY kcache.dbid, kcache.queryid, kcache.top
            ) FILTER (WHERE kcache.queryid IS NOT NULL),
            '{}'::jsonb
        ) AS entry_state
    FROM observer_roles AS observer
    LEFT JOIN pg_stat_kcache() AS kcache ON kcache.userid = observer.userid
    GROUP BY observer.userid, observer.rolname
), observer_owned_sql AS (
    SELECT jsonb_build_object(
        'roles', coalesce(jsonb_object_agg(
            statement_stats.rolname,
            jsonb_build_object(
                'pgStatStatementsTrack', statement_stats.pgss_track,
                'pgStatKcacheTrack', statement_stats.kcache_track,
                'statementCount', statement_stats.statement_count,
                'calls', statement_stats.calls,
                'planTimeMs', statement_stats.plan_time_ms,
                'execTimeMs', statement_stats.exec_time_ms,
                'cpuUserSeconds', kcache_stats.cpu_user_seconds,
                'cpuSystemSeconds', kcache_stats.cpu_system_seconds,
                'cpuTotalSeconds',
                    kcache_stats.cpu_user_seconds + kcache_stats.cpu_system_seconds,
                'planCpuUserSeconds', kcache_stats.plan_cpu_user_seconds,
                'planCpuSystemSeconds', kcache_stats.plan_cpu_system_seconds,
                'statementEntryState', statement_stats.entry_state,
                'kcacheEntryState', kcache_stats.entry_state
            ) ORDER BY statement_stats.rolname
        ), '{}'::jsonb),
        'totals', jsonb_build_object(
            'statementCount', coalesce(sum(statement_stats.statement_count), 0)::bigint,
            'calls', coalesce(sum(statement_stats.calls), 0)::bigint,
            'planTimeMs', coalesce(sum(statement_stats.plan_time_ms), 0)::double precision,
            'execTimeMs', coalesce(sum(statement_stats.exec_time_ms), 0)::double precision,
            'cpuUserSeconds', coalesce(sum(kcache_stats.cpu_user_seconds), 0)::double precision,
            'cpuSystemSeconds', coalesce(sum(kcache_stats.cpu_system_seconds), 0)::double precision,
            'cpuTotalSeconds', coalesce(sum(
                kcache_stats.cpu_user_seconds + kcache_stats.cpu_system_seconds
            ), 0)::double precision
        )
    ) AS payload
    FROM observer_statement_stats AS statement_stats
    JOIN observer_kcache_stats AS kcache_stats USING (userid, rolname)
), collector_queries AS (
    SELECT
        count(*)::bigint AS tracked_statement_count,
        count(*) FILTER (
            WHERE userid = (SELECT oid FROM pg_roles WHERE rolname = 'powa_collector')
        )::bigint AS collector_owned_query_count
    FROM pg_stat_statements
), query_info AS (
    SELECT stats_reset, dealloc FROM pg_stat_statements_info
), join_outbox AS (
    SELECT
        count(*)::bigint AS batch_count,
        coalesce(sum(row_count), 0)::bigint AS row_count,
        coalesce(max(row_count), 0)::bigint AS largest_batch_rows,
        CASE WHEN count(*) = 0 THEN 0::double precision
             ELSE extract(epoch FROM clock_timestamp() - min(captured_at))::double precision
        END AS oldest_age_seconds,
        pg_relation_size('advisor_join.outbox_rows') AS payload_bytes,
        pg_total_relation_size('advisor_join.outbox_batches')
          + pg_total_relation_size('advisor_join.outbox_rows') AS storage_bytes
    FROM advisor_join.outbox_batches
)
SELECT json_build_object(
    'databaseSizeBytes', pg_database_size('appdb'),
    'connectionsCurrent', (SELECT numbackends FROM database_stats),
    'maxConnections', current_setting('max_connections')::integer,
    'databaseStats', json_build_object(
        'xactCommit', (SELECT xact_commit FROM database_stats),
        'xactRollback', (SELECT xact_rollback FROM database_stats),
        'blocksRead', (SELECT blks_read FROM database_stats),
        'blocksHit', (SELECT blks_hit FROM database_stats),
        'tempFiles', (SELECT temp_files FROM database_stats),
        'tempBytes', (SELECT temp_bytes FROM database_stats),
        'deadlocks', (SELECT deadlocks FROM database_stats),
        'tuplesInserted', (SELECT tup_inserted FROM database_stats),
        'tuplesUpdated', (SELECT tup_updated FROM database_stats),
        'tuplesDeleted', (SELECT tup_deleted FROM database_stats),
        'sessions', (SELECT sessions FROM database_stats),
        'activeTimeMs', (SELECT active_time FROM database_stats),
        'readTimeMs', (SELECT blk_read_time FROM database_stats),
        'writeTimeMs', (SELECT blk_write_time FROM database_stats),
        'statsReset', (SELECT stats_reset FROM database_stats)
    ),
    'pgStatIo', json_build_object(
        'reads', (SELECT reads FROM io_stats),
        'readBytes', (SELECT read_bytes FROM io_stats),
        'readTimeMs', (SELECT read_time_ms FROM io_stats),
        'writes', (SELECT writes FROM io_stats),
        'writeBytes', (SELECT write_bytes FROM io_stats),
        'writeTimeMs', (SELECT write_time_ms FROM io_stats),
        'writebacks', (SELECT writebacks FROM io_stats),
        'extends', (SELECT extends FROM io_stats),
        'extendBytes', (SELECT extend_bytes FROM io_stats),
        'fsyncs', (SELECT fsyncs FROM io_stats),
        'statsReset', (SELECT stats_reset FROM io_stats)
    ),
    'queries', json_build_object(
        'queryCount', (SELECT query_count FROM query_stats),
        'totalCalls', (SELECT total_calls FROM query_stats),
        'taggedQueryCount', (SELECT tagged_query_count FROM query_stats),
        'taggedCalls', (SELECT tagged_calls FROM query_stats),
        'trackedStatementCount', (SELECT tracked_statement_count FROM collector_queries),
        'collectorOwnedQueryCount', (SELECT collector_owned_query_count FROM collector_queries),
        'dealloc', (SELECT dealloc FROM query_info),
        'maxTrackedStatements', current_setting('pg_stat_statements.max')::integer,
        'statsReset', (SELECT stats_reset FROM query_info),
        'appDbEntryState', (SELECT entries FROM query_stats)
    ),
    'observerOwnedSql', (SELECT payload FROM observer_owned_sql),
    'joinOutbox', json_build_object(
        'batchCount', (SELECT batch_count FROM join_outbox),
        'rowCount', (SELECT row_count FROM join_outbox),
        'largestBatchRows', (SELECT largest_batch_rows FROM join_outbox),
        'oldestAgeSeconds', (SELECT oldest_age_seconds FROM join_outbox),
        'payloadBytes', (SELECT payload_bytes FROM join_outbox),
        'storageBytes', (SELECT storage_bytes FROM join_outbox)
    )
)::text;
"""


def repository_sql(server_id: int, join_retention_days: int) -> str:
    return rf"""
WITH database_stats AS (
    SELECT * FROM pg_stat_database WHERE datname = current_database()
), io_stats AS (
    SELECT
        coalesce(sum(reads), 0)::bigint AS reads,
        coalesce(sum(read_bytes), 0)::numeric AS read_bytes,
        coalesce(sum(read_time), 0)::double precision AS read_time_ms,
        coalesce(sum(writes), 0)::bigint AS writes,
        coalesce(sum(write_bytes), 0)::numeric AS write_bytes,
        coalesce(sum(write_time), 0)::double precision AS write_time_ms,
        coalesce(sum(writebacks), 0)::bigint AS writebacks,
        coalesce(sum(extends), 0)::bigint AS extends,
        coalesce(sum(extend_bytes), 0)::numeric AS extend_bytes,
        coalesce(sum(fsyncs), 0)::bigint AS fsyncs,
        max(stats_reset) AS stats_reset
    FROM pg_stat_io
), tracked_queries AS (
    SELECT
        count(*)::bigint AS statement_series,
        count(DISTINCT (dbid, queryid))::bigint AS query_count
    FROM "PoWA".powa_statements
    WHERE srvid = {server_id}
), history AS (
    SELECT
        (SELECT count(*) FROM "PoWA".powa_statements_history
          WHERE srvid = {server_id})::bigint AS statement_history_chunks,
        (SELECT count(*) FROM "PoWA".powa_statements_history_current
          WHERE srvid = {server_id})::bigint AS statement_current_samples
), join_purge_debt AS (
    SELECT
        count(*) FILTER (
            WHERE captured_at < now() - make_interval(days => {join_retention_days})
        )::bigint AS overdue_batch_count,
        coalesce(sum(row_count) FILTER (
            WHERE captured_at < now() - make_interval(days => {join_retention_days})
        ), 0)::bigint AS overdue_row_count,
        CASE WHEN count(*) FILTER (
            WHERE captured_at < now() - make_interval(days => {join_retention_days})
        ) = 0 THEN 0::double precision ELSE max(
            extract(epoch FROM clock_timestamp() - captured_at)
        ) FILTER (
            WHERE captured_at < now() - make_interval(days => {join_retention_days})
        )::double precision END AS oldest_overdue_age_seconds,
        pg_total_relation_size('advisor_ingest.join_snapshot_batches')
          + pg_total_relation_size('advisor_ingest.join_predicate_samples')
          AS storage_bytes
    FROM advisor_ingest.join_snapshot_batches
    WHERE server_id = {server_id}
), collector AS (
    SELECT
        health.server_id,
        health.status,
        health.lag_seconds,
        cardinality(health.errors) AS error_count,
        health.frequency,
        server.powa_coalesce,
        extension.extversion AS powa_version,
        meta.coalesce_seq AS snapshot_sequence,
        CASE WHEN meta.snapts = '-infinity'::timestamptz THEN NULL
             ELSE to_char(meta.snapts AT TIME ZONE 'UTC',
                          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS snapshot_at,
        CASE WHEN meta.snapts = '-infinity'::timestamptz THEN NULL
             ELSE extract(epoch FROM clock_timestamp() - meta.snapts)::double precision
        END AS snapshot_freshness_seconds,
        CASE WHEN meta.snapts = '-infinity'::timestamptz THEN NULL
             ELSE (extract(epoch FROM meta.snapts) * 1000000)::bigint
        END AS snapshot_epoch_us
    FROM advisor.v_collector_health AS health
    JOIN "PoWA".powa_snapshot_metas AS meta ON meta.srvid = health.server_id
    JOIN "PoWA".powa_servers AS server ON server.id = health.server_id
    JOIN pg_extension AS extension ON extension.extname = 'powa'
    WHERE health.server_id = {server_id}
), join_transport AS (
    SELECT
        coalesce((
            SELECT status.status
            FROM advisor_ingest.join_source_status AS status
            WHERE status.server_id = {server_id}
        ), 'MISSING') AS status,
        (
            SELECT status.last_error
            FROM advisor_ingest.join_source_status AS status
            WHERE status.server_id = {server_id}
        ) AS last_error,
        (
            SELECT count(*)::bigint
            FROM advisor_ingest.join_predicate_staging AS staging
            WHERE staging.server_id = {server_id}
        ) AS staging_rows
)
SELECT json_build_object(
    'databaseSizeBytes', pg_database_size(current_database()),
    'connectionsCurrent', (SELECT numbackends FROM database_stats),
    'maxConnections', current_setting('max_connections')::integer,
    'databaseStats', json_build_object(
        'xactCommit', (SELECT xact_commit FROM database_stats),
        'xactRollback', (SELECT xact_rollback FROM database_stats),
        'blocksRead', (SELECT blks_read FROM database_stats),
        'blocksHit', (SELECT blks_hit FROM database_stats),
        'tempFiles', (SELECT temp_files FROM database_stats),
        'tempBytes', (SELECT temp_bytes FROM database_stats),
        'deadlocks', (SELECT deadlocks FROM database_stats),
        'tuplesInserted', (SELECT tup_inserted FROM database_stats),
        'tuplesUpdated', (SELECT tup_updated FROM database_stats),
        'tuplesDeleted', (SELECT tup_deleted FROM database_stats),
        'sessions', (SELECT sessions FROM database_stats),
        'activeTimeMs', (SELECT active_time FROM database_stats),
        'readTimeMs', (SELECT blk_read_time FROM database_stats),
        'writeTimeMs', (SELECT blk_write_time FROM database_stats),
        'statsReset', (SELECT stats_reset FROM database_stats)
    ),
    'pgStatIo', json_build_object(
        'reads', (SELECT reads FROM io_stats),
        'readBytes', (SELECT read_bytes FROM io_stats),
        'readTimeMs', (SELECT read_time_ms FROM io_stats),
        'writes', (SELECT writes FROM io_stats),
        'writeBytes', (SELECT write_bytes FROM io_stats),
        'writeTimeMs', (SELECT write_time_ms FROM io_stats),
        'writebacks', (SELECT writebacks FROM io_stats),
        'extends', (SELECT extends FROM io_stats),
        'extendBytes', (SELECT extend_bytes FROM io_stats),
        'fsyncs', (SELECT fsyncs FROM io_stats),
        'statsReset', (SELECT stats_reset FROM io_stats)
    ),
    'queries', json_build_object(
        'queryCount', (SELECT query_count FROM tracked_queries),
        'statementSeries', (SELECT statement_series FROM tracked_queries),
        'statementHistoryChunks', (SELECT statement_history_chunks FROM history),
        'statementCurrentSamples', (SELECT statement_current_samples FROM history)
    ),
    'joinPurgeDebt', json_build_object(
        'retentionDays', {join_retention_days},
        'overdueBatchCount', (SELECT overdue_batch_count FROM join_purge_debt),
        'overdueRowCount', (SELECT overdue_row_count FROM join_purge_debt),
        'oldestOverdueAgeSeconds', (SELECT oldest_overdue_age_seconds FROM join_purge_debt),
        'storageBytes', (SELECT storage_bytes FROM join_purge_debt)
    ),
    'joinTransport', json_build_object(
        'status', (SELECT status FROM join_transport),
        'lastError', (SELECT last_error FROM join_transport),
        'stagingRows', (SELECT staging_rows FROM join_transport)
    ),
    'collector', json_build_object(
        'serverId', (SELECT server_id FROM collector),
        'status', (SELECT status FROM collector),
        'lagSeconds', (SELECT lag_seconds FROM collector),
        'errorCount', (SELECT error_count FROM collector),
        'frequencySeconds', (SELECT frequency FROM collector),
        'powaCoalesce', (SELECT powa_coalesce FROM collector),
        'powaVersion', (SELECT powa_version FROM collector),
        'snapshotSequence', (SELECT snapshot_sequence FROM collector),
        'snapshotAt', (SELECT snapshot_at FROM collector),
        'snapshotFreshnessSeconds', (SELECT snapshot_freshness_seconds FROM collector),
        'snapshotEpochUs', (SELECT snapshot_epoch_us FROM collector)
    )
)::text;
"""


CGROUP_SCRIPT = r"""
set -eu
cgroup_version=''
cpu=''
read_bytes=''
write_bytes=''
memory_current=''
memory_peak=''
memory_limit=''
memory_max_events=''
memory_oom_events=''
memory_oom_kill_events=''
if [ -r /sys/fs/cgroup/cpu.stat ]; then
  cgroup_version='2'
  cpu="$(awk '$1 == "usage_usec" {print $2}' /sys/fs/cgroup/cpu.stat)"
elif [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
  cgroup_version='1'
  cpu="$(awk '{printf "%.0f", $1 / 1000}' /sys/fs/cgroup/cpuacct/cpuacct.usage)"
fi
if [ -r /sys/fs/cgroup/io.stat ] && grep -q 'rbytes=' /sys/fs/cgroup/io.stat; then
  read_bytes="$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^rbytes=/) {split($i,a,"="); total+=a[2]}} END {printf "%.0f", total+0}' /sys/fs/cgroup/io.stat)"
  write_bytes="$(awk '{for (i=1; i<=NF; i++) if ($i ~ /^wbytes=/) {split($i,a,"="); total+=a[2]}} END {printf "%.0f", total+0}' /sys/fs/cgroup/io.stat)"
else
  for candidate in \
      /sys/fs/cgroup/blkio/blkio.throttle.io_service_bytes \
      /sys/fs/cgroup/blkio/blkio.io_service_bytes; do
    if [ -r "$candidate" ]; then
      read_bytes="$(awk '$2 == "Read" {total += $3} END {printf "%.0f", total+0}' "$candidate")"
      write_bytes="$(awk '$2 == "Write" {total += $3} END {printf "%.0f", total+0}' "$candidate")"
      break
    fi
  done
fi
if [ -r /sys/fs/cgroup/memory.current ]; then
  cgroup_version='2'
  memory_current="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory.current)"
  if [ -r /sys/fs/cgroup/memory.peak ]; then
    memory_peak="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory.peak)"
  fi
  if [ -r /sys/fs/cgroup/memory.max ]; then
    memory_limit="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory.max)"
  fi
  if [ -r /sys/fs/cgroup/memory.events ]; then
    memory_max_events="$(awk '$1 == "max" {print $2}' /sys/fs/cgroup/memory.events)"
    memory_oom_events="$(awk '$1 == "oom" {print $2}' /sys/fs/cgroup/memory.events)"
    memory_oom_kill_events="$(awk '$1 == "oom_kill" {print $2}' /sys/fs/cgroup/memory.events)"
  fi
elif [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
  cgroup_version='1'
  memory_current="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory/memory.usage_in_bytes)"
  if [ -r /sys/fs/cgroup/memory/memory.max_usage_in_bytes ]; then
    memory_peak="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory/memory.max_usage_in_bytes)"
  fi
  if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    memory_limit="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  fi
  if [ -r /sys/fs/cgroup/memory/memory.failcnt ]; then
    memory_max_events="$(awk 'NR == 1 {print $1}' /sys/fs/cgroup/memory/memory.failcnt)"
  fi
fi
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
  "$cpu" "$read_bytes" "$write_bytes" \
  "$memory_current" "$memory_peak" "$memory_limit" \
  "$memory_max_events" "$memory_oom_events" "$memory_oom_kill_events" \
  "$cgroup_version"
"""


API_PROBE_SCRIPT = r"""
import concurrent.futures
import json
import sys
import time
import urllib.parse
import urllib.request

server_id = int(sys.argv[1])
concurrency = int(sys.argv[2])
request_timeout = float(sys.argv[3])
endpoint = sys.argv[4]
query_list_url = (
    "http://127.0.0.1:8000/api/v1/queries"
    f"?window=24h&pageSize=50&serverId={server_id}"
)
overview_url = "http://127.0.0.1:8000/api/v1/overview?window=24h"
headers = {"X-Advisor-Role": "analyst"}

if endpoint not in {"query-list", "overview", "query-detail"}:
    raise RuntimeError(f"unsupported probe endpoint: {endpoint}")

detail_url = None
if endpoint == "query-detail":
    if len(sys.argv) != 8:
        raise RuntimeError("query-detail probe target is missing")
    query_id = sys.argv[5]
    selected_server_id = int(sys.argv[6])
    database_id = int(sys.argv[7])
    if not query_id.lstrip("-").isdigit():
        raise RuntimeError("selected queryId is not numeric")
    detail_query = urllib.parse.urlencode(
        {
            "window": "24h",
            "serverId": selected_server_id,
            "databaseId": database_id,
        }
    )
    detail_url = (
        "http://127.0.0.1:8000/api/v1/queries/"
        f"{urllib.parse.quote(query_id, safe='-')}?{detail_query}"
    )

def request_once():
    url = {
        "query-list": query_list_url,
        "overview": overview_url,
        "query-detail": detail_url,
    }[endpoint]
    request = urllib.request.Request(url, headers=headers)
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=request_timeout) as response:
        payload = json.load(response)
    latency = time.perf_counter() - started
    if not isinstance(payload, dict):
        raise RuntimeError(f"API response is not an object: {url}")
    result = {
        "endpoint": endpoint,
        "latencySeconds": latency,
        "itemCount": None,
    }
    if endpoint == "query-list":
        items = payload.get("items")
        if not isinstance(items, list):
            raise RuntimeError("query-list response has no items array")
        result["itemCount"] = len(items)
        if items:
            selected = items[0]
            if not isinstance(selected, dict):
                raise RuntimeError("query-list item is not an object")
            selected_query_id = str(selected.get("queryId"))
            selected_server_id = selected.get("serverId")
            selected_database_id = selected.get("databaseId")
            if not selected_query_id.lstrip("-").isdigit():
                raise RuntimeError("selected queryId is not numeric")
            if (
                not isinstance(selected_server_id, int)
                or isinstance(selected_server_id, bool)
                or not isinstance(selected_database_id, int)
                or isinstance(selected_database_id, bool)
            ):
                raise RuntimeError("selected query is missing serverId or databaseId")
            result["selectedQuery"] = {
                "queryId": selected_query_id,
                "serverId": selected_server_id,
                "databaseId": selected_database_id,
            }
    elif endpoint == "overview":
        if (
            not isinstance(payload.get("cards"), dict)
            or not isinstance(payload.get("topQueries"), list)
            or not isinstance(payload.get("trend"), list)
        ):
            raise RuntimeError("overview response is missing cards, topQueries, or trend")
    elif (
        str(payload.get("queryId")) != query_id
        or not isinstance(payload.get("trend"), list)
    ):
        raise RuntimeError("query-detail response is missing queryId or trend")
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
    results = list(executor.map(lambda _: request_once(), range(concurrency)))
print(json.dumps(results, separators=(",", ":")))
"""


class BenchmarkError(RuntimeError):
    pass


class CommandRunner:
    def run(
        self,
        args: Sequence[str],
        *,
        capture: bool = True,
        check: bool = True,
        timeout: float | None = 30,
        env: Mapping[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            list(args),
            cwd=ROOT,
            env=dict(env) if env is not None else None,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout,
            check=False,
        )
        if check and result.returncode != 0:
            detail = (result.stderr or result.stdout or "command failed").strip()
            raise BenchmarkError(f"{' '.join(args[:3])}: {detail[-2000:]}")
        return result

    def start(
        self,
        args: Sequence[str],
        *,
        capture: bool = False,
        env: Mapping[str, str] | None = None,
    ) -> subprocess.Popen[str]:
        """Start the wrapped workload without blocking on its post-load checks."""

        return subprocess.Popen(
            list(args),
            cwd=ROOT,
            env=dict(env) if env is not None else None,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            start_new_session=True,
        )


@dataclass(frozen=True)
class DockerContext:
    project: str
    compose_file: str
    source_container: str
    repository_container: str
    api_container: str
    snapshotter_container: str
    source_alias: str
    server_id: int
    source_frequency: int
    join_retention_days: int


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def validate_sync_directory(directory: pathlib.Path) -> pathlib.Path:
    """Resolve a caller-created private directory used only for one handshake."""

    if not directory.is_absolute():
        raise BenchmarkError("benchmark sync dizini mutlak bir yol olmali")
    try:
        resolved = directory.resolve(strict=True)
        metadata = resolved.stat()
    except OSError as exc:
        raise BenchmarkError("benchmark sync dizini okunamadi") from exc
    if not stat.S_ISDIR(metadata.st_mode):
        raise BenchmarkError("benchmark sync yolu bir dizin olmali")
    if hasattr(os, "geteuid") and metadata.st_uid != os.geteuid():
        raise BenchmarkError("benchmark sync dizini mevcut kullaniciya ait olmali")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise BenchmarkError(
            "benchmark sync dizini yalniz sahibi tarafindan erisilebilir olmali"
        )
    return resolved


def sync_path(directory: pathlib.Path, phase: str, kind: str) -> pathlib.Path:
    if phase not in SYNC_PHASES or kind not in {"ready", "continue"}:
        raise BenchmarkError("gecersiz benchmark sync fazi")
    return directory / f"{phase}-{kind}.json"


def atomic_write_sync_payload(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    """Publish a small JSON marker atomically inside a private sync directory."""

    encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )
    if len(encoded) > SYNC_MAX_PAYLOAD_BYTES:
        raise BenchmarkError("benchmark sync payload boyutu siniri asti")
    if path.exists():
        raise BenchmarkError(f"benchmark sync marker zaten var: {path.name}")
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}.tmp"
    )
    descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            raise BenchmarkError(f"benchmark sync marker yarista olustu: {path.name}")
        os.replace(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_sync_payload(path: pathlib.Path) -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        raise
    except OSError as exc:
        raise BenchmarkError(f"benchmark sync marker acilamadi: {path.name}") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > SYNC_MAX_PAYLOAD_BYTES:
            raise BenchmarkError(f"benchmark sync marker guvenli degil: {path.name}")
        chunks: list[bytes] = []
        remaining = SYNC_MAX_PAYLOAD_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(descriptor)
    raw = b"".join(chunks)
    if len(raw) > SYNC_MAX_PAYLOAD_BYTES:
        raise BenchmarkError(f"benchmark sync marker cok buyuk: {path.name}")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BenchmarkError(f"benchmark sync marker JSON degil: {path.name}") from exc
    if not isinstance(payload, dict):
        raise BenchmarkError(f"benchmark sync marker nesne olmali: {path.name}")
    return payload


def wait_for_sync_payload(
    path: pathlib.Path,
    *,
    timeout_seconds: float,
    process: subprocess.Popen[str] | None = None,
    poll_seconds: float = 0.05,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            return read_sync_payload(path)
        except FileNotFoundError:
            pass
        if process is not None and process.poll() is not None:
            raise BenchmarkError(
                f"realistic wrapper {path.name} yayinlamadan cikti: {process.returncode}"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BenchmarkError(f"benchmark sync marker zaman asimi: {path.name}")
        time.sleep(min(poll_seconds, remaining))


def validate_phase_payload(
    payload: Mapping[str, Any], phase: str, expected_status: str
) -> None:
    if (
        payload.get("protocolVersion") != SYNC_PROTOCOL_VERSION
        or payload.get("phase") != phase
        or payload.get("status") != expected_status
    ):
        raise BenchmarkError(
            f"benchmark sync protokolu gecersiz: {phase}/{expected_status}"
        )


def publish_phase_response(
    directory: pathlib.Path, phase: str, *, status_value: str = "continue"
) -> None:
    if status_value not in {"continue", "abort"}:
        raise BenchmarkError("benchmark sync response gecersiz")
    atomic_write_sync_payload(
        sync_path(directory, phase, "continue"),
        {
            "protocolVersion": SYNC_PROTOCOL_VERSION,
            "phase": phase,
            "status": status_value,
            "createdAt": utc_now(),
        },
    )


def workload_boundary_handshake(
    directory: pathlib.Path, phase: str, timeout_seconds: float
) -> None:
    """Called by the shell wrapper immediately around the workload pipeline."""

    if phase not in SYNC_PHASES:
        raise BenchmarkError("benchmark sync fazi start veya end olmali")
    if not 1 <= timeout_seconds <= 3600:
        raise BenchmarkError("benchmark sync timeout 1..3600 saniye arasinda olmali")
    resolved = validate_sync_directory(directory)
    ready_path = sync_path(resolved, phase, "ready")
    continue_path = sync_path(resolved, phase, "continue")
    if continue_path.exists():
        raise BenchmarkError(
            f"benchmark sync response erken olustu: {continue_path.name}"
        )
    atomic_write_sync_payload(
        ready_path,
        {
            "protocolVersion": SYNC_PROTOCOL_VERSION,
            "phase": phase,
            "status": "ready",
            "createdAt": utc_now(),
        },
    )
    response = wait_for_sync_payload(
        continue_path,
        timeout_seconds=timeout_seconds,
    )
    response_status = response.get("status")
    if response_status not in {"continue", "abort"}:
        raise BenchmarkError(f"benchmark {phase} response durumu gecersiz")
    validate_phase_payload(response, phase, response_status)
    if response_status != "continue":
        raise BenchmarkError(f"benchmark {phase} fazini iptal etti")


def stop_process(process: subprocess.Popen[str]) -> None:
    """Stop only the child process group created for this benchmark run."""

    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait(timeout=10)


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise BenchmarkError(f"{name} true/false olmali")


def env_int(name: str, default: int, *, minimum: int = 0) -> int:
    value = os.environ.get(name, str(default))
    if not re.fullmatch(r"[0-9]+", value):
        raise BenchmarkError(f"{name} negatif olmayan tam sayi olmali")
    parsed = int(value)
    if parsed < minimum:
        raise BenchmarkError(f"{name} en az {minimum} olmali")
    return parsed


def env_float(name: str, default: float, *, minimum: float = 0.0) -> float:
    try:
        parsed = float(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise BenchmarkError(f"{name} sayisal olmali") from exc
    if not math.isfinite(parsed) or parsed < minimum:
        raise BenchmarkError(f"{name} sonlu ve en az {minimum} olmali")
    return parsed


def require_source_frequency(frequency_seconds: int) -> int:
    minimum = env_int("ERP_MIN_SOURCE_FREQUENCY_SECONDS", 30)
    if minimum and frequency_seconds < minimum:
        raise BenchmarkError(
            "Source toplama araligi ERP benchmark icin cok sik: "
            f"current={frequency_seconds}s, minimum={minimum}s. "
            "Mevcut kaydi scripts/register-source.sh --frequency 60 ile "
            "guncelleyin; yalniz bilincli worst-case testinde "
            "ERP_MIN_SOURCE_FREQUENCY_SECONDS=0 kullanin."
        )
    return minimum


def require_clean_baseline(snapshot_value: Mapping[str, Any]) -> None:
    issues: list[str] = []
    collector_status = value_at(
        snapshot_value, "repository", "postgres", "collector", "status"
    )
    collector_errors = value_at(
        snapshot_value, "repository", "postgres", "collector", "errorCount"
    )
    if collector_status != "HEALTHY" or collector_errors != 0:
        issues.append(
            f"collector={collector_status!r}/errors={collector_errors!r}"
        )

    outbox_batches = value_at(
        snapshot_value, "source", "postgres", "joinOutbox", "batchCount"
    )
    outbox_rows = value_at(
        snapshot_value, "source", "postgres", "joinOutbox", "rowCount"
    )
    if outbox_batches != 0 or outbox_rows != 0:
        issues.append(f"joinOutbox={outbox_batches!r} batches/{outbox_rows!r} rows")

    join_status = value_at(
        snapshot_value, "repository", "postgres", "joinTransport", "status"
    )
    join_error = value_at(
        snapshot_value, "repository", "postgres", "joinTransport", "lastError"
    )
    staging_rows = value_at(
        snapshot_value, "repository", "postgres", "joinTransport", "stagingRows"
    )
    if join_status != "HEALTHY" or join_error not in {None, ""}:
        issues.append(f"joinTransport={join_status!r}/error={join_error!r}")
    if staging_rows != 0:
        issues.append(f"joinStagingRows={staging_rows!r}")

    if issues:
        raise BenchmarkError(
            "Benchmark baseline temiz degil; recovery/backlog maliyeti olcume "
            "karismamali: " + "; ".join(issues)
        )


def _lines(value: str) -> list[str]:
    return [line.strip() for line in value.splitlines() if line.strip()]


def resolve_context(runner: CommandRunner) -> DockerContext:
    project = os.environ.get("ADVISOR_COMPOSE_PROJECT") or os.environ.get(
        "COMPOSE_PROJECT_NAME"
    )
    if not project:
        result = runner.run(
            [
                "docker",
                "ps",
                "--filter",
                "label=com.docker.compose.service=source-db",
                "--format",
                '{{.Label "com.docker.compose.project"}}',
            ]
        )
        projects = sorted(set(_lines(result.stdout)))
        if len(projects) != 1:
            raise BenchmarkError(
                "Tek calisan advisor projesi bulunamadi; COMPOSE_PROJECT_NAME ayarlayin"
            )
        project = projects[0]
    if not PROJECT_NAME.fullmatch(project):
        raise BenchmarkError(f"Guvenli olmayan Compose proje adi: {project}")

    def container_for(service: str) -> str:
        result = runner.run(
            [
                "docker",
                "ps",
                "--filter",
                f"label=com.docker.compose.project={project}",
                "--filter",
                f"label=com.docker.compose.service={service}",
                "--format",
                "{{.ID}}",
            ]
        )
        ids = _lines(result.stdout)
        if len(ids) != 1 or not CONTAINER_ID.fullmatch(ids[0]):
            raise BenchmarkError(
                f"{project}/{service} icin bir calisan container bekleniyordu"
            )
        return ids[0]

    source = container_for("source-db")
    repository = container_for("repository-db")
    api = container_for("api")
    snapshotter = container_for("join-snapshotter")
    compose_file = os.environ.get("COMPOSE_FILE", "").strip()
    if not compose_file:
        config_result = runner.run(
            [
                "docker",
                "inspect",
                "--format",
                '{{index .Config.Labels "com.docker.compose.project.config_files"}}',
                source,
            ]
        )
        config_files = [
            item.strip() for item in config_result.stdout.strip().split(",") if item.strip()
        ]
        if not config_files or any("\n" in item or "\x00" in item for item in config_files):
            raise BenchmarkError("Calisan Compose config dosyalari bulunamadi")
        compose_file = os.pathsep.join(config_files)
    alias_result = runner.run(
        ["docker", "exec", repository, "printenv", "JOIN_SOURCE_ALIAS"],
        check=False,
    )
    alias = alias_result.stdout.strip() if alias_result.returncode == 0 else "test-source"
    alias = alias or "test-source"
    if not SOURCE_ALIAS.fullmatch(alias):
        raise BenchmarkError(f"Guvenli olmayan source alias: {alias}")
    server_result = psql(
        runner,
        repository,
        "powa_repository",
        f'SELECT id || \'|\' || frequency FROM "PoWA".powa_servers WHERE alias=\'{alias}\';',
        port=5433,
        raw=True,
    )
    parts = server_result.split("|")
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        raise BenchmarkError(f"PoWA source kaydi bulunamadi: {alias}")
    retention_result = runner.run(
        ["docker", "exec", snapshotter, "printenv", "JOIN_RETENTION_DAYS"],
        check=False,
    )
    retention_raw = (
        retention_result.stdout.strip() if retention_result.returncode == 0 else "30"
    )
    if not retention_raw.isdigit() or not 1 <= int(retention_raw) <= 365:
        raise BenchmarkError("JOIN_RETENTION_DAYS 1..365 arasinda olmali")
    return DockerContext(
        project,
        compose_file,
        source,
        repository,
        api,
        snapshotter,
        alias,
        int(parts[0]),
        int(parts[1]),
        int(retention_raw),
    )


def psql(
    runner: CommandRunner,
    container: str,
    database: str,
    statement: str,
    *,
    port: int | None = None,
    raw: bool = False,
) -> Any:
    args = [
        "docker",
        "exec",
        container,
        "psql",
        "-X",
        "--set=ON_ERROR_STOP=1",
        "--username=postgres",
        f"--dbname={database}",
        "--quiet",
        "--tuples-only",
        "--no-align",
    ]
    if port is not None:
        args.append(f"--port={port}")
    args.extend(["--command", statement])
    output = runner.run(args, timeout=20).stdout.strip()
    if raw:
        return output
    candidates = [line for line in _lines(output) if line.startswith("{")]
    if not candidates:
        raise BenchmarkError("PostgreSQL metric sorgusu JSON dondurmedi")
    try:
        value = json.loads(candidates[-1])
    except json.JSONDecodeError as exc:
        raise BenchmarkError("PostgreSQL metric JSON'i parse edilemedi") from exc
    if not isinstance(value, dict):
        raise BenchmarkError("PostgreSQL metric sonucu nesne degil")
    return value


def parse_cgroup(value: str) -> dict[str, int | bool | None]:
    parts = value.strip().split("|")
    if len(parts) != 10:
        raise BenchmarkError("cgroup metric formati gecersiz")

    def number(item: str) -> int | None:
        if not item:
            return None
        if not item.isdigit():
            raise BenchmarkError("cgroup sayaci sayisal degil")
        return int(item)

    limit_raw = parts[5]
    if limit_raw == "max":
        memory_limit: int | None = None
        memory_limit_unlimited: bool | None = True
    elif limit_raw:
        parsed_limit = number(limit_raw)
        if parsed_limit is None:  # guarded by the non-empty branch
            raise BenchmarkError("cgroup bellek limiti sayisal degil")
        # cgroup v1 represents an unlimited hierarchy with a huge signed-long
        # sentinel instead of cgroup v2's explicit ``max`` token.
        if parsed_limit >= 1 << 60:
            memory_limit = None
            memory_limit_unlimited = True
        else:
            memory_limit = parsed_limit
            memory_limit_unlimited = False
    else:
        memory_limit = None
        memory_limit_unlimited = None

    version_raw = parts[9]
    if version_raw not in {"", "1", "2"}:
        raise BenchmarkError("cgroup surumu 1 veya 2 olmali")

    return {
        "cpuUsageUsec": number(parts[0]),
        "ioReadBytes": number(parts[1]),
        "ioWriteBytes": number(parts[2]),
        "memoryCurrentBytes": number(parts[3]),
        "memoryLifetimePeakBytes": number(parts[4]),
        "memoryLimitBytes": memory_limit,
        "memoryLimitUnlimited": memory_limit_unlimited,
        "memoryMaxEvents": number(parts[6]),
        "memoryOomEvents": number(parts[7]),
        "memoryOomKillEvents": number(parts[8]),
        "cgroupVersion": int(version_raw) if version_raw else None,
    }


def cgroup_metrics(
    runner: CommandRunner, container: str, *, include_started_at: bool = True
) -> dict[str, Any]:
    result = runner.run(
        ["docker", "exec", container, "sh", "-c", CGROUP_SCRIPT], timeout=10
    )
    metrics: dict[str, Any] = parse_cgroup(result.stdout)
    if include_started_at:
        started_at = runner.run(
            ["docker", "inspect", "--format", "{{.State.StartedAt}}", container],
            timeout=10,
        ).stdout.strip()
        metrics["startedAt"] = started_at or None
    return metrics


def capture_snapshot(
    runner: CommandRunner,
    context: DockerContext,
    *,
    container_boundary: str = "first",
    boundary_callback: Callable[[], None] | None = None,
) -> dict[str, Any]:
    """Capture metrics while excluding the metric SQL from cgroup deltas.

    A baseline reads PostgreSQL first and cgroups last. A final snapshot reads
    cgroups first and PostgreSQL last. The measured cgroup interval therefore
    starts after baseline metric SQL and ends before final metric SQL.
    """

    if container_boundary not in {"first", "last"}:
        raise BenchmarkError("container boundary first veya last olmali")

    def containers() -> tuple[dict[str, Any], dict[str, Any]]:
        return (
            cgroup_metrics(runner, context.source_container),
            cgroup_metrics(runner, context.repository_container),
        )

    container_boundary_at: str
    if container_boundary == "first":
        source_container, repository_container = containers()
        container_boundary_at = utc_now()
        if boundary_callback is not None:
            boundary_callback()
    source_postgres = psql(runner, context.source_container, "powa", SOURCE_SQL)
    repository_postgres = psql(
        runner,
        context.repository_container,
        "powa_repository",
        repository_sql(context.server_id, context.join_retention_days),
        port=5433,
    )
    if container_boundary == "last":
        source_container, repository_container = containers()
        container_boundary_at = utc_now()
        if boundary_callback is not None:
            boundary_callback()
    return {
        "capturedAt": utc_now(),
        "containerBoundary": container_boundary,
        "containerBoundaryAt": container_boundary_at,
        "source": {
            "container": source_container,
            "postgres": source_postgres,
        },
        "repository": {
            "container": repository_container,
            "postgres": repository_postgres,
        },
    }


def capture_clean_baseline(
    runner: CommandRunner,
    context: DockerContext,
    *,
    timeout_seconds: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    last_error: BenchmarkError | None = None
    while True:
        candidate = capture_snapshot(runner, context, container_boundary="last")
        try:
            require_clean_baseline(candidate)
            return candidate
        except BenchmarkError as exc:
            last_error = exc
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BenchmarkError(
                f"Clean baseline {timeout_seconds}s icinde olusmadi: {last_error}"
            ) from last_error
        print(f"ERP benchmark clean baseline bekliyor: {last_error}")
        time.sleep(min(2.0, remaining))


def capture_sample(runner: CommandRunner, context: DockerContext) -> dict[str, Any]:
    source = psql(
        runner,
        context.source_container,
        "powa",
        "SELECT json_build_object('connections', numbackends)::text "
        "FROM pg_stat_database WHERE datname='appdb';",
    )
    repository = psql(
        runner,
        context.repository_container,
        "powa_repository",
        rf"""
SELECT json_build_object(
  'connections', database_stats.numbackends,
  'collectorLagSeconds', health.lag_seconds,
  'serverId', health.server_id,
  'powaCoalesce', server.powa_coalesce,
  'powaVersion', extension.extversion,
  'snapshotSequence', meta.coalesce_seq,
  'snapshotFreshnessSeconds', CASE
    WHEN meta.snapts='-infinity'::timestamptz THEN NULL
    ELSE extract(epoch FROM clock_timestamp()-meta.snapts)::double precision END,
  'snapshotEpochUs', CASE
    WHEN meta.snapts='-infinity'::timestamptz THEN NULL
    ELSE (extract(epoch FROM meta.snapts) * 1000000)::bigint END
)::text
FROM pg_stat_database AS database_stats
CROSS JOIN advisor.v_collector_health AS health
JOIN "PoWA".powa_snapshot_metas AS meta ON meta.srvid=health.server_id
JOIN "PoWA".powa_servers AS server ON server.id=health.server_id
JOIN pg_extension AS extension ON extension.extname='powa'
WHERE database_stats.datname=current_database() AND health.server_id={context.server_id};
""",
        port=5433,
    )
    return {
        "capturedAt": utc_now(),
        "source": {
            **source,
            "container": cgroup_metrics(
                runner, context.source_container, include_started_at=False
            ),
        },
        "repository": {
            **repository,
            "container": cgroup_metrics(
                runner, context.repository_container, include_started_at=False
            ),
        },
    }


def capture_api_probe(
    runner: CommandRunner,
    context: DockerContext,
    concurrency: int,
    *,
    request_timeout_seconds: float = 15.0,
    endpoint: str = "query-list",
    detail_target: Mapping[str, Any] | None = None,
) -> list[dict[str, Any]]:
    if not 1.0 <= request_timeout_seconds <= 120.0:
        raise BenchmarkError("API probe timeout 1..120 saniye arasinda olmali")
    if endpoint not in {"query-list", "overview", "query-detail"}:
        raise BenchmarkError("API probe endpoint'i gecersiz")
    detail_arguments: list[str] = []
    if endpoint == "query-detail":
        if not isinstance(detail_target, Mapping):
            raise BenchmarkError("API query-detail probe hedefi eksik")
        query_id = str(detail_target.get("queryId"))
        selected_server_id = detail_target.get("serverId")
        database_id = detail_target.get("databaseId")
        if not query_id.lstrip("-").isdigit():
            raise BenchmarkError("API query-detail queryId hedefi gecersiz")
        if (
            not isinstance(selected_server_id, int)
            or isinstance(selected_server_id, bool)
            or not isinstance(database_id, int)
            or isinstance(database_id, bool)
        ):
            raise BenchmarkError("API query-detail server/database hedefi gecersiz")
        detail_arguments = [query_id, str(selected_server_id), str(database_id)]
    result = runner.run(
        [
            "docker",
            "exec",
            context.api_container,
            "python",
            "-c",
            API_PROBE_SCRIPT,
            str(context.server_id),
            str(concurrency),
            str(request_timeout_seconds),
            endpoint,
            *detail_arguments,
        ],
        timeout=request_timeout_seconds + 10.0,
    )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise BenchmarkError("API latency probe JSON'i parse edilemedi") from exc
    if not isinstance(payload, list) or len(payload) != concurrency:
        raise BenchmarkError("API latency probe eksik sonuc dondurdu")
    normalized: list[dict[str, Any]] = []
    for item in payload:
        if not isinstance(item, dict):
            raise BenchmarkError("API latency probe sonucu nesne degil")
        item_endpoint = item.get("endpoint")
        latency = item.get("latencySeconds")
        item_count = item.get("itemCount")
        if item_endpoint != endpoint:
            raise BenchmarkError("API latency probe endpoint'i gecersiz")
        if (
            not isinstance(latency, (int, float))
            or isinstance(latency, bool)
            or latency < 0
        ):
            raise BenchmarkError("API latency probe metrikleri gecersiz")
        if endpoint == "query-list":
            if (
                not isinstance(item_count, int)
                or isinstance(item_count, bool)
                or item_count < 0
            ):
                raise BenchmarkError("API latency probe metrikleri gecersiz")
        elif item_count is not None:
            raise BenchmarkError("API latency probe metrikleri gecersiz")
        normalized_item: dict[str, Any] = {
            "endpoint": endpoint,
            "latencySeconds": float(latency),
            "itemCount": item_count,
        }
        selected_query = item.get("selectedQuery")
        if selected_query is not None:
            if endpoint != "query-list" or not isinstance(selected_query, dict):
                raise BenchmarkError("API latency probe secili sorgusu gecersiz")
            selected_query_id = str(selected_query.get("queryId"))
            selected_server_id = selected_query.get("serverId")
            selected_database_id = selected_query.get("databaseId")
            if (
                not selected_query_id.lstrip("-").isdigit()
                or not isinstance(selected_server_id, int)
                or isinstance(selected_server_id, bool)
                or not isinstance(selected_database_id, int)
                or isinstance(selected_database_id, bool)
            ):
                raise BenchmarkError("API latency probe secili sorgusu gecersiz")
            normalized_item["selectedQuery"] = {
                "queryId": selected_query_id,
                "serverId": selected_server_id,
                "databaseId": selected_database_id,
            }
        if endpoint == "query-list" and item_count > 0 and selected_query is None:
            raise BenchmarkError("API latency probe secili sorgusu eksik")
        if endpoint == "query-list" and item_count == 0 and selected_query is not None:
            raise BenchmarkError("API latency probe secili sorgusu gecersiz")
        normalized.append(normalized_item)
    return normalized


def wait_for_repository_cache_refresh(
    runner: CommandRunner,
    context: DockerContext,
    *,
    timeout_seconds: float = 60.0,
    idle_stability_seconds: float = 2.0,
) -> None:
    """Keep the measurement open until probe-triggered refresh SQL is idle.

    Query-list and global-trend responses use stale-while-revalidate, so the
    HTTP request can finish before their repository refresh.  Waiting for a
    stable idle period makes that CPU/I/O part of the same benchmark boundary
    instead of leaking into the postlude or the next run.
    """
    if timeout_seconds <= 0 or idle_stability_seconds <= 0:
        raise BenchmarkError("API cache idle bekleme sureleri pozitif olmali")
    deadline = time.monotonic() + timeout_seconds
    idle_since: float | None = None
    statement = """
        SELECT count(*)
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND state <> 'idle'
          AND (
              application_name = 'advisor-query-metrics-cache-refresh'
              OR application_name = 'advisor-global-trend-cache-refresh'
              OR query LIKE '%%advisor-query-metrics-cache-refresh%%'
              OR query LIKE '%%advisor-global-trend-cache-refresh%%'
          )
    """
    while True:
        raw_count = psql(
            runner,
            context.repository_container,
            "powa_repository",
            statement,
            port=5433,
            raw=True,
        )
        if not raw_count.isdigit():
            raise BenchmarkError("API metrics-cache activity sayaci gecersiz")
        now_monotonic = time.monotonic()
        if int(raw_count) == 0:
            if idle_since is None:
                idle_since = now_monotonic
            elif now_monotonic - idle_since >= idle_stability_seconds:
                return
        else:
            idle_since = None
        if now_monotonic >= deadline:
            raise BenchmarkError(
                "API metrics-cache refresh repository'de zamaninda tamamlanmadi"
            )
        time.sleep(min(0.25, max(deadline - now_monotonic, 0.0)))


def value_at(data: Mapping[str, Any], *path: str) -> Any:
    value: Any = data
    for part in path:
        if not isinstance(value, Mapping):
            return None
        value = value.get(part)
    return value


def subtract(after: Any, before: Any) -> float | int | None:
    if isinstance(after, bool) or isinstance(before, bool):
        return None
    if not isinstance(after, (int, float)) or not isinstance(before, (int, float)):
        return None
    return after - before


def calculate_entry_continuity(
    before: Any, after: Any, *, state_width: int
) -> dict[str, Any]:
    """Prove that every baseline counter entry survived with the same epoch."""

    def valid_state(value: Any) -> bool:
        return isinstance(value, list) and len(value) == state_width and all(
            isinstance(item, int) and not isinstance(item, bool) for item in value
        )

    if (
        not isinstance(before, Mapping)
        or not isinstance(after, Mapping)
        or any(
            not isinstance(key, str) or not valid_state(value)
            for key, value in before.items()
        )
        or any(
            not isinstance(key, str) or not valid_state(value)
            for key, value in after.items()
        )
    ):
        return {
            "stateValid": False,
            "beforeEntryCount": len(before) if isinstance(before, Mapping) else None,
            "afterEntryCount": len(after) if isinstance(after, Mapping) else None,
            "missingEntryCount": None,
            "resetEntryCount": None,
            "missingEntryKeys": [],
            "resetEntryKeys": [],
        }

    missing = sorted(key for key in before if key not in after)
    reset = sorted(
        key for key, stats_since in before.items()
        if key in after and after[key] != stats_since
    )
    return {
        "stateValid": True,
        "beforeEntryCount": len(before),
        "afterEntryCount": len(after),
        "missingEntryCount": len(missing),
        "resetEntryCount": len(reset),
        # Keep the diagnostic bounded even if a broad scoped reset affects the
        # full 50k-entry capacity. The complete before/after maps remain in the
        # JSON snapshots for offline analysis.
        "missingEntryKeys": missing[:20],
        "resetEntryKeys": reset[:20],
    }


def calculate_pgss_continuity(before: Any, after: Any) -> dict[str, Any]:
    """Detect scoped pg_stat_statements resets that do not move global time."""

    return calculate_entry_continuity(before, after, state_width=2)


def calculate_kcache_continuity(before: Any, after: Any) -> dict[str, Any]:
    """Detect pg_stat_kcache entry reset/eviction before subtracting CPU."""

    return calculate_entry_continuity(before, after, state_width=1)


def calculate_delta(before: Mapping[str, Any], after: Mapping[str, Any]) -> dict[str, Any]:
    database_counters = (
        "xactCommit",
        "xactRollback",
        "blocksRead",
        "blocksHit",
        "tempFiles",
        "tempBytes",
        "deadlocks",
        "tuplesInserted",
        "tuplesUpdated",
        "tuplesDeleted",
        "sessions",
        "activeTimeMs",
        "readTimeMs",
        "writeTimeMs",
    )
    io_counters = (
        "reads",
        "readBytes",
        "readTimeMs",
        "writes",
        "writeBytes",
        "writeTimeMs",
        "writebacks",
        "extends",
        "extendBytes",
        "fsyncs",
    )
    result: dict[str, Any] = {"counterDecreases": []}
    for target in ("source", "repository"):
        before_target = value_at(before, target) or {}
        after_target = value_at(after, target) or {}
        target_delta: dict[str, Any] = {
            "container": {},
            "postgres": {
                "databaseStats": {},
                "pgStatIo": {},
                "queries": {},
            },
        }
        for counter in (
            "cpuUsageUsec",
            "ioReadBytes",
            "ioWriteBytes",
            "memoryLifetimePeakBytes",
            "memoryMaxEvents",
            "memoryOomEvents",
            "memoryOomKillEvents",
        ):
            delta = subtract(
                value_at(after_target, "container", counter),
                value_at(before_target, "container", counter),
            )
            target_delta["container"][counter] = delta
            if delta is not None and delta < 0:
                result["counterDecreases"].append(f"{target}.container.{counter}")
        target_delta["container"]["memoryCurrentBytes"] = subtract(
            value_at(after_target, "container", "memoryCurrentBytes"),
            value_at(before_target, "container", "memoryCurrentBytes"),
        )
        target_delta["container"]["memoryLimitBytes"] = value_at(
            after_target, "container", "memoryLimitBytes"
        )
        target_delta["container"]["memoryLimitUnlimited"] = value_at(
            after_target, "container", "memoryLimitUnlimited"
        )
        target_delta["container"]["cgroupVersion"] = value_at(
            after_target, "container", "cgroupVersion"
        )
        target_delta["container"]["cpuUsageSeconds"] = (
            target_delta["container"]["cpuUsageUsec"] / 1_000_000
            if target_delta["container"]["cpuUsageUsec"] is not None
            else None
        )
        target_delta["postgres"]["databaseSizeBytes"] = subtract(
            value_at(after_target, "postgres", "databaseSizeBytes"),
            value_at(before_target, "postgres", "databaseSizeBytes"),
        )
        target_delta["postgres"]["connectionsCurrent"] = subtract(
            value_at(after_target, "postgres", "connectionsCurrent"),
            value_at(before_target, "postgres", "connectionsCurrent"),
        )
        for counter in database_counters:
            delta = subtract(
                value_at(after_target, "postgres", "databaseStats", counter),
                value_at(before_target, "postgres", "databaseStats", counter),
            )
            target_delta["postgres"]["databaseStats"][counter] = delta
            if delta is not None and delta < 0:
                result["counterDecreases"].append(
                    f"{target}.postgres.databaseStats.{counter}"
                )
        for counter in io_counters:
            delta = subtract(
                value_at(after_target, "postgres", "pgStatIo", counter),
                value_at(before_target, "postgres", "pgStatIo", counter),
            )
            target_delta["postgres"]["pgStatIo"][counter] = delta
            if delta is not None and delta < 0:
                result["counterDecreases"].append(
                    f"{target}.postgres.pgStatIo.{counter}"
                )
        query_counters = (
            ("queryCount", False),
            ("totalCalls", True),
            ("taggedQueryCount", False),
            ("taggedCalls", True),
            ("trackedStatementCount", False),
            ("collectorOwnedQueryCount", False),
            ("dealloc", True),
            ("statementSeries", False),
            ("statementHistoryChunks", False),
            ("statementCurrentSamples", False),
        )
        for counter, cumulative in query_counters:
            delta = subtract(
                value_at(after_target, "postgres", "queries", counter),
                value_at(before_target, "postgres", "queries", counter),
            )
            target_delta["postgres"]["queries"][counter] = delta
            if cumulative and delta is not None and delta < 0:
                result["counterDecreases"].append(
                    f"{target}.postgres.queries.{counter}"
                )
        if target == "source":
            target_delta["postgres"]["queries"]["entryContinuity"] = (
                calculate_pgss_continuity(
                    value_at(
                        before_target,
                        "postgres",
                        "queries",
                        "appDbEntryState",
                    ),
                    value_at(
                        after_target,
                        "postgres",
                        "queries",
                        "appDbEntryState",
                    ),
                )
            )
            observer_delta: dict[str, Any] = {"roles": {}, "totals": {}}
            observer_counters = (
                ("statementCount", False),
                ("calls", True),
                ("planTimeMs", True),
                ("execTimeMs", True),
                ("cpuUserSeconds", True),
                ("cpuSystemSeconds", True),
                ("cpuTotalSeconds", True),
                ("planCpuUserSeconds", True),
                ("planCpuSystemSeconds", True),
            )
            for role_name in ("powa_collector", "advisor_join_reader"):
                before_role = value_at(
                    before_target,
                    "postgres",
                    "observerOwnedSql",
                    "roles",
                    role_name,
                ) or {}
                after_role = value_at(
                    after_target,
                    "postgres",
                    "observerOwnedSql",
                    "roles",
                    role_name,
                ) or {}
                role_delta: dict[str, Any] = {
                    "pgStatStatementsTrack": after_role.get(
                        "pgStatStatementsTrack"
                    ),
                    "pgStatKcacheTrack": after_role.get("pgStatKcacheTrack"),
                }
                for counter, cumulative in observer_counters:
                    counter_delta = subtract(
                        after_role.get(counter), before_role.get(counter)
                    )
                    role_delta[counter] = counter_delta
                    if cumulative and counter_delta is not None and counter_delta < 0:
                        result["counterDecreases"].append(
                            f"source.postgres.observerOwnedSql.roles."
                            f"{role_name}.{counter}"
                        )
                role_delta["statementEntryContinuity"] = (
                    calculate_pgss_continuity(
                        before_role.get("statementEntryState"),
                        after_role.get("statementEntryState"),
                    )
                )
                role_delta["kcacheEntryContinuity"] = (
                    calculate_kcache_continuity(
                        before_role.get("kcacheEntryState"),
                        after_role.get("kcacheEntryState"),
                    )
                )
                observer_delta["roles"][role_name] = role_delta
            for counter in (
                "statementCount",
                "calls",
                "planTimeMs",
                "execTimeMs",
                "cpuUserSeconds",
                "cpuSystemSeconds",
                "cpuTotalSeconds",
            ):
                observer_delta["totals"][counter] = subtract(
                    value_at(
                        after_target,
                        "postgres",
                        "observerOwnedSql",
                        "totals",
                        counter,
                    ),
                    value_at(
                        before_target,
                        "postgres",
                        "observerOwnedSql",
                        "totals",
                        counter,
                    ),
                )
            target_delta["postgres"]["observerOwnedSql"] = observer_delta
            target_delta["postgres"]["joinOutbox"] = {}
            for counter in (
                "batchCount",
                "rowCount",
                "largestBatchRows",
                "oldestAgeSeconds",
                "payloadBytes",
                "storageBytes",
            ):
                target_delta["postgres"]["joinOutbox"][counter] = subtract(
                    value_at(after_target, "postgres", "joinOutbox", counter),
                    value_at(before_target, "postgres", "joinOutbox", counter),
                )
        if target == "repository":
            target_delta["postgres"]["joinPurgeDebt"] = {}
            for counter in (
                "overdueBatchCount",
                "overdueRowCount",
                "oldestOverdueAgeSeconds",
                "storageBytes",
            ):
                target_delta["postgres"]["joinPurgeDebt"][counter] = subtract(
                    value_at(after_target, "postgres", "joinPurgeDebt", counter),
                    value_at(before_target, "postgres", "joinPurgeDebt", counter),
                )
            target_delta["postgres"]["collector"] = {
                "lagSeconds": subtract(
                    value_at(after_target, "postgres", "collector", "lagSeconds"),
                    value_at(before_target, "postgres", "collector", "lagSeconds"),
                ),
                "snapshotFreshnessSeconds": subtract(
                    value_at(
                        after_target,
                        "postgres",
                        "collector",
                        "snapshotFreshnessSeconds",
                    ),
                    value_at(
                        before_target,
                        "postgres",
                        "collector",
                        "snapshotFreshnessSeconds",
                    ),
                ),
                "snapshotSequence": subtract(
                    value_at(
                        after_target, "postgres", "collector", "snapshotSequence"
                    ),
                    value_at(
                        before_target, "postgres", "collector", "snapshotSequence"
                    ),
                ),
                "snapshotEpochUs": subtract(
                    value_at(
                        after_target, "postgres", "collector", "snapshotEpochUs"
                    ),
                    value_at(
                        before_target, "postgres", "collector", "snapshotEpochUs"
                    ),
                ),
            }
        result[target] = target_delta
    return result


def _valid_integer(value: Any, *, minimum: int = 0) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and value >= minimum
    )


def _powa_boundary_crossings(
    before_sequence: int,
    after_sequence: int,
    *,
    server_id: int,
    powa_coalesce: int,
    residue: int,
) -> int:
    """Count PoWA snapshot sequence values in ``(before, after]``.

    PoWA 5.2 runs aggregate functions when
    ``(coalesce_seq + (srvid % 20)) % powa_coalesce = 0`` and purge functions
    at residue 1.  ``powa_coalesce`` values below two cannot represent both
    boundaries and are rejected by the caller.
    """

    first_sequence = before_sequence + 1
    offset = server_id % 20
    distance = (residue - ((first_sequence + offset) % powa_coalesce)) % (
        powa_coalesce
    )
    first_crossing = first_sequence + distance
    if first_crossing > after_sequence:
        return 0
    return ((after_sequence - first_crossing) // powa_coalesce) + 1


def calculate_powa_maintenance(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
    samples: Sequence[Mapping[str, Any]] = (),
    *,
    expected_server_id: int | None = None,
) -> dict[str, Any]:
    """Classify whether PoWA aggregate/purge maintenance was in the window.

    Invalid, changing or regressing observations never become a steady-state
    claim.  In that case ``maintenanceInclusive`` is unknown and
    ``steadyStateEligible`` deliberately remains false.
    """

    before_collector = value_at(before, "repository", "postgres", "collector")
    after_collector = value_at(after, "repository", "postgres", "collector")
    observations: list[tuple[str, Any, Any, Any, Any]] = [
        (
            "before",
            value_at(before_collector or {}, "serverId"),
            value_at(before_collector or {}, "powaCoalesce"),
            value_at(before_collector or {}, "powaVersion"),
            value_at(before_collector or {}, "snapshotSequence"),
        )
    ]
    observations.extend(
        (
            f"sample[{index}]",
            value_at(sample, "repository", "serverId"),
            value_at(sample, "repository", "powaCoalesce"),
            value_at(sample, "repository", "powaVersion"),
            value_at(sample, "repository", "snapshotSequence"),
        )
        for index, sample in enumerate(samples)
    )
    observations.append(
        (
            "after",
            value_at(after_collector or {}, "serverId"),
            value_at(after_collector or {}, "powaCoalesce"),
            value_at(after_collector or {}, "powaVersion"),
            value_at(after_collector or {}, "snapshotSequence"),
        )
    )

    before_server = observations[0][1]
    before_coalesce = observations[0][2]
    before_version = observations[0][3]
    before_sequence = observations[0][4]
    after_coalesce = observations[-1][2]
    after_version = observations[-1][3]
    after_sequence = observations[-1][4]
    reasons: list[str] = []

    server_values = [item[1] for item in observations]
    coalesce_values = [item[2] for item in observations]
    version_values = [item[3] for item in observations]
    sequence_values = [item[4] for item in observations]
    if not all(_valid_integer(value) for value in server_values):
        reasons.append("INVALID_OR_MISSING_SERVER_ID")
    elif len(set(server_values)) != 1:
        reasons.append("SERVER_ID_CHANGED")
    elif expected_server_id is not None and before_server != expected_server_id:
        reasons.append("SERVER_ID_MISMATCH")

    if not all(_valid_integer(value, minimum=2) for value in coalesce_values):
        reasons.append("INVALID_OR_MISSING_POWA_COALESCE")
    elif len(set(coalesce_values)) != 1:
        reasons.append("POWA_COALESCE_CHANGED")

    if not all(isinstance(value, str) and bool(value) for value in version_values):
        reasons.append("INVALID_OR_MISSING_POWA_VERSION")
    elif len(set(version_values)) != 1:
        reasons.append("POWA_VERSION_CHANGED")
    elif before_version not in SUPPORTED_POWA_MAINTENANCE_SEMANTICS:
        reasons.append("UNSUPPORTED_POWA_VERSION")

    if not all(_valid_integer(value) for value in sequence_values):
        reasons.append("INVALID_OR_MISSING_SNAPSHOT_SEQUENCE")
    elif any(
        later < earlier
        for earlier, later in zip(sequence_values, sequence_values[1:])
    ):
        reasons.append("SNAPSHOT_SEQUENCE_REGRESSION")

    sequence_advance = (
        after_sequence - before_sequence
        if _valid_integer(before_sequence)
        and _valid_integer(after_sequence)
        and after_sequence >= before_sequence
        else None
    )
    result: dict[str, Any] = {
        "classification": "UNKNOWN",
        "maintenanceInclusive": None,
        "steadyStateEligible": False,
        "serverId": (
            before_server
            if _valid_integer(before_server)
            and all(value == before_server for value in server_values)
            and (
                expected_server_id is None or before_server == expected_server_id
            )
            else None
        ),
        "serverIdBefore": before_server if _valid_integer(before_server) else None,
        "serverIdAfter": (
            observations[-1][1]
            if _valid_integer(observations[-1][1])
            else None
        ),
        "powaCoalesce": (
            before_coalesce
            if _valid_integer(before_coalesce, minimum=2)
            and all(value == before_coalesce for value in coalesce_values)
            else None
        ),
        "powaVersion": (
            before_version
            if isinstance(before_version, str)
            and before_version in SUPPORTED_POWA_MAINTENANCE_SEMANTICS
            and all(value == before_version for value in version_values)
            else None
        ),
        "powaCoalesceBefore": (
            before_coalesce
            if _valid_integer(before_coalesce, minimum=2)
            else None
        ),
        "powaCoalesceAfter": (
            after_coalesce if _valid_integer(after_coalesce, minimum=2) else None
        ),
        "powaVersionBefore": (
            before_version if isinstance(before_version, str) else None
        ),
        "powaVersionAfter": (
            after_version if isinstance(after_version, str) else None
        ),
        "snapshotSequenceBefore": (
            before_sequence if _valid_integer(before_sequence) else None
        ),
        "snapshotSequenceAfter": (
            after_sequence if _valid_integer(after_sequence) else None
        ),
        "snapshotSequenceAdvance": sequence_advance,
        "aggregateBoundaryCrossings": None,
        "purgeBoundaryCrossings": None,
        "observedIntermediateSamples": len(samples),
        "boundaryInterval": "(before, after]",
        "unknownReasons": reasons,
    }
    if reasons:
        return result

    # The validation above narrows these values to non-boolean integers.
    assert isinstance(before_server, int)
    assert isinstance(before_coalesce, int)
    assert isinstance(before_sequence, int)
    assert isinstance(after_sequence, int)
    aggregate_crossings = _powa_boundary_crossings(
        before_sequence,
        after_sequence,
        server_id=before_server,
        powa_coalesce=before_coalesce,
        residue=0,
    )
    purge_crossings = _powa_boundary_crossings(
        before_sequence,
        after_sequence,
        server_id=before_server,
        powa_coalesce=before_coalesce,
        residue=1,
    )
    result["aggregateBoundaryCrossings"] = aggregate_crossings
    result["purgeBoundaryCrossings"] = purge_crossings
    result["maintenanceInclusive"] = aggregate_crossings + purge_crossings > 0
    if result["maintenanceInclusive"]:
        result["classification"] = "MAINTENANCE_INCLUSIVE"
    elif sequence_advance == 0:
        result["classification"] = "INSUFFICIENT_SNAPSHOT_PROGRESS"
    else:
        result["classification"] = "STEADY_STATE_ELIGIBLE"
        result["steadyStateEligible"] = True
    return result


def calculate_derived_metrics(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
    delta: Mapping[str, Any],
    elapsed_seconds: float,
    samples: Sequence[Mapping[str, Any]] = (),
    *,
    expected_server_id: int | None = None,
) -> dict[str, Any]:
    """Build additive capacity metrics without changing acceptance guards."""

    valid_window = (
        isinstance(elapsed_seconds, (int, float))
        and not isinstance(elapsed_seconds, bool)
        and math.isfinite(float(elapsed_seconds))
        and elapsed_seconds > 0
    )

    def io_rates(target: str) -> dict[str, Any]:
        read_bytes = value_at(delta, target, "container", "ioReadBytes")
        write_bytes = value_at(delta, target, "container", "ioWriteBytes")

        def rate(value: Any) -> float | None:
            if (
                not valid_window
                or not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(float(value))
                or value < 0
            ):
                return None
            return round(float(value) / float(elapsed_seconds), 6)

        read_rate = rate(read_bytes)
        write_rate = rate(write_bytes)
        return {
            "scope": "containerBlockIo",
            "readBytesPerSecond": read_rate,
            "writeBytesPerSecond": write_rate,
            "totalBytesPerSecond": (
                rate(read_bytes + write_bytes)
                if read_rate is not None and write_rate is not None
                else None
            ),
        }

    return {
        "measurementSeconds": round(float(elapsed_seconds), 6)
        if valid_window
        else None,
        "source": {"containerIo": io_rates("source")},
        "repository": {"containerIo": io_rates("repository")},
        "powaMaintenance": calculate_powa_maintenance(
            before,
            after,
            samples,
            expected_server_id=expected_server_id,
        ),
    }


def calculate_peaks(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
    samples: Sequence[Mapping[str, Any]],
    sampling_errors: int,
) -> dict[str, Any]:
    source_connections = [
        value_at(before, "source", "postgres", "connectionsCurrent"),
        value_at(after, "source", "postgres", "connectionsCurrent"),
    ]
    repository_connections = [
        value_at(before, "repository", "postgres", "connectionsCurrent"),
        value_at(after, "repository", "postgres", "connectionsCurrent"),
    ]
    collector_lags = [
        value_at(before, "repository", "postgres", "collector", "lagSeconds"),
        value_at(after, "repository", "postgres", "collector", "lagSeconds"),
    ]
    freshness = [
        value_at(
            before,
            "repository",
            "postgres",
            "collector",
            "snapshotFreshnessSeconds",
        ),
        value_at(
            after,
            "repository",
            "postgres",
            "collector",
            "snapshotFreshnessSeconds",
        ),
    ]
    source_memory = [
        value_at(before, "source", "container", "memoryCurrentBytes"),
        value_at(after, "source", "container", "memoryCurrentBytes"),
    ]
    repository_memory = [
        value_at(before, "repository", "container", "memoryCurrentBytes"),
        value_at(after, "repository", "container", "memoryCurrentBytes"),
    ]
    snapshot_epochs = [
        value_at(
            before, "repository", "postgres", "collector", "snapshotEpochUs"
        )
    ]
    for sample in samples:
        source_connections.append(value_at(sample, "source", "connections"))
        repository_connections.append(value_at(sample, "repository", "connections"))
        collector_lags.append(value_at(sample, "repository", "collectorLagSeconds"))
        freshness.append(value_at(sample, "repository", "snapshotFreshnessSeconds"))
        snapshot_epochs.append(value_at(sample, "repository", "snapshotEpochUs"))
        source_memory.append(
            value_at(sample, "source", "container", "memoryCurrentBytes")
        )
        repository_memory.append(
            value_at(sample, "repository", "container", "memoryCurrentBytes")
        )
    snapshot_epochs.append(
        value_at(after, "repository", "postgres", "collector", "snapshotEpochUs")
    )

    snapshot_advance_count = 0
    snapshot_epoch_regression = False
    previous_epoch: int | None = None
    for epoch in snapshot_epochs:
        if not isinstance(epoch, int) or isinstance(epoch, bool):
            continue
        if previous_epoch is not None:
            if epoch > previous_epoch:
                snapshot_advance_count += 1
            elif epoch < previous_epoch:
                snapshot_epoch_regression = True
        previous_epoch = epoch

    def maximum(values: Sequence[Any]) -> float | int | None:
        numbers = [
            value
            for value in values
            if isinstance(value, (int, float)) and not isinstance(value, bool)
        ]
        return max(numbers) if numbers else None

    return {
        "sourceConnections": maximum(source_connections),
        "repositoryConnections": maximum(repository_connections),
        "collectorLagSeconds": maximum(collector_lags),
        "snapshotFreshnessSeconds": maximum(freshness),
        "snapshotAdvanceCount": snapshot_advance_count,
        "snapshotEpochRegression": snapshot_epoch_regression,
        "sourceMemoryWindowPeakBytes": maximum(source_memory),
        "repositoryMemoryWindowPeakBytes": maximum(repository_memory),
        "sourceMemoryLifetimePeakBytes": maximum(
            [
                value_at(
                    before, "source", "container", "memoryLifetimePeakBytes"
                ),
                value_at(
                    after, "source", "container", "memoryLifetimePeakBytes"
                ),
            ]
        ),
        "repositoryMemoryLifetimePeakBytes": maximum(
            [
                value_at(
                    before,
                    "repository",
                    "container",
                    "memoryLifetimePeakBytes",
                ),
                value_at(
                    after,
                    "repository",
                    "container",
                    "memoryLifetimePeakBytes",
                ),
            ]
        ),
        "sampleCount": len(samples),
        "samplingErrors": sampling_errors,
    }


def calculate_api_metrics(
    samples: Sequence[Mapping[str, Any]],
    errors: Sequence[str],
    concurrency: int,
    *,
    endpoint_concurrency: Mapping[str, int] | None = None,
) -> dict[str, Any]:
    def summarize(
        selected_samples: Sequence[Mapping[str, Any]],
        error_count: int,
        sample_concurrency: int,
    ) -> dict[str, Any]:
        latencies = sorted(
            float(item["latencySeconds"])
            for item in selected_samples
            if isinstance(item.get("latencySeconds"), (int, float))
            and not isinstance(item.get("latencySeconds"), bool)
        )
        item_counts = [
            int(item["itemCount"])
            for item in selected_samples
            if isinstance(item.get("itemCount"), int)
            and not isinstance(item.get("itemCount"), bool)
        ]

        def percentile(fraction: float) -> float | None:
            if not latencies:
                return None
            index = max(0, math.ceil(len(latencies) * fraction) - 1)
            return latencies[index]

        return {
            "concurrency": sample_concurrency,
            "sampleCount": len(latencies),
            "errorCount": error_count,
            "p50Seconds": percentile(0.50),
            "p95Seconds": percentile(0.95),
            "maxSeconds": max(latencies) if latencies else None,
            "minimumItems": min(item_counts) if item_counts else None,
            "maximumItems": max(item_counts) if item_counts else None,
        }

    endpoints = ("query-list", "overview", "query-detail")
    labeled = any(item.get("endpoint") in endpoints for item in samples) or any(
        error.startswith(tuple(f"{endpoint}:" for endpoint in endpoints))
        for error in errors
    )
    query_list_samples = [
        item
        for item in samples
        if item.get("endpoint") in (None, "query-list")
    ]
    query_list_error_count = (
        sum(1 for error in errors if error.startswith("query-list:"))
        if labeled
        else len(errors)
    )
    result = summarize(query_list_samples, query_list_error_count, concurrency)
    if labeled:
        by_endpoint: dict[str, Any] = {}
        for endpoint in endpoints:
            endpoint_samples = [
                item for item in samples if item.get("endpoint") == endpoint
            ]
            endpoint_errors = sum(
                1 for error in errors if error.startswith(f"{endpoint}:")
            )
            by_endpoint[endpoint] = summarize(
                endpoint_samples,
                endpoint_errors,
                (
                    endpoint_concurrency.get(endpoint, concurrency)
                    if endpoint_concurrency is not None
                    else concurrency
                ),
            )
        result["byEndpoint"] = by_endpoint
        result["matrixErrorCount"] = len(errors)
    return result


def load_thresholds(
    before: Mapping[str, Any],
    frequency: int,
    *,
    duration_seconds: int = DEFAULTS["erp"][0],
    sample_seconds: float = 5.0,
) -> dict[str, Any]:
    source_max = int(value_at(before, "source", "postgres", "maxConnections") or 100)
    repository_max = int(
        value_at(before, "repository", "postgres", "maxConnections") or 100
    )
    default_lag = max(30.0, float(frequency) * 4.0)
    default_peak_samples = max(
        1, math.floor((float(duration_seconds) / sample_seconds) * 0.8)
    )
    expected_snapshots = float(duration_seconds) / max(float(frequency), 1.0)
    default_min_snapshots = max(1, math.floor(expected_snapshots * 0.8))
    default_max_snapshots = max(
        default_min_snapshots, math.ceil(expected_snapshots * 1.5) + 1
    )
    min_collector_snapshots = env_int(
        "ERP_MIN_COLLECTOR_SNAPSHOTS", default_min_snapshots, minimum=1
    )
    max_collector_snapshots = env_int(
        "ERP_MAX_COLLECTOR_SNAPSHOTS", default_max_snapshots, minimum=1
    )
    if max_collector_snapshots < min_collector_snapshots:
        raise BenchmarkError(
            "ERP_MAX_COLLECTOR_SNAPSHOTS, ERP_MIN_COLLECTOR_SNAPSHOTS "
            "degerinden kucuk olamaz"
        )
    return {
        "maxSourceConnections": env_int(
            "ERP_MAX_SOURCE_CONNECTIONS", max(1, math.floor(source_max * 0.9)), minimum=1
        ),
        "maxRepositoryConnections": env_int(
            "ERP_MAX_REPOSITORY_CONNECTIONS",
            max(1, math.floor(repository_max * 0.9)),
            minimum=1,
        ),
        "maxCollectorLagSeconds": env_float(
            "ERP_MAX_COLLECTOR_LAG_SECONDS", default_lag
        ),
        "maxSnapshotFreshnessSeconds": env_float(
            "ERP_MAX_SNAPSHOT_FRESHNESS_SECONDS", default_lag
        ),
        "minSnapshotAdvanceMicroseconds": env_int(
            "ERP_MIN_SNAPSHOT_ADVANCE_MICROSECONDS", 1
        ),
        "minSourceTaggedCallsDelta": env_int(
            "ERP_MIN_SOURCE_TAGGED_CALLS_DELTA", 1
        ),
        "minSourceFrequencySeconds": env_int(
            "ERP_MIN_SOURCE_FREQUENCY_SECONDS", 30
        ),
        "minCollectorSnapshots": min_collector_snapshots,
        "maxCollectorSnapshots": max_collector_snapshots,
        "maxSourceDatabaseGrowthBytes": env_int(
            "ERP_MAX_SOURCE_DB_GROWTH_BYTES", 4 * 1024**3
        ),
        "maxRepositoryDatabaseGrowthBytes": env_int(
            "ERP_MAX_REPOSITORY_DB_GROWTH_BYTES", 4 * 1024**3
        ),
        "maxSamplingErrors": env_int("ERP_MAX_SAMPLING_ERRORS", 3),
        "minPeakSamples": env_int(
            "ERP_MIN_PEAK_SAMPLES", default_peak_samples, minimum=1
        ),
        "maxApiP95Seconds": env_float("ERP_MAX_API_P95_SECONDS", 2.0),
        "maxApiOverviewP95Seconds": env_float(
            "ERP_MAX_API_OVERVIEW_P95_SECONDS", 8.0
        ),
        "maxApiDetailP95Seconds": env_float(
            "ERP_MAX_API_DETAIL_P95_SECONDS", 2.0
        ),
        "minApiSamples": env_int("ERP_MIN_API_SAMPLES", 5, minimum=1),
        "maxApiErrors": env_int("ERP_MAX_API_ERRORS", 0),
        "maxPgssOccupancyPercent": env_float(
            "ERP_MAX_PGSS_OCCUPANCY_PERCENT", 90.0
        ),
        "maxJoinOutboxBatches": env_int("ERP_MAX_JOIN_OUTBOX_BATCHES", 100),
        "maxJoinOutboxRows": env_int("ERP_MAX_JOIN_OUTBOX_ROWS", 1_000_000),
        "maxJoinOutboxLargestBatchRows": env_int(
            "ERP_MAX_JOIN_OUTBOX_LARGEST_BATCH_ROWS", 250_000
        ),
        "maxJoinOutboxOldestAgeSeconds": env_float(
            "ERP_MAX_JOIN_OUTBOX_OLDEST_AGE_SECONDS", default_lag
        ),
        "maxJoinOutboxStorageBytes": env_int(
            "ERP_MAX_JOIN_OUTBOX_STORAGE_BYTES", 1024**3
        ),
        "maxJoinOutboxPayloadBytes": env_int(
            "ERP_MAX_JOIN_OUTBOX_PAYLOAD_BYTES", 512 * 1024**2
        ),
        "maxJoinPurgeDebtBatches": env_int(
            "ERP_MAX_JOIN_PURGE_DEBT_BATCHES", 0
        ),
        "maxJoinPurgeDebtRows": env_int("ERP_MAX_JOIN_PURGE_DEBT_ROWS", 0),
        # Zero disables hardware-specific ceilings while measurement and
        # reset/non-negative guards remain mandatory.
        "maxSourceAverageCpuCores": env_float(
            "ERP_MAX_SOURCE_AVG_CPU_CORES", 0.0
        ),
        "maxRepositoryAverageCpuCores": env_float(
            "ERP_MAX_REPOSITORY_AVG_CPU_CORES", 0.0
        ),
        "maxRepositorySourceCpuRatio": env_float(
            "ERP_MAX_REPOSITORY_SOURCE_CPU_RATIO", 0.0
        ),
        "maxSourceIoBytes": env_int("ERP_MAX_SOURCE_IO_BYTES", 0),
        "maxRepositoryIoBytes": env_int("ERP_MAX_REPOSITORY_IO_BYTES", 0),
        "maxSourceMemoryBytes": env_int("ERP_MAX_SOURCE_MEMORY_BYTES", 0),
        "maxRepositoryMemoryBytes": env_int(
            "ERP_MAX_REPOSITORY_MEMORY_BYTES", 0
        ),
        "maxMemoryPressureEventsDelta": env_int(
            "ERP_MAX_MEMORY_PRESSURE_EVENTS_DELTA", 0
        ),
        "maxOomEventsDelta": env_int("ERP_MAX_OOM_EVENTS_DELTA", 0),
        "maxOomKillEventsDelta": env_int("ERP_MAX_OOM_KILL_EVENTS_DELTA", 0),
        "requireCgroupMetrics": env_bool("ERP_REQUIRE_CGROUP_METRICS", True),
        "requireCgroupMemoryEvents": env_bool(
            "ERP_REQUIRE_CGROUP_MEMORY_EVENTS", True
        ),
    }


def evaluate_guardrails(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
    delta: Mapping[str, Any],
    peaks: Mapping[str, Any],
    api_metrics: Mapping[str, Any],
    thresholds: Mapping[str, Any],
    *,
    elapsed_seconds: float,
    workload_exit_code: int,
) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []

    def add(name: str, passed: bool, actual: Any, limit: Any, message: str) -> None:
        checks.append(
            {
                "name": name,
                "status": "PASS" if passed else "FAIL",
                "actual": actual,
                "limit": limit,
                "message": message,
            }
        )

    def skip(name: str, actual: Any, message: str) -> None:
        checks.append(
            {
                "name": name,
                "status": "SKIP",
                "actual": actual,
                "limit": None,
                "message": message,
            }
        )

    add(
        "workload_exit_code",
        workload_exit_code == 0,
        workload_exit_code,
        0,
        "realistic workload wrapper basariyla tamamlanmali",
    )
    decreases = list(delta.get("counterDecreases") or [])
    add(
        "monotonic_counters",
        not decreases,
        decreases,
        [],
        "CPU/I/O/bellek/PostgreSQL kümülatif sayaçlari geriye gitmemeli",
    )
    for target in ("source", "repository"):
        before_started = value_at(before, target, "container", "startedAt")
        after_started = value_at(after, target, "container", "startedAt")
        add(
            f"{target}_container_restart",
            before_started is not None and before_started == after_started,
            {"before": before_started, "after": after_started},
            "unchanged",
            "container ölçüm penceresinde restart etmemeli",
        )
    for target in ("source", "repository"):
        for family, reset_path in (
            ("database", ("databaseStats", "statsReset")),
            ("pg_stat_io", ("pgStatIo", "statsReset")),
        ):
            before_reset = value_at(before, target, "postgres", *reset_path)
            after_reset = value_at(after, target, "postgres", *reset_path)
            add(
                f"{target}_{family}_reset",
                before_reset == after_reset,
                {"before": before_reset, "after": after_reset},
                "unchanged",
                "ölçüm penceresinde istatistik reseti olmamali",
            )
    source_query_reset_before = value_at(
        before, "source", "postgres", "queries", "statsReset"
    )
    source_query_reset_after = value_at(
        after, "source", "postgres", "queries", "statsReset"
    )
    add(
        "source_pg_stat_statements_reset",
        source_query_reset_before == source_query_reset_after,
        {"before": source_query_reset_before, "after": source_query_reset_after},
        "unchanged",
        "query call deltasi reset ile kirilmamali",
    )
    continuity = value_at(
        delta, "source", "postgres", "queries", "entryContinuity"
    )
    continuity_ok = (
        isinstance(continuity, Mapping)
        and continuity.get("stateValid") is True
        and continuity.get("missingEntryCount") == 0
        and continuity.get("resetEntryCount") == 0
    )
    add(
        "source_pgss_entry_continuity",
        continuity_ok,
        continuity,
        {"stateValid": True, "missingEntryCount": 0, "resetEntryCount": 0},
        "baseline appdb query anahtarlari ve stats_since degerleri korunmali",
    )
    observer_continuity: dict[str, Any] = {}
    observer_continuity_ok = True
    for role_name in ("powa_collector", "advisor_join_reader"):
        role_state = value_at(
            delta,
            "source",
            "postgres",
            "observerOwnedSql",
            "roles",
            role_name,
        ) or {}
        statement_state = role_state.get("statementEntryContinuity")
        kcache_state = role_state.get("kcacheEntryContinuity")
        observer_continuity[role_name] = {
            "pgStatStatements": statement_state,
            "pgStatKcache": kcache_state,
        }
        for state in (statement_state, kcache_state):
            observer_continuity_ok = observer_continuity_ok and (
                isinstance(state, Mapping)
                and state.get("stateValid") is True
                and state.get("missingEntryCount") == 0
                and state.get("resetEntryCount") == 0
            )
    add(
        "source_observer_counter_continuity",
        observer_continuity_ok,
        observer_continuity,
        {
            "stateValid": True,
            "missingEntryCount": 0,
            "resetEntryCount": 0,
        },
        "observer-owned pg_stat_statements/kcache baseline entry'leri korunmali",
    )
    if thresholds["requireCgroupMetrics"]:
        missing = []
        for target in ("source", "repository"):
            for counter in (
                "cpuUsageUsec",
                "ioReadBytes",
                "ioWriteBytes",
                "memoryCurrentBytes",
                "memoryLifetimePeakBytes",
            ):
                if value_at(delta, target, "container", counter) is None:
                    missing.append(f"{target}.{counter}")
            before_cgroup_version = value_at(
                before, target, "container", "cgroupVersion"
            )
            after_cgroup_version = value_at(
                after, target, "container", "cgroupVersion"
            )
            if (
                before_cgroup_version not in {1, 2}
                or after_cgroup_version != before_cgroup_version
            ):
                missing.append(f"{target}.cgroupVersion")
            limit_bytes = value_at(
                after, target, "container", "memoryLimitBytes"
            )
            limit_unlimited = value_at(
                after, target, "container", "memoryLimitUnlimited"
            )
            if not (
                (
                    isinstance(limit_bytes, int)
                    and not isinstance(limit_bytes, bool)
                )
                or isinstance(limit_unlimited, bool)
            ):
                missing.append(f"{target}.memoryLimit")
        add(
            "cgroup_metrics_available",
            not missing,
            missing,
            [],
            "container CPU, block I/O ve bellek sayaçlari ölçülebilmeli",
        )
    memory_event_fields = (
        ("memoryMaxEvents", "maxMemoryPressureEventsDelta", "memory_pressure"),
        ("memoryOomEvents", "maxOomEventsDelta", "memory_oom"),
        ("memoryOomKillEvents", "maxOomKillEventsDelta", "memory_oom_kill"),
    )
    missing_memory_events: list[str] = []
    unavailable_v1_exact_events: list[str] = []
    for target in ("source", "repository"):
        cgroup_version = value_at(after, target, "container", "cgroupVersion")
        before_limit = {
            "bytes": value_at(before, target, "container", "memoryLimitBytes"),
            "unlimited": value_at(
                before, target, "container", "memoryLimitUnlimited"
            ),
        }
        after_limit = {
            "bytes": value_at(after, target, "container", "memoryLimitBytes"),
            "unlimited": value_at(
                after, target, "container", "memoryLimitUnlimited"
            ),
        }
        limit_known = (
            (
                isinstance(before_limit["bytes"], int)
                and not isinstance(before_limit["bytes"], bool)
            )
            or isinstance(before_limit["unlimited"], bool)
        ) and (
            (
                isinstance(after_limit["bytes"], int)
                and not isinstance(after_limit["bytes"], bool)
            )
            or isinstance(after_limit["unlimited"], bool)
        )
        if thresholds["requireCgroupMetrics"] or limit_known:
            add(
                f"{target}_memory_limit_unchanged",
                limit_known and before_limit == after_limit,
                {"before": before_limit, "after": after_limit},
                "unchanged",
                "container bellek limiti ölçüm penceresinde değişmemeli",
            )
        else:
            skip(
                f"{target}_memory_limit_unchanged",
                {"before": before_limit, "after": after_limit},
                "cgroup bellek limiti ölçülemiyor",
            )
        for field, threshold_key, guard_suffix in memory_event_fields:
            event_delta = value_at(delta, target, "container", field)
            if not isinstance(event_delta, int) or isinstance(event_delta, bool):
                if cgroup_version == 1 and field in {
                    "memoryOomEvents",
                    "memoryOomKillEvents",
                }:
                    unavailable_v1_exact_events.append(f"{target}.{field}")
                    skip(
                        f"{target}_{guard_suffix}_events",
                        event_delta,
                        "cgroup v1 exact OOM sayacini sunmaz; failcnt baski kapisi aktif",
                    )
                    continue
                missing_memory_events.append(f"{target}.{field}")
                if not thresholds["requireCgroupMemoryEvents"]:
                    skip(
                        f"{target}_{guard_suffix}_events",
                        event_delta,
                        "platform bu cgroup bellek olay sayacini sunmuyor",
                    )
                continue
            add(
                f"{target}_{guard_suffix}_events",
                event_delta <= thresholds[threshold_key],
                event_delta,
                {"maxDelta": thresholds[threshold_key]},
                "ölçüm penceresinde cgroup bellek baskisi/OOM olayi birikmemeli",
            )
    if thresholds["requireCgroupMemoryEvents"]:
        add(
            "cgroup_memory_event_metrics_available",
            not missing_memory_events,
            {
                "missing": missing_memory_events,
                "unavailableExactOnV1": unavailable_v1_exact_events,
            },
            [],
            "v2 max/oom/oom_kill veya v1 failcnt baski sayaci ölçülebilmeli",
        )
    snapshot_delta = value_at(
        delta, "repository", "postgres", "collector", "snapshotEpochUs"
    )
    add(
        "snapshot_time_advance",
        isinstance(snapshot_delta, (int, float))
        and snapshot_delta >= thresholds["minSnapshotAdvanceMicroseconds"],
        snapshot_delta,
        {"minMicroseconds": thresholds["minSnapshotAdvanceMicroseconds"]},
        "PoWA snapts workload boyunca ilerlemeli",
    )
    snapshot_advance_count = peaks.get("snapshotAdvanceCount")
    add(
        "collector_effective_snapshot_cadence",
        isinstance(snapshot_advance_count, int)
        and not isinstance(snapshot_advance_count, bool)
        and peaks.get("snapshotEpochRegression") is False
        and thresholds["minCollectorSnapshots"]
        <= snapshot_advance_count
        <= thresholds["maxCollectorSnapshots"],
        {
            "advances": snapshot_advance_count,
            "epochRegression": peaks.get("snapshotEpochRegression"),
        },
        {
            "min": thresholds["minCollectorSnapshots"],
            "max": thresholds["maxCollectorSnapshots"],
        },
        "collector gercek snapshot sayisi configured frequency ile uyumlu olmali",
    )
    tagged_calls = value_at(delta, "source", "postgres", "queries", "taggedCalls")
    add(
        "source_tagged_query_calls",
        isinstance(tagged_calls, (int, float))
        and tagged_calls >= thresholds["minSourceTaggedCallsDelta"],
        tagged_calls,
        {"min": thresholds["minSourceTaggedCallsDelta"]},
        "ERP sorgulari source pg_stat_statements sayacini ilerletmeli",
    )
    dealloc_delta = value_at(delta, "source", "postgres", "queries", "dealloc")
    add(
        "source_pgss_dealloc_delta",
        dealloc_delta == 0,
        dealloc_delta,
        0,
        "pg_stat_statements kapasite baskisiyla entry evict etmemeli",
    )
    collector_owned_delta = value_at(
        delta, "source", "postgres", "queries", "collectorOwnedQueryCount"
    )
    add(
        "source_collector_owned_query_delta",
        collector_owned_delta == 0,
        collector_owned_delta,
        0,
        "collector sorgulari source pg_stat_statements'a yeni entry eklememeli",
    )
    tracked_statements = value_at(
        after, "source", "postgres", "queries", "trackedStatementCount"
    )
    max_statements = value_at(
        after, "source", "postgres", "queries", "maxTrackedStatements"
    )
    pgss_occupancy = (
        100.0 * tracked_statements / max_statements
        if isinstance(tracked_statements, (int, float))
        and isinstance(max_statements, (int, float))
        and max_statements > 0
        else None
    )
    add(
        "source_pgss_occupancy",
        pgss_occupancy is not None
        and pgss_occupancy <= thresholds["maxPgssOccupancyPercent"],
        {
            "percent": pgss_occupancy,
            "tracked": tracked_statements,
            "max": max_statements,
        },
        {"maxPercent": thresholds["maxPgssOccupancyPercent"]},
        "pg_stat_statements occupancy eviction marjini birakmali",
    )
    collector_status = value_at(after, "repository", "postgres", "collector", "status")
    collector_errors = value_at(
        after, "repository", "postgres", "collector", "errorCount"
    )
    add(
        "collector_health",
        collector_status == "HEALTHY" and collector_errors == 0,
        {"status": collector_status, "errors": collector_errors},
        {"status": "HEALTHY", "errors": 0},
        "collector koşu sonunda sağlıklı olmali",
    )
    before_frequency = value_at(
        before, "repository", "postgres", "collector", "frequencySeconds"
    )
    after_frequency = value_at(
        after, "repository", "postgres", "collector", "frequencySeconds"
    )
    add(
        "source_collection_frequency_unchanged",
        isinstance(before_frequency, int)
        and not isinstance(before_frequency, bool)
        and before_frequency == after_frequency,
        {"beforeSeconds": before_frequency, "afterSeconds": after_frequency},
        "unchanged",
        "benchmark source toplama frekansini degistirmemeli",
    )
    minimum_frequency = thresholds["minSourceFrequencySeconds"]
    if minimum_frequency == 0:
        skip(
            "source_collection_frequency_minimum",
            after_frequency,
            "minimum source toplama araligi bilincli olarak kapali",
        )
    else:
        add(
            "source_collection_frequency_minimum",
            isinstance(after_frequency, int)
            and not isinstance(after_frequency, bool)
            and after_frequency >= minimum_frequency,
            after_frequency,
            {"minSeconds": minimum_frequency},
            "ERP benchmark source'u aşırı sik toplamamali",
        )
    add(
        "collector_peak_lag",
        isinstance(peaks.get("collectorLagSeconds"), (int, float))
        and peaks["collectorLagSeconds"] <= thresholds["maxCollectorLagSeconds"],
        peaks.get("collectorLagSeconds"),
        {"max": thresholds["maxCollectorLagSeconds"]},
        "örneklenen collector lag siniri aşmamali",
    )
    add(
        "snapshot_peak_freshness",
        isinstance(peaks.get("snapshotFreshnessSeconds"), (int, float))
        and peaks["snapshotFreshnessSeconds"]
        <= thresholds["maxSnapshotFreshnessSeconds"],
        peaks.get("snapshotFreshnessSeconds"),
        {"max": thresholds["maxSnapshotFreshnessSeconds"]},
        "snapshot freshness siniri aşmamali",
    )
    add(
        "source_peak_connections",
        isinstance(peaks.get("sourceConnections"), (int, float))
        and peaks["sourceConnections"] <= thresholds["maxSourceConnections"],
        peaks.get("sourceConnections"),
        {"max": thresholds["maxSourceConnections"]},
        "source connection kapasitesi tüketilmemeli",
    )
    add(
        "repository_peak_connections",
        isinstance(peaks.get("repositoryConnections"), (int, float))
        and peaks["repositoryConnections"] <= thresholds["maxRepositoryConnections"],
        peaks.get("repositoryConnections"),
        {"max": thresholds["maxRepositoryConnections"]},
        "repository connection kapasitesi tüketilmemeli",
    )
    for target, threshold_key in (
        ("source", "maxSourceDatabaseGrowthBytes"),
        ("repository", "maxRepositoryDatabaseGrowthBytes"),
    ):
        growth = value_at(delta, target, "postgres", "databaseSizeBytes")
        add(
            f"{target}_database_growth",
            isinstance(growth, (int, float)) and growth <= thresholds[threshold_key],
            growth,
            {"max": thresholds[threshold_key]},
            "tek koşuda kontrolsüz database büyümesi olmamali",
        )
        deadlocks = value_at(delta, target, "postgres", "databaseStats", "deadlocks")
        add(
            f"{target}_deadlocks",
            deadlocks == 0,
            deadlocks,
            0,
            "benchmark deadlock üretmemeli",
        )
    add(
        "sampling_errors",
        isinstance(peaks.get("samplingErrors"), int)
        and peaks["samplingErrors"] <= thresholds["maxSamplingErrors"],
        peaks.get("samplingErrors"),
        {"max": thresholds["maxSamplingErrors"]},
        "peak monitor örnekleme hatalari sinirli olmali",
    )
    add(
        "peak_sample_count",
        isinstance(peaks.get("sampleCount"), int)
        and peaks["sampleCount"] >= thresholds["minPeakSamples"],
        peaks.get("sampleCount"),
        {"min": thresholds["minPeakSamples"]},
        "istenen süre/aralik icin yeterli başarılı peak örnegi alinmali",
    )
    add(
        "api_sample_count",
        isinstance(api_metrics.get("sampleCount"), int)
        and api_metrics["sampleCount"] >= thresholds["minApiSamples"],
        api_metrics.get("sampleCount"),
        {"min": thresholds["minApiSamples"]},
        "yük altinda yeterli API latency örnegi alinmali",
    )
    api_probe_error_count = api_metrics.get(
        "matrixErrorCount", api_metrics.get("errorCount")
    )
    add(
        "api_probe_errors",
        isinstance(api_probe_error_count, int)
        and api_probe_error_count <= thresholds["maxApiErrors"],
        api_probe_error_count,
        {"max": thresholds["maxApiErrors"]},
        "yük altindaki API probe hatalari siniri aşmamali",
    )
    add(
        "api_query_p95",
        isinstance(api_metrics.get("p95Seconds"), (int, float))
        and api_metrics["p95Seconds"] <= thresholds["maxApiP95Seconds"],
        {
            "seconds": api_metrics.get("p95Seconds"),
            "concurrency": api_metrics.get("concurrency"),
        },
        {"maxSeconds": thresholds["maxApiP95Seconds"]},
        "query list API p95 yük altinda hedefi aşmamali",
    )
    by_endpoint = api_metrics.get("byEndpoint")
    if isinstance(by_endpoint, Mapping):
        overview_metrics = by_endpoint.get("overview") or {}
        overview_limit = thresholds.get("maxApiOverviewP95Seconds", 8.0)
        add(
            "api_overview_p95",
            isinstance(overview_metrics.get("p95Seconds"), (int, float))
            and overview_metrics["p95Seconds"] <= overview_limit,
            {
                "seconds": overview_metrics.get("p95Seconds"),
                "sampleCount": overview_metrics.get("sampleCount"),
                "concurrency": overview_metrics.get("concurrency"),
            },
            {"maxSeconds": overview_limit},
            "overview API p95 yük altinda hedefi aşmamali",
        )
        detail_metrics = by_endpoint.get("query-detail") or {}
        detail_limit = thresholds.get("maxApiDetailP95Seconds", 2.0)
        add(
            "api_query_detail_p95",
            isinstance(detail_metrics.get("p95Seconds"), (int, float))
            and detail_metrics["p95Seconds"] <= detail_limit,
            {
                "seconds": detail_metrics.get("p95Seconds"),
                "sampleCount": detail_metrics.get("sampleCount"),
                "concurrency": detail_metrics.get("concurrency"),
            },
            {"maxSeconds": detail_limit},
            "query detail/trend API p95 yük altinda hedefi aşmamali",
        )
    else:
        skip(
            "api_overview_p95",
            None,
            "legacy probe verisinde overview endpoint etiketi yok",
        )
        skip(
            "api_query_detail_p95",
            None,
            "legacy probe verisinde query-detail endpoint etiketi yok",
        )
    add(
        "api_query_items",
        isinstance(api_metrics.get("maximumItems"), int)
        and api_metrics["maximumItems"] > 0,
        api_metrics.get("maximumItems"),
        {"min": 1},
        "yük penceresinde query API hedef source icin veri dondurmeli",
    )

    outbox = value_at(after, "source", "postgres", "joinOutbox") or {}
    for field, threshold_key, guard_name in (
        ("batchCount", "maxJoinOutboxBatches", "join_outbox_batches"),
        ("rowCount", "maxJoinOutboxRows", "join_outbox_rows"),
        (
            "largestBatchRows",
            "maxJoinOutboxLargestBatchRows",
            "join_outbox_largest_batch",
        ),
        (
            "oldestAgeSeconds",
            "maxJoinOutboxOldestAgeSeconds",
            "join_outbox_oldest_age",
        ),
        (
            "payloadBytes",
            "maxJoinOutboxPayloadBytes",
            "join_outbox_payload",
        ),
        ("storageBytes", "maxJoinOutboxStorageBytes", "join_outbox_storage"),
    ):
        actual = outbox.get(field) if isinstance(outbox, Mapping) else None
        add(
            guard_name,
            isinstance(actual, (int, float))
            and not isinstance(actual, bool)
            and actual <= thresholds[threshold_key],
            actual,
            {"max": thresholds[threshold_key]},
            "source JOIN outbox backlog siniri aşmamali",
        )

    purge_debt = value_at(after, "repository", "postgres", "joinPurgeDebt") or {}
    for field, threshold_key, guard_name in (
        (
            "overdueBatchCount",
            "maxJoinPurgeDebtBatches",
            "join_purge_debt_batches",
        ),
        ("overdueRowCount", "maxJoinPurgeDebtRows", "join_purge_debt_rows"),
    ):
        actual = purge_debt.get(field) if isinstance(purge_debt, Mapping) else None
        add(
            guard_name,
            isinstance(actual, (int, float))
            and not isinstance(actual, bool)
            and actual <= thresholds[threshold_key],
            actual,
            {"max": thresholds[threshold_key]},
            "repository JOIN retention purge borcu birikmemeli",
        )

    for target, peak_key, threshold_key in (
        ("source", "sourceMemoryWindowPeakBytes", "maxSourceMemoryBytes"),
        (
            "repository",
            "repositoryMemoryWindowPeakBytes",
            "maxRepositoryMemoryBytes",
        ),
    ):
        memory_peak = peaks.get(peak_key)
        ceiling = thresholds[threshold_key]
        if ceiling == 0:
            skip(
                f"{target}_memory_window_peak",
                memory_peak,
                "donanim/topoloji bağımlı bellek tavanı varsayılan olarak kapalı",
            )
        else:
            add(
                f"{target}_memory_window_peak",
                isinstance(memory_peak, (int, float))
                and not isinstance(memory_peak, bool)
                and memory_peak <= ceiling,
                memory_peak,
                {"maxBytes": ceiling},
                "örneklenen container bellek tepe değeri siniri aşmamali",
            )

    source_cpu = value_at(delta, "source", "container", "cpuUsageSeconds")
    repository_cpu = value_at(delta, "repository", "container", "cpuUsageSeconds")
    source_cores = source_cpu / elapsed_seconds if source_cpu is not None and elapsed_seconds > 0 else None
    repository_cores = (
        repository_cpu / elapsed_seconds
        if repository_cpu is not None and elapsed_seconds > 0
        else None
    )
    for name, actual, threshold_key in (
        ("source_average_cpu_cores", source_cores, "maxSourceAverageCpuCores"),
        (
            "repository_average_cpu_cores",
            repository_cores,
            "maxRepositoryAverageCpuCores",
        ),
    ):
        ceiling = thresholds[threshold_key]
        if ceiling == 0:
            skip(name, actual, "donanim-bağımlı CPU tavanı varsayılan olarak kapalı")
        else:
            add(name, actual is not None and actual <= ceiling, actual, {"max": ceiling}, "ortalama CPU core tavanı")
    ratio_limit = thresholds["maxRepositorySourceCpuRatio"]
    ratio = (
        repository_cpu / source_cpu
        if source_cpu is not None and repository_cpu is not None and source_cpu > 0
        else None
    )
    if ratio_limit == 0:
        skip(
            "repository_source_cpu_ratio",
            ratio,
            "topoloji-bağımlı CPU oranı varsayılan olarak kapalı",
        )
    else:
        add(
            "repository_source_cpu_ratio",
            ratio is not None and ratio <= ratio_limit,
            ratio,
            {"max": ratio_limit},
            "gözlem repository'si source CPU maliyetini orantısız aşmamali",
        )
    for target, threshold_key in (
        ("source", "maxSourceIoBytes"),
        ("repository", "maxRepositoryIoBytes"),
    ):
        read_bytes = value_at(delta, target, "container", "ioReadBytes")
        write_bytes = value_at(delta, target, "container", "ioWriteBytes")
        total_io = (
            read_bytes + write_bytes
            if isinstance(read_bytes, (int, float))
            and isinstance(write_bytes, (int, float))
            else None
        )
        ceiling = thresholds[threshold_key]
        if ceiling == 0:
            skip(
                f"{target}_container_io_bytes",
                total_io,
                "donanim/veri hacmi bağımlı I/O tavanı varsayılan olarak kapalı",
            )
        else:
            add(
                f"{target}_container_io_bytes",
                total_io is not None and total_io <= ceiling,
                total_io,
                {"max": ceiling},
                "container block I/O tavanı",
            )
    return checks


def write_report(report: Mapping[str, Any], directory: pathlib.Path, profile: str) -> pathlib.Path:
    directory.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = directory / f"{stamp}-{profile}-erp-stack.json"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=".erp-stack-", delete=False
    ) as handle:
        json.dump(report, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
        temporary = pathlib.Path(handle.name)
    temporary.replace(target)
    return target


def human_bytes(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "n/a"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    rendered = float(value)
    for unit in units:
        if abs(rendered) < 1024 or unit == units[-1]:
            return f"{rendered:.2f} {unit}"
        rendered /= 1024
    return f"{rendered:.2f} TiB"


def human_bytes_per_second(value: Any) -> str:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return "n/a"
    return f"{human_bytes(value)}/s"


def print_summary(report: Mapping[str, Any], report_path: pathlib.Path) -> None:
    delta = report["delta"]
    derived = report.get("derivedMetrics") or {}
    peaks = report["peaks"]
    api = report["api"]
    source_frequency = f"{report.get('sourceFrequencySeconds')}s"
    print("\nERP stack benchmark özeti")
    print("metric                              source            repository")
    print(
        f"total container CPU delta           {value_at(delta, 'source', 'container', 'cpuUsageSeconds')!s:>12} s"
        f" {value_at(delta, 'repository', 'container', 'cpuUsageSeconds')!s:>15} s"
    )
    print(
        f"tracked observer SQL CPU            {value_at(delta, 'source', 'postgres', 'observerOwnedSql', 'totals', 'cpuTotalSeconds')!s:>12} s"
        f" {'-':>17}"
    )
    print(
        f"tracked observer calls / exec ms    {str(value_at(delta, 'source', 'postgres', 'observerOwnedSql', 'totals', 'calls')):>12} /"
        f" {str(value_at(delta, 'source', 'postgres', 'observerOwnedSql', 'totals', 'execTimeMs')):>12}"
    )
    print(
        f"container read delta                {human_bytes(value_at(delta, 'source', 'container', 'ioReadBytes')):>14}"
        f" {human_bytes(value_at(delta, 'repository', 'container', 'ioReadBytes')):>17}"
    )
    print(
        f"container write delta               {human_bytes(value_at(delta, 'source', 'container', 'ioWriteBytes')):>14}"
        f" {human_bytes(value_at(delta, 'repository', 'container', 'ioWriteBytes')):>17}"
    )
    print(
        f"container total I/O rate            {human_bytes_per_second(value_at(derived, 'source', 'containerIo', 'totalBytesPerSecond')):>14}"
        f" {human_bytes_per_second(value_at(derived, 'repository', 'containerIo', 'totalBytesPerSecond')):>17}"
    )
    print(
        f"database size delta                 {human_bytes(value_at(delta, 'source', 'postgres', 'databaseSizeBytes')):>14}"
        f" {human_bytes(value_at(delta, 'repository', 'postgres', 'databaseSizeBytes')):>17}"
    )
    print(
        f"sampled memory peak                 {human_bytes(peaks.get('sourceMemoryWindowPeakBytes')):>14}"
        f" {human_bytes(peaks.get('repositoryMemoryWindowPeakBytes')):>17}"
    )
    print(
        f"peak connections                    {str(peaks.get('sourceConnections')):>14}"
        f" {str(peaks.get('repositoryConnections')):>17}"
    )
    print(
        f"collector peak lag / freshness      {'-':>14}"
        f" {peaks.get('collectorLagSeconds')}s / {peaks.get('snapshotFreshnessSeconds')}s"
    )
    print(
        f"query API p95 / concurrency         {'-':>14}"
        f" {api.get('p95Seconds')}s / {api.get('concurrency')}"
    )
    endpoint_metrics = api.get("byEndpoint") or {}
    print(
        f"overview API p95                    {'-':>14}"
        f" {value_at(endpoint_metrics, 'overview', 'p95Seconds')}s"
    )
    print(
        f"query detail/trend API p95          {'-':>14}"
        f" {value_at(endpoint_metrics, 'query-detail', 'p95Seconds')}s"
    )
    print(
        f"source collection frequency         {source_frequency:>14}"
        f" {'-':>17}"
    )
    print(
        f"observed snapshot advances           {'-':>14}"
        f" {str(peaks.get('snapshotAdvanceCount')):>17}"
    )
    maintenance = value_at(derived, "powaMaintenance") or {}
    print(
        f"PoWA aggregate/purge crossings       {'-':>14}"
        f" {str(maintenance.get('aggregateBoundaryCrossings')) + ' / ' + str(maintenance.get('purgeBoundaryCrossings')):>17}"
    )
    print(
        f"capacity window classification       {'-':>14}"
        f" {str(maintenance.get('classification')):>17}"
    )
    failures = [check for check in report["guardrails"] if check["status"] == "FAIL"]
    skipped = [check for check in report["guardrails"] if check["status"] == "SKIP"]
    passed = len(report["guardrails"]) - len(failures) - len(skipped)
    print(
        f"guardrails                          {passed} pass, "
        f"{len(skipped)} skip, {len(failures)} fail"
    )
    for check in failures:
        print(f"  [FAIL] {check['name']}: actual={check['actual']} limit={check['limit']}")
    print(f"JSON report                         {report_path}")


def prepare_benchmark_environment(
    runner: CommandRunner,
    context: DockerContext,
    profile: str,
    *,
    prepare_first: bool,
) -> dict[str, str]:
    """Prepare image/seed outside the measured source/repository window."""

    workload_env = dict(os.environ)
    workload_env["COMPOSE_PROJECT_NAME"] = context.project
    workload_env["COMPOSE_FILE"] = context.compose_file
    # BuildKit and image pulls are host preparation, not source/repository
    # steady-state load. Complete them before the baseline and force the
    # wrapped run to reuse that image so elapsed CPU/API samples cannot be
    # diluted by an idle build window.
    runner.run(
        ["docker", "compose", "--profile", "realistic-load", "build", "workload"],
        capture=False,
        timeout=None,
        env=workload_env,
    )
    workload_env["REALISTIC_SKIP_BUILD"] = "true"
    workload_env["REALISTIC_SKIP_PREPARE"] = "false"
    if prepare_first:
        runner.run(
            ["bash", "scripts/prepare-realistic-workload.sh", profile, "--yes"],
            capture=False,
            timeout=None,
            env=workload_env,
        )
        workload_env["REALISTIC_SKIP_PREPARE"] = "true"
    return workload_env


def run_benchmark(args: argparse.Namespace, runner: CommandRunner) -> int:
    profile = args.profile
    default_duration, default_workers = DEFAULTS[profile]
    duration = args.duration if args.duration is not None else default_duration
    workers = args.workers if args.workers is not None else default_workers
    if not 30 <= duration <= 7200:
        raise BenchmarkError("duration 30..7200 saniye arasinda olmali")
    if not 3 <= workers <= 64:
        raise BenchmarkError("workers 3..64 arasinda olmali")
    sample_seconds = env_float("ERP_BENCHMARK_SAMPLE_SECONDS", 5.0, minimum=1.0)
    api_concurrency = env_int("ERP_API_CONCURRENCY", 2, minimum=1)
    api_overview_concurrency = env_int(
        "ERP_API_OVERVIEW_CONCURRENCY", 1, minimum=1
    )
    if api_concurrency > 8:
        raise BenchmarkError("ERP_API_CONCURRENCY en fazla 8 olmali")
    if api_overview_concurrency > 8:
        raise BenchmarkError("ERP_API_OVERVIEW_CONCURRENCY en fazla 8 olmali")
    prepare_first = env_bool("ERP_BENCHMARK_PREPARE_FIRST", True)
    fail_on_guardrail = env_bool("ERP_BENCHMARK_FAIL_ON_GUARDRAIL", True)
    preflight_timeout = env_int(
        "ERP_BENCHMARK_PREFLIGHT_TIMEOUT_SECONDS", 300, minimum=30
    )
    workload_grace = env_int(
        "ERP_BENCHMARK_WORKLOAD_GRACE_SECONDS", 300, minimum=30
    )
    sync_timeout = env_int("ERP_BENCHMARK_SYNC_TIMEOUT_SECONDS", 300, minimum=30)
    if sync_timeout > 3600:
        raise BenchmarkError("ERP_BENCHMARK_SYNC_TIMEOUT_SECONDS en fazla 3600 olmali")
    report_dir = pathlib.Path(
        os.environ.get("ERP_BENCHMARK_REPORT_DIR", "runtime/load-reports")
    )
    if not report_dir.is_absolute():
        report_dir = ROOT / report_dir
    context = resolve_context(runner)
    # Reject an unsafe/stale demo configuration before image build, seed and
    # the expensive workload run. The harness reports but never mutates the
    # monitored source registration.
    require_source_frequency(context.source_frequency)
    baseline_timeout = env_int(
        "ERP_BENCHMARK_BASELINE_TIMEOUT_SECONDS",
        max(60, context.source_frequency * 2),
        minimum=5,
    )
    print(
        f"ERP benchmark context: project={context.project}, "
        f"source={context.source_alias}/{context.server_id}, profile={profile}, "
        f"duration={duration}s, workers={workers}"
    )
    workload_env = prepare_benchmark_environment(
        runner, context, profile, prepare_first=prepare_first
    )
    # Warm connection pools and the 24h dashboard read paths before measurement.
    # A cold process may need to build the first bounded metrics-cache entry;
    # keep that one-time refresh outside the measured window while retaining
    # the strict 15-second timeout for every load-window probe below.
    warm_query_samples = capture_api_probe(
        runner,
        context,
        1,
        request_timeout_seconds=45.0,
        endpoint="query-list",
    )
    capture_api_probe(
        runner,
        context,
        1,
        request_timeout_seconds=45.0,
        endpoint="overview",
    )
    detail_target = next(
        (
            dict(item["selectedQuery"])
            for item in warm_query_samples
            if isinstance(item.get("selectedQuery"), Mapping)
        ),
        None,
    )
    if detail_target is not None:
        capture_api_probe(
            runner,
            context,
            1,
            request_timeout_seconds=45.0,
            endpoint="query-detail",
            detail_target=detail_target,
        )
    wait_for_repository_cache_refresh(runner, context)
    samples: list[dict[str, Any]] = []
    sampling_errors: list[str] = []
    api_samples: list[dict[str, Any]] = []
    api_errors: list[str] = []
    api_rotation = ("query-list", "overview", "query-detail")
    api_concurrency_by_endpoint = {
        "query-list": api_concurrency,
        "overview": api_overview_concurrency,
        "query-detail": api_concurrency,
    }
    api_completed_batches = {endpoint: 0 for endpoint in api_rotation}
    api_skipped_detail_batches = 0
    stop = threading.Event()

    def monitor() -> None:
        while not stop.is_set():
            try:
                samples.append(capture_sample(runner, context))
            except Exception as exc:  # monitoring must not hide workload result
                sampling_errors.append(f"{type(exc).__name__}: {str(exc)[:300]}")
            stop.wait(sample_seconds)

    def monitor_api() -> None:
        nonlocal detail_target, api_skipped_detail_batches
        rotation_index = 0
        while not stop.is_set():
            endpoint = api_rotation[rotation_index % len(api_rotation)]
            rotation_index += 1
            if endpoint == "query-detail" and detail_target is None:
                api_skipped_detail_batches += 1
                stop.wait(sample_seconds)
                continue
            try:
                probe_samples = capture_api_probe(
                    runner,
                    context,
                    api_concurrency_by_endpoint[endpoint],
                    endpoint=endpoint,
                    detail_target=detail_target,
                )
                api_samples.extend(probe_samples)
                api_completed_batches[endpoint] += 1
                if endpoint == "query-list":
                    selected_query = next(
                        (
                            item["selectedQuery"]
                            for item in probe_samples
                            if isinstance(item.get("selectedQuery"), Mapping)
                        ),
                        None,
                    )
                    if selected_query is not None:
                        detail_target = dict(selected_query)
            except Exception as exc:  # API failure is reported by its own gate
                api_errors.append(
                    f"{endpoint}: {type(exc).__name__}: {str(exc)[:300]}"
                )
            stop.wait(sample_seconds)

    monitor_thread = threading.Thread(target=monitor, name="erp-stack-monitor", daemon=True)
    api_thread = threading.Thread(
        target=monitor_api, name="erp-stack-api-monitor", daemon=True
    )
    monitor_started = False
    api_started = False
    threads_joined = False

    def stop_monitors() -> None:
        nonlocal threads_joined
        stop.set()
        if threads_joined:
            return
        if monitor_started:
            monitor_thread.join(timeout=45.0)
        if api_started:
            api_thread.join(timeout=30.0)
        if monitor_started and monitor_thread.is_alive():
            sampling_errors.append("monitor thread 45 saniyede durmadi")
        if api_started and api_thread.is_alive():
            api_errors.append("API monitor thread 30 saniyede durmadi")
        threads_joined = True

    wrapper_finished_at: str
    start_ready: Mapping[str, Any]
    end_ready: Mapping[str, Any]
    started_at: str
    start_continued_at: str
    generator_finished_at: str
    generator_elapsed_seconds: float
    measurement_finished_at: str
    elapsed_seconds: float
    end_continued_at: str
    before: dict[str, Any]
    after: dict[str, Any]
    thresholds: dict[str, Any]
    workload_exit_code: int
    with tempfile.TemporaryDirectory(prefix="advisor-erp-benchmark-") as raw_sync_dir:
        sync_directory = validate_sync_directory(pathlib.Path(raw_sync_dir).resolve())
        workload_env["REALISTIC_BENCHMARK_SYNC_DIR"] = str(sync_directory)
        workload_env["REALISTIC_BENCHMARK_SYNC_TIMEOUT_SECONDS"] = str(sync_timeout)
        process = runner.start(
            [
                "bash",
                "scripts/run-realistic-workload.sh",
                profile,
                str(duration),
                str(workers),
            ],
            capture=False,
            env=workload_env,
        )
        start_response_sent = False
        end_response_sent = False
        try:
            start_ready = wait_for_sync_payload(
                sync_path(sync_directory, "start", "ready"),
                timeout_seconds=float(preflight_timeout),
                process=process,
            )
            validate_phase_payload(start_ready, "start", "ready")

            # The shell wrapper is blocked immediately before the workload
            # container starts: preflight, health/manifest checks and
            # image setup cannot leak into this baseline or the elapsed time.
            before = capture_clean_baseline(
                runner,
                context,
                timeout_seconds=baseline_timeout,
            )
            thresholds = load_thresholds(
                before,
                context.source_frequency,
                duration_seconds=duration,
                sample_seconds=sample_seconds,
            )
            started_at = utc_now()
            started_monotonic = time.monotonic()
            monitor_thread.start()
            monitor_started = True
            api_thread.start()
            api_started = True
            publish_phase_response(sync_directory, "start")
            start_continued_at = utc_now()
            start_response_sent = True

            end_ready = wait_for_sync_payload(
                sync_path(sync_directory, "end", "ready"),
                timeout_seconds=float(duration + workload_grace),
                process=process,
            )
            validate_phase_payload(end_ready, "end", "ready")
            generator_finished_at = utc_now()
            generator_elapsed_seconds = max(
                time.monotonic() - started_monotonic, 0.000001
            )
            stop.set()
            stop_monitors()
            wait_for_repository_cache_refresh(runner, context)

            def record_final_container_boundary() -> None:
                nonlocal measurement_finished_at, elapsed_seconds
                measurement_finished_at = utc_now()
                elapsed_seconds = max(
                    time.monotonic() - started_monotonic, 0.000001
                )

            # Keep the wrapper blocked before FORCE snapshot and verifier
            # postlude. All in-flight probes finish before cgroup boundaries;
            # final metric SQL runs after those boundaries and is excluded.
            after = capture_snapshot(
                runner,
                context,
                container_boundary="first",
                boundary_callback=record_final_container_boundary,
            )
            publish_phase_response(sync_directory, "end")
            end_continued_at = utc_now()
            end_response_sent = True

            # Post-load validation still runs to completion and its exit code
            # remains an independent hard guardrail.
            workload_exit_code = process.wait()
            wrapper_finished_at = utc_now()
        except BaseException:
            stop.set()
            if not start_response_sent and sync_path(
                sync_directory, "start", "ready"
            ).exists():
                try:
                    publish_phase_response(
                        sync_directory, "start", status_value="abort"
                    )
                except Exception:
                    pass
            if start_response_sent and not end_response_sent and sync_path(
                sync_directory, "end", "ready"
            ).exists():
                try:
                    publish_phase_response(sync_directory, "end", status_value="abort")
                except Exception:
                    pass
            stop_monitors()
            stop_process(process)
            raise

    delta = calculate_delta(before, after)
    derived_metrics = calculate_derived_metrics(
        before,
        after,
        delta,
        elapsed_seconds,
        samples,
        expected_server_id=context.server_id,
    )
    peaks = calculate_peaks(before, after, samples, len(sampling_errors))
    api_metrics = calculate_api_metrics(
        api_samples,
        api_errors,
        api_concurrency,
        endpoint_concurrency=api_concurrency_by_endpoint,
    )
    api_metrics["probePlan"] = {
        "window": "24h",
        "rotation": list(api_rotation),
        "delayAfterBatchSeconds": sample_seconds,
        "concurrencyByEndpoint": dict(api_concurrency_by_endpoint),
        "completedBatches": dict(api_completed_batches),
        "skippedDetailBatchesWithoutSelection": api_skipped_detail_batches,
        "detailSelection": "first query from latest query-list batch",
    }
    guardrails = evaluate_guardrails(
        before,
        after,
        delta,
        peaks,
        api_metrics,
        thresholds,
        elapsed_seconds=elapsed_seconds,
        workload_exit_code=workload_exit_code,
    )
    failed = [check for check in guardrails if check["status"] == "FAIL"]
    report = {
        "schemaVersion": 4,
        "type": "advisor-erp-stack-benchmark",
        "status": "FAILED" if failed else "PASSED",
        "project": context.project,
        "sourceAlias": context.source_alias,
        "serverId": context.server_id,
        "profile": profile,
        "durationSeconds": duration,
        "workers": workers,
        "startedAt": started_at,
        "finishedAt": wrapper_finished_at,
        "measurementFinishedAt": measurement_finished_at,
        "elapsedSeconds": round(elapsed_seconds, 6),
        "generatorElapsedSeconds": round(generator_elapsed_seconds, 6),
        "workloadExitCode": workload_exit_code,
        "sourceFrequencySeconds": context.source_frequency,
        "measurementScope": {
            "sourceContainer": (
                "total source container cost: ERP workload, observer SQL and "
                "benchmark sampling; not isolated observer overhead"
            ),
            "observerOwnedSql": (
                "tracked pg_stat_statements/pg_stat_kcache subset for "
                "powa_collector and advisor_join_reader; role tracking=none "
                "makes the corresponding delta intentionally unavailable/zero"
            ),
            "repositoryContainer": (
                "total repository container cost including collector writes and "
                "dashboard API probe SQL"
            ),
        },
        "measurementBoundary": {
            "protocolVersion": SYNC_PROTOCOL_VERSION,
            "startReadyAt": start_ready.get("createdAt"),
            "baselineCapturedAt": before.get("capturedAt"),
            "measurementStartedAt": started_at,
            "startContinuedAt": start_continued_at,
            "endReadyAt": end_ready.get("createdAt"),
            "generatorFinishedAt": generator_finished_at,
            "measurementFinishedAt": measurement_finished_at,
            "afterCapturedAt": after.get("capturedAt"),
            "endContinuedAt": end_continued_at,
            "wrapperFinishedAt": wrapper_finished_at,
        },
        "before": before,
        "after": after,
        "delta": delta,
        "derivedMetrics": derived_metrics,
        "peaks": peaks,
        "api": api_metrics,
        "samplingErrors": sampling_errors,
        "apiErrors": api_errors,
        "thresholds": thresholds,
        "guardrails": guardrails,
    }
    report_path = write_report(report, report_dir, profile)
    print_summary(report, report_path)
    if workload_exit_code != 0:
        return workload_exit_code
    return 1 if failed and fail_on_guardrail else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Source ve PoWA repository ERP maliyetini before/after/delta ölçer."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run", help="realistic workload'u sar ve guardrail uygula")
    run.add_argument("profile", choices=tuple(DEFAULTS), nargs="?", default="erp")
    run.add_argument("duration", type=int, nargs="?")
    run.add_argument("workers", type=int, nargs="?")
    subparsers.add_parser("snapshot", help="salt-okunur tek metric snapshot'i yazdir")
    sync = subparsers.add_parser("sync-boundary", help=argparse.SUPPRESS)
    sync.add_argument("directory", type=pathlib.Path)
    sync.add_argument("phase", choices=SYNC_PHASES)
    sync.add_argument("timeout", type=float)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    if sys.version_info < (3, 10):
        print("[HATA] Python 3.10+ gerekli", file=sys.stderr)
        return 2
    parser = build_parser()
    args = parser.parse_args(argv)
    runner = CommandRunner()
    try:
        if args.command == "sync-boundary":
            workload_boundary_handshake(args.directory, args.phase, args.timeout)
            return 0
        if args.command == "snapshot":
            context = resolve_context(runner)
            print(json.dumps(capture_snapshot(runner, context), indent=2, sort_keys=True))
            return 0
        return run_benchmark(args, runner)
    except (BenchmarkError, subprocess.TimeoutExpired) as exc:
        print(f"[HATA] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
