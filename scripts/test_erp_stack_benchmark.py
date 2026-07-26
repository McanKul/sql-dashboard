from __future__ import annotations

import copy
import contextlib
import datetime as dt
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from scripts import erp_stack_benchmark as benchmark
from scripts import realistic_join_boundary as join_boundary


DATABASE_COUNTERS = {
    "xactCommit": 100,
    "xactRollback": 2,
    "blocksRead": 30,
    "blocksHit": 400,
    "tempFiles": 3,
    "tempBytes": 4_000,
    "deadlocks": 0,
    "tuplesInserted": 50,
    "tuplesUpdated": 60,
    "tuplesDeleted": 7,
    "sessions": 80,
    "activeTimeMs": 9_000.0,
    "readTimeMs": 100.0,
    "writeTimeMs": 20.0,
    "statsReset": None,
}
IO_COUNTERS = {
    "reads": 10,
    "readBytes": 1_000,
    "readTimeMs": 3.0,
    "writes": 20,
    "writeBytes": 2_000,
    "writeTimeMs": 4.0,
    "writebacks": 2,
    "extends": 3,
    "extendBytes": 300,
    "fsyncs": 4,
    "statsReset": "2026-01-01T00:00:00+00:00",
}


def observer_snapshot(*, after: bool) -> dict[str, object]:
    increment = 1 if after else 0
    roles = {
        "powa_collector": {
            "pgStatStatementsTrack": "all",
            "pgStatKcacheTrack": "top",
            "statementCount": 2,
            "calls": 10 + 5 * increment,
            "planTimeMs": 1.0 + increment,
            "execTimeMs": 10.0 + 4 * increment,
            "cpuUserSeconds": 0.10 + 0.05 * increment,
            "cpuSystemSeconds": 0.02 + 0.01 * increment,
            "cpuTotalSeconds": 0.12 + 0.06 * increment,
            "planCpuUserSeconds": 0.01 + 0.005 * increment,
            "planCpuSystemSeconds": 0.002 + 0.001 * increment,
            "statementEntryState": {"10:20:30:t": [1_000_000, 1_000_000]},
            "kcacheEntryState": {"10:20:30:t": [1_000_000]},
        },
        "advisor_join_reader": {
            "pgStatStatementsTrack": "all",
            "pgStatKcacheTrack": "top",
            "statementCount": 1,
            "calls": 3 + 2 * increment,
            "planTimeMs": 0.5 + 0.25 * increment,
            "execTimeMs": 4.0 + 2 * increment,
            "cpuUserSeconds": 0.04 + 0.02 * increment,
            "cpuSystemSeconds": 0.01 + 0.005 * increment,
            "cpuTotalSeconds": 0.05 + 0.025 * increment,
            "planCpuUserSeconds": 0.004 + 0.002 * increment,
            "planCpuSystemSeconds": 0.001 + 0.0005 * increment,
            "statementEntryState": {"11:21:31:t": [1_100_000, 1_100_000]},
            "kcacheEntryState": {"11:21:31:t": [1_100_000]},
        },
    }
    total_fields = (
        "statementCount",
        "calls",
        "planTimeMs",
        "execTimeMs",
        "cpuUserSeconds",
        "cpuSystemSeconds",
        "cpuTotalSeconds",
    )
    return {
        "roles": roles,
        "totals": {
            field: sum(float(role[field]) for role in roles.values())
            for field in total_fields
        },
    }


def snapshot(*, after: bool = False) -> dict[str, object]:
    increment = 10 if after else 0
    source_database = {
        key: value + increment
        if isinstance(value, (int, float)) and key != "deadlocks"
        else value
        for key, value in DATABASE_COUNTERS.items()
    }
    repository_database = copy.deepcopy(source_database)
    source_io = {
        key: value + increment
        if isinstance(value, (int, float))
        else value
        for key, value in IO_COUNTERS.items()
    }
    repository_io = copy.deepcopy(source_io)
    return {
        "capturedAt": "2026-01-01T00:01:00.000000Z" if after else "2026-01-01T00:00:00.000000Z",
        "source": {
            "container": {
                "cpuUsageUsec": 3_000_000 if after else 1_000_000,
                "ioReadBytes": 1_100 if after else 100,
                "ioWriteBytes": 2_200 if after else 200,
                "memoryCurrentBytes": 300_000 if after else 200_000,
                "memoryLifetimePeakBytes": 350_000 if after else 250_000,
                "memoryLimitBytes": None,
                "memoryLimitUnlimited": True,
                "memoryMaxEvents": 0,
                "memoryOomEvents": 0,
                "memoryOomKillEvents": 0,
                "cgroupVersion": 2,
                "startedAt": "2026-01-01T00:00:00Z",
            },
            "postgres": {
                "databaseSizeBytes": 2_000 if after else 1_000,
                "connectionsCurrent": 3 if after else 2,
                "maxConnections": 100,
                "databaseStats": source_database,
                "pgStatIo": source_io,
                "queries": {
                    "queryCount": 15 if after else 10,
                    "totalCalls": 300 if after else 100,
                    "taggedQueryCount": 8 if after else 5,
                    "taggedCalls": 120 if after else 20,
                    "trackedStatementCount": 300 if after else 100,
                    "collectorOwnedQueryCount": 0,
                    "dealloc": 4,
                    "maxTrackedStatements": 10_000,
                    "statsReset": "2026-01-01T00:00:00+00:00",
                    "appDbEntryState": {
                        "10:20:-30:t": [1_000_000, 1_000_000],
                        **(
                            {"10:20:31:t": [2_000_000, 2_000_000]}
                            if after
                            else {}
                        ),
                    },
                },
                "observerOwnedSql": observer_snapshot(after=after),
                "joinOutbox": {
                    "batchCount": 0,
                    "rowCount": 0,
                    "largestBatchRows": 0,
                    "oldestAgeSeconds": 0.0,
                    "payloadBytes": 8_192,
                    "storageBytes": 32_768,
                },
            },
        },
        "repository": {
            "container": {
                "cpuUsageUsec": 2_000_000 if after else 1_000_000,
                "ioReadBytes": 700 if after else 100,
                "ioWriteBytes": 900 if after else 100,
                "memoryCurrentBytes": 250_000 if after else 150_000,
                "memoryLifetimePeakBytes": 300_000 if after else 200_000,
                "memoryLimitBytes": 1_000_000,
                "memoryLimitUnlimited": False,
                "memoryMaxEvents": 0,
                "memoryOomEvents": 0,
                "memoryOomKillEvents": 0,
                "cgroupVersion": 2,
                "startedAt": "2026-01-01T00:00:00Z",
            },
            "postgres": {
                "databaseSizeBytes": 1_500 if after else 1_000,
                "connectionsCurrent": 4 if after else 3,
                "maxConnections": 100,
                "databaseStats": repository_database,
                "pgStatIo": repository_io,
                "queries": {
                    "queryCount": 12 if after else 10,
                    "statementSeries": 14 if after else 10,
                    "statementHistoryChunks": 25 if after else 20,
                    "statementCurrentSamples": 30 if after else 20,
                },
                "joinPurgeDebt": {
                    "retentionDays": 30,
                    "overdueBatchCount": 0,
                    "overdueRowCount": 0,
                    "oldestOverdueAgeSeconds": 0.0,
                    "storageBytes": 65_536,
                },
                "joinTransport": {
                    "status": "HEALTHY",
                    "lastError": None,
                    "stagingRows": 0,
                },
                "collector": {
                    "serverId": 7,
                    "status": "HEALTHY",
                    "lagSeconds": 2.0,
                    "errorCount": 0,
                    "frequencySeconds": 5,
                    "powaCoalesce": 100,
                    "powaVersion": "5.2.0",
                    "snapshotSequence": 12 if after else 10,
                    "snapshotAt": "2026-01-01T00:01:00.000000Z",
                    "snapshotFreshnessSeconds": 2.0,
                    "snapshotEpochUs": 2_000_000 if after else 1_000_000,
                },
            },
        },
    }


def thresholds() -> dict[str, object]:
    return {
        "maxSourceConnections": 90,
        "maxRepositoryConnections": 90,
        "maxCollectorLagSeconds": 30.0,
        "maxSnapshotFreshnessSeconds": 30.0,
        "minSnapshotAdvanceMicroseconds": 1,
        "minSourceTaggedCallsDelta": 1,
        "minSourceFrequencySeconds": 0,
        "minCollectorSnapshots": 1,
        "maxCollectorSnapshots": 200,
        "maxSourceDatabaseGrowthBytes": 4 * 1024**3,
        "maxRepositoryDatabaseGrowthBytes": 4 * 1024**3,
        "maxSamplingErrors": 3,
        "minPeakSamples": 1,
        "maxApiP95Seconds": 2.0,
        "maxApiOverviewP95Seconds": 8.0,
        "maxApiDetailP95Seconds": 2.0,
        "minApiSamples": 5,
        "maxApiErrors": 0,
        "maxPgssOccupancyPercent": 90.0,
        "maxJoinOutboxBatches": 100,
        "maxJoinOutboxRows": 1_000_000,
        "maxJoinOutboxLargestBatchRows": 250_000,
        "maxJoinOutboxOldestAgeSeconds": 30.0,
        "maxJoinOutboxPayloadBytes": 512 * 1024**2,
        "maxJoinOutboxStorageBytes": 1024**3,
        "maxJoinPurgeDebtBatches": 0,
        "maxJoinPurgeDebtRows": 0,
        "maxSourceAverageCpuCores": 0.0,
        "maxRepositoryAverageCpuCores": 0.0,
        "maxRepositorySourceCpuRatio": 0.0,
        "maxSourceIoBytes": 0,
        "maxRepositoryIoBytes": 0,
        "maxSourceMemoryBytes": 0,
        "maxRepositoryMemoryBytes": 0,
        "maxMemoryPressureEventsDelta": 0,
        "maxOomEventsDelta": 0,
        "maxOomKillEventsDelta": 0,
        "requireCgroupMetrics": True,
        "requireCgroupMemoryEvents": True,
    }


class DeltaTests(unittest.TestCase):
    def test_before_after_delta_preserves_gauges_and_counters(self) -> None:
        delta = benchmark.calculate_delta(snapshot(), snapshot(after=True))
        self.assertEqual(delta["source"]["container"]["cpuUsageSeconds"], 2.0)
        self.assertEqual(delta["source"]["container"]["ioReadBytes"], 1_000)
        self.assertEqual(
            delta["source"]["postgres"]["queries"]["taggedCalls"], 100
        )
        self.assertEqual(
            delta["source"]["postgres"]["observerOwnedSql"]["totals"]["calls"],
            7.0,
        )
        self.assertAlmostEqual(
            delta["source"]["postgres"]["observerOwnedSql"]["totals"][
                "cpuTotalSeconds"
            ],
            0.085,
        )
        self.assertEqual(
            delta["repository"]["postgres"]["collector"]["snapshotSequence"],
            2,
        )
        self.assertEqual(
            delta["source"]["container"]["memoryLifetimePeakBytes"], 100_000
        )
        self.assertEqual(
            delta["source"]["postgres"]["queries"]["entryContinuity"][
                "missingEntryCount"
            ],
            0,
        )
        self.assertEqual(delta["counterDecreases"], [])

    def test_counter_decrease_is_explicit(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        after["source"]["container"]["cpuUsageUsec"] = 1
        after["repository"]["postgres"]["databaseStats"]["xactCommit"] = 1
        delta = benchmark.calculate_delta(before, after)
        self.assertIn("source.container.cpuUsageUsec", delta["counterDecreases"])
        self.assertIn(
            "repository.postgres.databaseStats.xactCommit",
            delta["counterDecreases"],
        )

    def test_pgss_continuity_detects_scoped_reset_and_disappearance(self) -> None:
        before = {
            "1:2:3:t": [100, 100],
            "1:2:4:t": [200, 200],
            "1:2:5:f": [300, 300],
        }
        after = {
            "1:2:3:t": [999, 999],
            "1:2:5:f": [300, 300],
            "1:2:6:t": [400, 400],
        }
        result = benchmark.calculate_pgss_continuity(before, after)
        self.assertTrue(result["stateValid"])
        self.assertEqual(result["missingEntryCount"], 1)
        self.assertEqual(result["resetEntryCount"], 1)
        self.assertEqual(result["missingEntryKeys"], ["1:2:4:t"])
        self.assertEqual(result["resetEntryKeys"], ["1:2:3:t"])

    def test_pgss_continuity_rejects_missing_or_malformed_state(self) -> None:
        for before, after in ((None, {}), ({"key": [1]}, {"key": [1]})):
            with self.subTest(before=before, after=after):
                self.assertFalse(
                    benchmark.calculate_pgss_continuity(before, after)["stateValid"]
                )

    def test_kcache_continuity_detects_per_entry_reset(self) -> None:
        result = benchmark.calculate_kcache_continuity(
            {"1:2:3:t": [100]}, {"1:2:3:t": [200]}
        )
        self.assertTrue(result["stateValid"])
        self.assertEqual(result["resetEntryCount"], 1)

    def test_sampled_memory_peak_captures_mid_window_high_watermark(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        samples = [
            {
                "source": {
                    "connections": 20,
                    "container": {"memoryCurrentBytes": 900_000},
                },
                "repository": {
                    "connections": 10,
                    "collectorLagSeconds": 5.0,
                    "snapshotFreshnessSeconds": 5.0,
                    "container": {"memoryCurrentBytes": 800_000},
                },
            }
        ]
        peaks = benchmark.calculate_peaks(before, after, samples, 0)
        self.assertEqual(peaks["sourceMemoryWindowPeakBytes"], 900_000)
        self.assertEqual(peaks["repositoryMemoryWindowPeakBytes"], 800_000)

    def test_snapshot_cadence_counts_distinct_observed_advances(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        before["repository"]["postgres"]["collector"]["snapshotEpochUs"] = 100
        after["repository"]["postgres"]["collector"]["snapshotEpochUs"] = 400
        samples = [
            {"repository": {"snapshotEpochUs": epoch}}
            for epoch in (100, 200, 200, 300)
        ]
        peaks = benchmark.calculate_peaks(before, after, samples, 0)
        self.assertEqual(peaks["snapshotAdvanceCount"], 3)
        self.assertFalse(peaks["snapshotEpochRegression"])

        samples[2]["repository"]["snapshotEpochUs"] = 150
        peaks = benchmark.calculate_peaks(before, after, samples, 0)
        self.assertTrue(peaks["snapshotEpochRegression"])


class DerivedMetricsTests(unittest.TestCase):
    def test_container_io_rates_use_measured_elapsed_window(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        delta = benchmark.calculate_delta(before, after)

        derived = benchmark.calculate_derived_metrics(
            before,
            after,
            delta,
            10.0,
            expected_server_id=7,
        )

        self.assertEqual(derived["measurementSeconds"], 10.0)
        self.assertEqual(
            derived["source"]["containerIo"],
            {
                "scope": "containerBlockIo",
                "readBytesPerSecond": 100.0,
                "writeBytesPerSecond": 200.0,
                "totalBytesPerSecond": 300.0,
            },
        )
        self.assertEqual(
            derived["repository"]["containerIo"]["readBytesPerSecond"],
            60.0,
        )
        self.assertEqual(
            derived["repository"]["containerIo"]["writeBytesPerSecond"],
            80.0,
        )
        self.assertEqual(
            derived["repository"]["containerIo"]["totalBytesPerSecond"],
            140.0,
        )

    def test_io_rates_fail_closed_for_bad_window_or_counter(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        delta = benchmark.calculate_delta(before, after)
        delta["source"]["container"]["ioReadBytes"] = -1

        derived = benchmark.calculate_derived_metrics(
            before, after, delta, float("nan")
        )

        self.assertIsNone(derived["measurementSeconds"])
        self.assertIsNone(
            derived["source"]["containerIo"]["readBytesPerSecond"]
        )
        self.assertIsNone(
            derived["source"]["containerIo"]["writeBytesPerSecond"]
        )
        self.assertIsNone(
            derived["source"]["containerIo"]["totalBytesPerSecond"]
        )

    def test_powa_crossings_match_server_offset_and_open_closed_window(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        before_collector = before["repository"]["postgres"]["collector"]
        after_collector = after["repository"]["postgres"]["collector"]
        # srvid=7 shifts aggregate to sequence 93 and purge to sequence 94.
        before_collector["snapshotSequence"] = 92
        after_collector["snapshotSequence"] = 94

        maintenance = benchmark.calculate_powa_maintenance(
            before, after, expected_server_id=7
        )

        self.assertEqual(maintenance["aggregateBoundaryCrossings"], 1)
        self.assertEqual(maintenance["purgeBoundaryCrossings"], 1)
        self.assertTrue(maintenance["maintenanceInclusive"])
        self.assertFalse(maintenance["steadyStateEligible"])
        self.assertEqual(
            maintenance["classification"], "MAINTENANCE_INCLUSIVE"
        )
        self.assertEqual(maintenance["boundaryInterval"], "(before, after]")

        # A boundary already represented by the baseline is excluded.
        before_collector["snapshotSequence"] = 93
        after_collector["snapshotSequence"] = 94
        maintenance = benchmark.calculate_powa_maintenance(before, after)
        self.assertEqual(maintenance["aggregateBoundaryCrossings"], 0)
        self.assertEqual(maintenance["purgeBoundaryCrossings"], 1)

    def test_known_window_without_maintenance_is_steady_state_eligible(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        before["repository"]["postgres"]["collector"].update(
            {"serverId": 1, "powaCoalesce": 100, "snapshotSequence": 7009}
        )
        after["repository"]["postgres"]["collector"].update(
            {"serverId": 1, "powaCoalesce": 100, "snapshotSequence": 7013}
        )
        samples = [
            {
                "repository": {
                    "serverId": 1,
                    "powaCoalesce": 100,
                    "powaVersion": "5.2.0",
                    "snapshotSequence": sequence,
                }
            }
            for sequence in (7010, 7012)
        ]

        maintenance = benchmark.calculate_powa_maintenance(
            before, after, samples, expected_server_id=1
        )

        self.assertEqual(maintenance["aggregateBoundaryCrossings"], 0)
        self.assertEqual(maintenance["purgeBoundaryCrossings"], 0)
        self.assertFalse(maintenance["maintenanceInclusive"])
        self.assertTrue(maintenance["steadyStateEligible"])
        self.assertEqual(
            maintenance["classification"], "STEADY_STATE_ELIGIBLE"
        )

    def test_documented_6998_to_7002_window_crosses_both_boundaries(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        before["repository"]["postgres"]["collector"].update(
            {"serverId": 1, "powaCoalesce": 100, "snapshotSequence": 6998}
        )
        after["repository"]["postgres"]["collector"].update(
            {"serverId": 1, "powaCoalesce": 100, "snapshotSequence": 7002}
        )

        maintenance = benchmark.calculate_powa_maintenance(before, after)

        self.assertEqual(maintenance["aggregateBoundaryCrossings"], 1)
        self.assertEqual(maintenance["purgeBoundaryCrossings"], 1)
        self.assertTrue(maintenance["maintenanceInclusive"])

    def test_multiple_boundary_crossings_are_counted_not_just_flagged(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        before["repository"]["postgres"]["collector"].update(
            {"serverId": 0, "powaCoalesce": 5, "snapshotSequence": 0}
        )
        after["repository"]["postgres"]["collector"].update(
            {"serverId": 0, "powaCoalesce": 5, "snapshotSequence": 15}
        )

        maintenance = benchmark.calculate_powa_maintenance(before, after)

        self.assertEqual(maintenance["aggregateBoundaryCrossings"], 3)
        self.assertEqual(maintenance["purgeBoundaryCrossings"], 3)

    def test_unknown_evidence_never_claims_steady_state(self) -> None:
        cases = {}

        missing = (snapshot(), snapshot(after=True), ())
        del missing[1]["repository"]["postgres"]["collector"]["powaCoalesce"]
        cases["missing"] = missing

        changed = (snapshot(), snapshot(after=True), ())
        changed[1]["repository"]["postgres"]["collector"]["powaCoalesce"] = 50
        cases["changed"] = changed

        changed_server = (snapshot(), snapshot(after=True), ())
        changed_server[1]["repository"]["postgres"]["collector"]["serverId"] = 8
        cases["changed-server"] = changed_server

        unsupported_version = (snapshot(), snapshot(after=True), ())
        unsupported_version[0]["repository"]["postgres"]["collector"][
            "powaVersion"
        ] = "99.0.0"
        unsupported_version[1]["repository"]["postgres"]["collector"][
            "powaVersion"
        ] = "99.0.0"
        cases["unsupported-version"] = unsupported_version

        regressed = (snapshot(), snapshot(after=True), ())
        regressed[0]["repository"]["postgres"]["collector"]["snapshotSequence"] = 20
        regressed[1]["repository"]["postgres"]["collector"]["snapshotSequence"] = 19
        cases["regressed"] = regressed

        sampled_regression = (
            snapshot(),
            snapshot(after=True),
            [
                {
                    "repository": {
                        "serverId": 7,
                        "powaCoalesce": 100,
                        "powaVersion": "5.2.0",
                        "snapshotSequence": 9,
                    }
                }
            ],
        )
        cases["sampled-regression"] = sampled_regression

        for name, (before, after, samples) in cases.items():
            with self.subTest(name=name):
                maintenance = benchmark.calculate_powa_maintenance(
                    before, after, samples, expected_server_id=7
                )
                self.assertEqual(maintenance["classification"], "UNKNOWN")
                self.assertIsNone(maintenance["maintenanceInclusive"])
                self.assertFalse(maintenance["steadyStateEligible"])
                self.assertIsNone(maintenance["aggregateBoundaryCrossings"])
                self.assertIsNone(maintenance["purgeBoundaryCrossings"])
                self.assertTrue(maintenance["unknownReasons"])

    def test_no_snapshot_progress_is_not_steady_state_evidence(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        after["repository"]["postgres"]["collector"]["snapshotSequence"] = 10

        maintenance = benchmark.calculate_powa_maintenance(before, after)

        self.assertEqual(
            maintenance["classification"], "INSUFFICIENT_SNAPSHOT_PROGRESS"
        )
        self.assertFalse(maintenance["maintenanceInclusive"])
        self.assertFalse(maintenance["steadyStateEligible"])


class GuardrailTests(unittest.TestCase):
    def evaluate(
        self,
        before=None,
        after=None,
        limits=None,
        *,
        workload=0,
        api_metrics=None,
    ):
        before = before or snapshot()
        after = after or snapshot(after=True)
        delta = benchmark.calculate_delta(before, after)
        peaks = benchmark.calculate_peaks(
            before,
            after,
            [
                {
                    "source": {"connections": 20},
                    "repository": {
                        "connections": 10,
                        "collectorLagSeconds": 5.0,
                        "snapshotFreshnessSeconds": 5.0,
                    },
                }
            ],
            0,
        )
        return benchmark.evaluate_guardrails(
            before,
            after,
            delta,
            peaks,
            api_metrics
            or benchmark.calculate_api_metrics(
                [
                    {"latencySeconds": 0.25, "itemCount": 50},
                    {"latencySeconds": 0.30, "itemCount": 50},
                    {"latencySeconds": 0.35, "itemCount": 50},
                    {"latencySeconds": 0.40, "itemCount": 50},
                    {"latencySeconds": 0.45, "itemCount": 50},
                ],
                [],
                2,
            ),
            limits or thresholds(),
            elapsed_seconds=60.0,
            workload_exit_code=workload,
        )

    def test_portable_defaults_pass_and_hardware_ceilings_skip(self) -> None:
        checks = self.evaluate()
        failures = [item for item in checks if item["status"] == "FAIL"]
        skipped = {item["name"] for item in checks if item["status"] == "SKIP"}
        self.assertEqual(failures, [])
        self.assertIn("source_average_cpu_cores", skipped)
        self.assertIn("repository_container_io_bytes", skipped)

    def test_endpoint_specific_api_latency_guardrails_are_independent(self) -> None:
        samples = []
        for latency in (0.25, 0.30, 0.35, 0.40, 0.45):
            samples.extend(
                (
                    {
                        "endpoint": "query-list",
                        "latencySeconds": latency,
                        "itemCount": 50,
                    },
                    {
                        "endpoint": "overview",
                        "latencySeconds": 5.25,
                        "itemCount": None,
                    },
                    {
                        "endpoint": "query-detail",
                        "latencySeconds": 0.20,
                        "itemCount": None,
                    },
                )
            )
        api_metrics = benchmark.calculate_api_metrics(samples, [], 2)
        checks = self.evaluate(api_metrics=api_metrics)
        statuses = {item["name"]: item["status"] for item in checks}
        self.assertEqual(statuses["api_query_p95"], "PASS")
        self.assertEqual(statuses["api_overview_p95"], "PASS")
        self.assertEqual(statuses["api_query_detail_p95"], "PASS")

        api_metrics["byEndpoint"]["overview"]["p95Seconds"] = 8.01
        checks = self.evaluate(api_metrics=api_metrics)
        statuses = {item["name"]: item["status"] for item in checks}
        self.assertEqual(statuses["api_query_p95"], "PASS")
        self.assertEqual(statuses["api_overview_p95"], "FAIL")
        self.assertEqual(statuses["api_query_detail_p95"], "PASS")

    def test_restart_reset_stale_collector_and_workload_failure_fail_closed(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        after["source"]["container"]["startedAt"] = "2026-01-01T00:00:30Z"
        after["source"]["postgres"]["databaseStats"]["statsReset"] = (
            "2026-01-01T00:00:30+00:00"
        )
        after["source"]["postgres"]["queries"]["taggedCalls"] = 20
        after["repository"]["postgres"]["collector"]["status"] = "STALE"
        checks = self.evaluate(before, after, workload=7)
        failed = {item["name"] for item in checks if item["status"] == "FAIL"}
        self.assertTrue(
            {
                "workload_exit_code",
                "source_container_restart",
                "source_database_reset",
                "source_tagged_query_calls",
                "collector_health",
            }.issubset(failed)
        )

    def test_opt_in_cpu_and_io_ceilings_are_enforced(self) -> None:
        limits = thresholds()
        limits.update(
            {
                "maxSourceAverageCpuCores": 0.001,
                "maxRepositoryAverageCpuCores": 0.001,
                "maxRepositorySourceCpuRatio": 0.1,
                "maxSourceIoBytes": 1,
                "maxRepositoryIoBytes": 1,
            }
        )
        checks = self.evaluate(limits=limits)
        failed = {item["name"] for item in checks if item["status"] == "FAIL"}
        self.assertTrue(
            {
                "source_average_cpu_cores",
                "repository_average_cpu_cores",
                "repository_source_cpu_ratio",
                "source_container_io_bytes",
                "repository_container_io_bytes",
            }.issubset(failed)
        )

    def test_pgss_capacity_and_collector_tracking_are_hard_failures(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        after["source"]["postgres"]["queries"]["dealloc"] = 5
        after["source"]["postgres"]["queries"]["collectorOwnedQueryCount"] = 1
        checks = self.evaluate(before, after)
        failed = {item["name"] for item in checks if item["status"] == "FAIL"}
        self.assertTrue(
            {
                "source_pgss_dealloc_delta",
                "source_collector_owned_query_delta",
            }.issubset(failed)
        )

    def test_source_collection_frequency_is_reported_but_never_mutated(self) -> None:
        limits = thresholds()
        limits["minSourceFrequencySeconds"] = 30
        checks = self.evaluate(limits=limits)
        by_name = {item["name"]: item for item in checks}
        self.assertEqual(
            by_name["source_collection_frequency_minimum"]["status"], "FAIL"
        )

        before = snapshot()
        after = snapshot(after=True)
        before["repository"]["postgres"]["collector"]["frequencySeconds"] = 60
        after["repository"]["postgres"]["collector"]["frequencySeconds"] = 60
        checks = self.evaluate(before, after, limits)
        by_name = {item["name"]: item for item in checks}
        self.assertEqual(
            by_name["source_collection_frequency_minimum"]["status"], "PASS"
        )
        self.assertEqual(
            by_name["source_collection_frequency_unchanged"]["status"], "PASS"
        )

        after["repository"]["postgres"]["collector"]["frequencySeconds"] = 30
        checks = self.evaluate(before, after, limits)
        by_name = {item["name"]: item for item in checks}
        self.assertEqual(
            by_name["source_collection_frequency_unchanged"]["status"], "FAIL"
        )

    def test_scoped_pgss_reset_and_memory_events_fail_closed(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        after["source"]["postgres"]["queries"]["appDbEntryState"][
            "10:20:-30:t"
        ] = [9_000_000, 9_000_000]
        after["source"]["postgres"]["observerOwnedSql"]["roles"][
            "powa_collector"
        ]["kcacheEntryState"]["10:20:30:t"] = [9_000_000]
        after["source"]["container"]["memoryMaxEvents"] = 1
        after["repository"]["container"]["memoryOomEvents"] = 1
        after["repository"]["container"]["memoryOomKillEvents"] = 1
        checks = self.evaluate(before, after)
        failed = {item["name"] for item in checks if item["status"] == "FAIL"}
        self.assertTrue(
            {
                "source_pgss_entry_continuity",
                "source_observer_counter_continuity",
                "source_memory_pressure_events",
                "repository_memory_oom_events",
                "repository_memory_oom_kill_events",
            }.issubset(failed)
        )

    def test_peak_sample_count_and_opt_in_memory_ceiling_are_enforced(self) -> None:
        limits = thresholds()
        limits["minPeakSamples"] = 2
        limits["maxSourceMemoryBytes"] = 250_000
        checks = self.evaluate(limits=limits)
        failed = {item["name"] for item in checks if item["status"] == "FAIL"}
        self.assertIn("peak_sample_count", failed)
        self.assertIn("source_memory_window_peak", failed)

    def test_missing_memory_events_and_limit_change_fail_closed(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        after["source"]["container"]["memoryOomEvents"] = None
        after["repository"]["container"]["memoryLimitBytes"] = 900_000
        after["repository"]["container"]["memoryLimitUnlimited"] = False
        checks = self.evaluate(before, after)
        failed = {item["name"] for item in checks if item["status"] == "FAIL"}
        self.assertIn("cgroup_memory_event_metrics_available", failed)
        self.assertIn("repository_memory_limit_unchanged", failed)

    def test_cgroup_v1_failcnt_is_hard_but_exact_oom_is_auto_skipped(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        for value in (before, after):
            for target in ("source", "repository"):
                container = value[target]["container"]
                container["cgroupVersion"] = 1
                container["memoryOomEvents"] = None
                container["memoryOomKillEvents"] = None
        checks = self.evaluate(before, after)
        by_name = {item["name"]: item for item in checks}
        self.assertEqual(by_name["source_memory_pressure_events"]["status"], "PASS")
        self.assertEqual(by_name["source_memory_oom_events"]["status"], "SKIP")
        self.assertEqual(
            by_name["source_memory_oom_kill_events"]["status"], "SKIP"
        )
        self.assertEqual(
            by_name["cgroup_memory_event_metrics_available"]["status"], "PASS"
        )

    def test_coalesce_sequence_cycle_does_not_fail_snapshot_progress(self) -> None:
        before = snapshot()
        after = snapshot(after=True)
        before["repository"]["postgres"]["collector"]["snapshotSequence"] = 99
        after["repository"]["postgres"]["collector"]["snapshotSequence"] = 0
        checks = self.evaluate(before, after)
        by_name = {item["name"]: item for item in checks}
        self.assertEqual(by_name["snapshot_time_advance"]["status"], "PASS")
        self.assertNotIn(
            "repository.postgres.collector.snapshotSequence",
            benchmark.calculate_delta(before, after)["counterDecreases"],
        )


class ConfigurationTests(unittest.TestCase):
    def test_full_verify_warms_query_list_before_strict_latency_gate(self) -> None:
        verifier_path = benchmark.ROOT / "scripts/verify.sh"
        verifier = verifier_path.read_text(encoding="utf-8")

        warmup_call = (
            'curl -fsS --max-time "$verify_api_warmup_timeout_seconds"'
        )
        timed_call = "http_seconds=\"$(curl -fsS"
        self.assertIn(
            'verify_api_warmup_timeout_seconds="${VERIFY_API_WARMUP_TIMEOUT_SECONDS:-45}"',
            verifier,
        )
        self.assertLess(verifier.index(warmup_call), verifier.index(timed_call))
        self.assertIn("performance-warmup.json", verifier)
        self.assertIn("payload['total'] > 0", verifier)
        self.assertIn("payload['items']", verifier)
        self.assertIn("elapsed < 2.0", verifier)
        self.assertIn("latency kapisi disinda", verifier)

        for invalid_value in ("4", "121", "not-a-number"):
            with self.subTest(invalid_value=invalid_value):
                result = subprocess.run(
                    ["bash", str(verifier_path)],
                    cwd=benchmark.ROOT,
                    env={
                        **os.environ,
                        "VERIFY_API_WARMUP_TIMEOUT_SECONDS": invalid_value,
                    },
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "VERIFY_API_WARMUP_TIMEOUT_SECONDS 5-120 arasinda olmali",
                    result.stderr,
                )
                self.assertNotIn("Compose yapilandirmasi gecerli", result.stdout)

    def test_full_verify_snapshot_waits_follow_persisted_cadence(self) -> None:
        verifier_path = benchmark.ROOT / "scripts/verify.sh"
        verifier = verifier_path.read_text(encoding="utf-8")

        self.assertIn("SELECT id, frequency FROM", verifier)
        self.assertIn(
            'verify_snapshot_grace_seconds="${VERIFY_SNAPSHOT_GRACE_SECONDS:-30}"',
            verifier,
        )
        self.assertIn(
            "demo_source_frequency + verify_snapshot_grace_seconds", verifier
        )
        self.assertIn(
            "snapshot_wait_timeout_seconds >= 40", verifier
        )
        self.assertEqual(verifier.count("wait_for_forced_snapshot_state"), 5)
        self.assertEqual(
            verifier.count("NOTIFY powa_collector, 'FORCE_SNAPSHOT"), 1
        )
        self.assertNotIn("for attempt in $(seq 1 20); do", verifier)
        self.assertGreaterEqual(
            verifier.count("attempt <= snapshot_wait_attempts"), 3
        )

        for invalid_value in ("4", "301", "not-a-number"):
            with self.subTest(invalid_value=invalid_value):
                result = subprocess.run(
                    ["bash", str(verifier_path)],
                    cwd=benchmark.ROOT,
                    env={
                        **os.environ,
                        "VERIFY_SNAPSHOT_GRACE_SECONDS": invalid_value,
                    },
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "VERIFY_SNAPSHOT_GRACE_SECONDS 5-300 arasinda olmali",
                    result.stderr,
                )
                self.assertNotIn("Compose yapilandirmasi gecerli", result.stdout)

    def test_database_metric_probe_is_bounded_and_fails_closed(self) -> None:
        verifier = (
            benchmark.ROOT / "scripts/verify-realistic-workload.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'database_metrics_timeout_seconds="${REALISTIC_DATABASE_METRICS_TIMEOUT_SECONDS:-30}"',
            verifier,
        )
        self.assertIn(
            "database_metrics_timeout_seconds >= 5", verifier
        )
        self.assertIn(
            "database_metrics_timeout_seconds <= 120", verifier
        )
        self.assertIn(
            "statement_timeout=${database_metrics_timeout_ms}ms", verifier
        )
        self.assertIn(
            "application_name=advisor-realistic-database-metric-verifier",
            verifier,
        )
        self.assertIn(
            'if ! database_metric_state="$(repository_sql_bounded_database_metrics',
            verifier,
        )
        self.assertIn(
            "/* advisor-realistic:database-metric-state */", verifier
        )
        self.assertIn(
            'fatal "Database I/O metric sorgusu tamamlanamadi', verifier
        )

    def test_post_load_verifier_aligns_untimed_warmup_with_default_ui_window(
        self,
    ) -> None:
        verifier = (
            benchmark.ROOT / "scripts/verify-realistic-workload.sh"
        ).read_text(encoding="utf-8")
        marker = '"$api_container" python - <<\'PY\'\n'
        probe_script = verifier.split(marker, 1)[1].split("\nPY\n)", 1)[0]
        requested: list[tuple[str, float]] = []

        def urlopen(request, *, timeout):
            url = request if isinstance(request, str) else request.full_url
            requested.append((url, float(timeout)))
            payload = (
                {"repository": "healthy"}
                if url.endswith("/api/v1/health")
                else {"items": [{"queryId": "42"}]}
            )
            return io.BytesIO(json.dumps(payload).encode("utf-8"))

        output = io.StringIO()
        with mock.patch.dict(
            os.environ,
            {
                "REALISTIC_API_SAMPLES": "20",
                "REALISTIC_API_WINDOW": "24h",
                "REALISTIC_API_WARMUP_TIMEOUT_SECONDS": "45",
                "REALISTIC_SERVER_ID": "7",
            },
            clear=False,
        ), mock.patch(
            "urllib.request.urlopen", side_effect=urlopen
        ), contextlib.redirect_stdout(output):
            exec(probe_script, {})

        self.assertEqual(len(requested), 22)
        self.assertEqual(requested[0][1], 5.0)
        self.assertEqual(requested[1][1], 45.0)
        self.assertTrue(all(timeout == 5.0 for _, timeout in requested[2:]))
        self.assertTrue(
            all("window=24h" in url for url, _ in requested[1:])
        )
        self.assertIn("|20|20", output.getvalue())
        self.assertIn(
            'REALISTIC_API_WINDOW="${REALISTIC_API_WINDOW:-24h}"', verifier
        )
        self.assertIn(
            'REALISTIC_API_WARMUP_TIMEOUT_SECONDS="${REALISTIC_API_WARMUP_TIMEOUT_SECONDS:-45}"',
            verifier,
        )
        self.assertIn("${REALISTIC_MAX_API_P95_SECONDS:-2.0}", verifier)

    def test_api_probe_script_covers_rotated_default_ui_endpoints(self) -> None:
        requested_urls: list[str] = []

        def urlopen(request, *, timeout):
            self.assertEqual(timeout, 12.0)
            url = request.full_url
            requested_urls.append(url)
            if "/api/v1/queries?" in url:
                payload = {
                    "items": [
                        {"queryId": "-42", "serverId": 7, "databaseId": 19}
                    ]
                }
            elif "/api/v1/overview?" in url:
                payload = {"cards": {}, "topQueries": [], "trend": []}
            elif "/api/v1/queries/-42?" in url:
                payload = {"queryId": "-42", "trend": []}
            else:  # pragma: no cover - makes an unexpected URL fail loudly
                self.fail(f"unexpected API probe URL: {url}")
            return io.BytesIO(json.dumps(payload).encode("utf-8"))

        def execute_probe(endpoint: str, *target: str) -> list[dict[str, object]]:
            output = io.StringIO()
            argv = ["api-probe", "7", "1", "12", endpoint, *target]
            with mock.patch.object(sys, "argv", argv), mock.patch(
                "urllib.request.urlopen", side_effect=urlopen
            ), contextlib.redirect_stdout(output):
                exec(benchmark.API_PROBE_SCRIPT, {})
            return json.loads(output.getvalue())

        results = [
            *execute_probe("query-list"),
            *execute_probe("overview"),
            *execute_probe("query-detail", "-42", "7", "19"),
        ]

        self.assertEqual(
            [item["endpoint"] for item in results],
            ["query-list", "overview", "query-detail"],
        )
        self.assertEqual(
            results[0]["selectedQuery"],
            {"queryId": "-42", "serverId": 7, "databaseId": 19},
        )
        self.assertIn("window=24h&pageSize=50&serverId=7", requested_urls[0])
        self.assertEqual(
            requested_urls[1],
            "http://127.0.0.1:8000/api/v1/overview?window=24h",
        )
        self.assertIn("/api/v1/queries/-42?window=24h", requested_urls[2])
        self.assertIn("serverId=7", requested_urls[2])
        self.assertIn("databaseId=19", requested_urls[2])

    def test_capture_and_metrics_keep_query_list_legacy_fields(self) -> None:
        payload = [
            {
                "endpoint": "query-list",
                "latencySeconds": 0.10,
                "itemCount": 4,
                "selectedQuery": {
                    "queryId": "42",
                    "serverId": 7,
                    "databaseId": 19,
                },
            },
            {
                "endpoint": "query-list",
                "latencySeconds": 0.11,
                "itemCount": 0,
            },
        ]
        runner = mock.Mock()
        runner.run.return_value = subprocess.CompletedProcess(
            ["docker"], 0, json.dumps(payload), ""
        )
        context = benchmark.DockerContext(
            "advisor-live",
            "/srv/compose.yaml",
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )

        query_samples = benchmark.capture_api_probe(runner, context, 2)

        self.assertEqual(query_samples, payload)
        self.assertEqual(runner.run.call_args.kwargs["timeout"], 25.0)
        samples = [
            *query_samples,
            {"endpoint": "overview", "latencySeconds": 5.0, "itemCount": None},
            {
                "endpoint": "query-detail",
                "latencySeconds": 0.30,
                "itemCount": None,
            },
        ]
        metrics = benchmark.calculate_api_metrics(
            samples,
            [],
            2,
            endpoint_concurrency={
                "query-list": 2,
                "overview": 1,
                "query-detail": 2,
            },
        )
        self.assertEqual(metrics["sampleCount"], 2)
        self.assertEqual(metrics["minimumItems"], 0)
        self.assertEqual(metrics["maximumItems"], 4)
        self.assertEqual(metrics["p95Seconds"], 0.11)
        self.assertEqual(metrics["byEndpoint"]["overview"]["p95Seconds"], 5.0)
        self.assertEqual(metrics["byEndpoint"]["overview"]["concurrency"], 1)
        self.assertEqual(
            metrics["byEndpoint"]["query-detail"]["p95Seconds"], 0.30
        )
        error_metrics = benchmark.calculate_api_metrics(
            samples,
            ["overview: timeout", "query-list: timeout"],
            2,
        )
        self.assertEqual(error_metrics["errorCount"], 1)
        self.assertEqual(error_metrics["matrixErrorCount"], 2)
        self.assertEqual(error_metrics["byEndpoint"]["overview"]["errorCount"], 1)

        legacy = benchmark.calculate_api_metrics(
            [{"latencySeconds": 0.25, "itemCount": 3}], [], 1
        )
        self.assertNotIn("byEndpoint", legacy)
        self.assertEqual(
            set(legacy),
            {
                "concurrency",
                "sampleCount",
                "errorCount",
                "p50Seconds",
                "p95Seconds",
                "maxSeconds",
                "minimumItems",
                "maximumItems",
            },
        )

    def test_capture_api_probe_rejects_malformed_endpoint_batch(self) -> None:
        context = benchmark.DockerContext(
            "advisor-live",
            "/srv/compose.yaml",
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )
        invalid_payloads = (
            [
                {
                    "endpoint": "overview",
                    "latencySeconds": 0.1,
                    "itemCount": None,
                }
            ],
            [
                {
                    "endpoint": "query-list",
                    "latencySeconds": 0.1,
                    "itemCount": 1,
                }
            ],
            [
                {
                    "endpoint": "query-list",
                    "latencySeconds": 0.1,
                    "itemCount": -1,
                }
            ],
        )
        for payload in invalid_payloads:
            runner = mock.Mock()
            runner.run.return_value = subprocess.CompletedProcess(
                ["docker"], 0, json.dumps(payload), ""
            )
            with self.subTest(payload=payload), self.assertRaises(
                benchmark.BenchmarkError
            ):
                benchmark.capture_api_probe(runner, context, 1)

        with self.assertRaisesRegex(benchmark.BenchmarkError, "hedefi eksik"):
            benchmark.capture_api_probe(
                mock.Mock(), context, 1, endpoint="query-detail"
            )

    def test_threshold_defaults_are_relative_and_portable(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            result = benchmark.load_thresholds(
                snapshot(), 5, duration_seconds=600, sample_seconds=5
            )
        self.assertEqual(result["maxSourceConnections"], 90)
        self.assertEqual(result["maxRepositoryConnections"], 90)
        self.assertEqual(result["maxCollectorLagSeconds"], 30.0)
        self.assertEqual(result["maxPgssOccupancyPercent"], 90.0)
        self.assertEqual(result["maxSourceAverageCpuCores"], 0.0)
        self.assertEqual(result["minPeakSamples"], 96)
        self.assertEqual(result["maxApiOverviewP95Seconds"], 8.0)
        self.assertEqual(result["maxApiDetailP95Seconds"], 2.0)
        self.assertEqual(result["minSourceFrequencySeconds"], 30)
        self.assertEqual(result["minCollectorSnapshots"], 96)
        self.assertEqual(result["maxCollectorSnapshots"], 181)
        self.assertEqual(result["maxRepositorySourceCpuRatio"], 0.0)
        self.assertEqual(result["maxMemoryPressureEventsDelta"], 0)
        self.assertTrue(result["requireCgroupMetrics"])
        self.assertTrue(result["requireCgroupMemoryEvents"])

    def test_invalid_environment_values_fail_before_workload(self) -> None:
        invalid = (
            {"ERP_MAX_SOURCE_CONNECTIONS": "-1"},
            {"ERP_MAX_COLLECTOR_LAG_SECONDS": "nan"},
            {"ERP_REQUIRE_CGROUP_METRICS": "sometimes"},
        )
        for values in invalid:
            with self.subTest(values=values), mock.patch.dict(
                os.environ, values, clear=True
            ), self.assertRaises(benchmark.BenchmarkError):
                benchmark.load_thresholds(snapshot(), 5)

    def test_source_frequency_preflight_rejects_before_expensive_work(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(
                benchmark.BenchmarkError, "current=5s, minimum=30s"
            ):
                benchmark.require_source_frequency(5)
            self.assertEqual(benchmark.require_source_frequency(60), 30)

        with mock.patch.dict(
            os.environ, {"ERP_MIN_SOURCE_FREQUENCY_SECONDS": "0"}, clear=True
        ):
            self.assertEqual(benchmark.require_source_frequency(5), 0)

    def test_baseline_must_be_healthy_and_backlog_free(self) -> None:
        clean = snapshot()
        benchmark.require_clean_baseline(clean)

        dirty = copy.deepcopy(clean)
        dirty["repository"]["postgres"]["collector"]["status"] = "DEGRADED"
        dirty["source"]["postgres"]["joinOutbox"]["batchCount"] = 2
        dirty["repository"]["postgres"]["joinTransport"]["stagingRows"] = 3
        with self.assertRaisesRegex(
            benchmark.BenchmarkError,
            "collector=.*joinOutbox=.*joinStagingRows",
        ):
                benchmark.require_clean_baseline(dirty)

    def test_cache_refresh_wait_requires_stable_repository_idle(self) -> None:
        context = benchmark.DockerContext(
            "advisor-live",
            "/srv/compose.yaml",
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )
        with mock.patch.object(
            benchmark, "psql", side_effect=["1", "0", "0"]
        ) as psql_mock, mock.patch.object(
            benchmark.time,
            "monotonic",
            side_effect=[0.0, 0.0, 0.5, 1.6],
        ), mock.patch.object(benchmark.time, "sleep"):
            benchmark.wait_for_repository_cache_refresh(
                mock.Mock(),
                context,
                timeout_seconds=5.0,
                idle_stability_seconds=1.0,
            )
        self.assertEqual(psql_mock.call_count, 3)
        activity_sql = psql_mock.call_args_list[0].args[3]
        self.assertIn("advisor-query-metrics-cache-refresh", activity_sql)
        self.assertIn("advisor-global-trend-cache-refresh", activity_sql)

    def test_cache_refresh_wait_rejects_invalid_activity_count(self) -> None:
        context = benchmark.DockerContext(
            "advisor-live",
            "/srv/compose.yaml",
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )
        with mock.patch.object(benchmark, "psql", return_value="not-a-count"):
            with self.assertRaisesRegex(benchmark.BenchmarkError, "sayaci gecersiz"):
                benchmark.wait_for_repository_cache_refresh(mock.Mock(), context)

    def test_cgroup_v2_line_parser_requires_monotonic_integers(self) -> None:
        self.assertEqual(
            benchmark.parse_cgroup("123|456|789|1000|2000|max|3|4|5|2\n"),
            {
                "cpuUsageUsec": 123,
                "ioReadBytes": 456,
                "ioWriteBytes": 789,
                "memoryCurrentBytes": 1000,
                "memoryLifetimePeakBytes": 2000,
                "memoryLimitBytes": None,
                "memoryLimitUnlimited": True,
                "memoryMaxEvents": 3,
                "memoryOomEvents": 4,
                "memoryOomKillEvents": 5,
                "cgroupVersion": 2,
            },
        )
        self.assertEqual(
            benchmark.parse_cgroup("|||||||||"),
            {
                "cpuUsageUsec": None,
                "ioReadBytes": None,
                "ioWriteBytes": None,
                "memoryCurrentBytes": None,
                "memoryLifetimePeakBytes": None,
                "memoryLimitBytes": None,
                "memoryLimitUnlimited": None,
                "memoryMaxEvents": None,
                "memoryOomEvents": None,
                "memoryOomKillEvents": None,
                "cgroupVersion": None,
            },
        )
        with self.assertRaises(benchmark.BenchmarkError):
            benchmark.parse_cgroup("12|oops|34|1|2|max|0|0|0|2")

    def test_cgroup_v1_unlimited_sentinel_is_normalized(self) -> None:
        result = benchmark.parse_cgroup(
            "1|2|3|4|5|9223372036854771712|6|||1"
        )
        self.assertIsNone(result["memoryLimitBytes"])
        self.assertTrue(result["memoryLimitUnlimited"])
        self.assertEqual(result["cgroupVersion"], 1)

    def test_resolve_context_inherits_running_compose_files(self) -> None:
        class ContextRunner:
            def __init__(self) -> None:
                self.calls: list[list[str]] = []

            def run(self, args, **_kwargs):
                command = list(args)
                self.calls.append(command)
                stdout = ""
                if command[:2] == ["docker", "ps"]:
                    filters = [
                        command[index + 1]
                        for index, item in enumerate(command[:-1])
                        if item == "--filter"
                    ]
                    service = next(
                        value.rsplit("=", 1)[1]
                        for value in filters
                        if value.startswith("label=com.docker.compose.service=")
                    )
                    if not any("project=" in value for value in filters):
                        stdout = "advisor-live\n"
                    else:
                        stdout = {
                            "source-db": "a" * 12,
                            "repository-db": "b" * 12,
                            "api": "c" * 12,
                            "join-snapshotter": "d" * 12,
                        }[service]
                elif command[:2] == ["docker", "inspect"]:
                    stdout = "/srv/compose.yaml,/srv/compose.fixed.yaml\n"
                elif "printenv" in command:
                    stdout = "30\n" if "JOIN_RETENTION_DAYS" in command else "erp-source\n"
                elif "psql" in command:
                    stdout = "7|5\n"
                return subprocess.CompletedProcess(command, 0, stdout, "")

        runner = ContextRunner()
        with mock.patch.dict(os.environ, {}, clear=True):
            context = benchmark.resolve_context(runner)
        self.assertEqual(context.project, "advisor-live")
        self.assertEqual(
            context.compose_file,
            os.pathsep.join(("/srv/compose.yaml", "/srv/compose.fixed.yaml")),
        )
        self.assertEqual(context.server_id, 7)

    def test_build_and_prepare_are_outside_measured_environment(self) -> None:
        class RecordingRunner:
            def __init__(self) -> None:
                self.calls: list[tuple[list[str], dict[str, str]]] = []

            def run(self, args, **kwargs):
                self.calls.append((list(args), dict(kwargs.get("env") or {})))
                return subprocess.CompletedProcess(list(args), 0, "", "")

        context = benchmark.DockerContext(
            "advisor-live",
            os.pathsep.join(("/srv/compose.yaml", "/srv/compose.fixed.yaml")),
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )
        runner = RecordingRunner()
        with mock.patch.dict(
            os.environ,
            {"REALISTIC_SKIP_BUILD": "false", "REALISTIC_SKIP_PREPARE": "true"},
            clear=True,
        ):
            workload_env = benchmark.prepare_benchmark_environment(
                runner, context, "erp", prepare_first=True
            )
        self.assertEqual(
            runner.calls[0][0],
            [
                "docker",
                "compose",
                "--profile",
                "realistic-load",
                "build",
                "workload",
            ],
        )
        self.assertEqual(
            runner.calls[1][0],
            ["bash", "scripts/prepare-realistic-workload.sh", "erp", "--yes"],
        )
        for _, call_env in runner.calls:
            self.assertEqual(call_env["COMPOSE_PROJECT_NAME"], "advisor-live")
            self.assertEqual(call_env["COMPOSE_FILE"], context.compose_file)
        self.assertEqual(workload_env["REALISTIC_SKIP_BUILD"], "true")
        self.assertEqual(workload_env["REALISTIC_SKIP_PREPARE"], "true")

        no_seed_runner = RecordingRunner()
        with mock.patch.dict(os.environ, {}, clear=True):
            no_seed_env = benchmark.prepare_benchmark_environment(
                no_seed_runner, context, "erp", prepare_first=False
            )
        self.assertEqual(len(no_seed_runner.calls), 1)
        self.assertEqual(no_seed_env["REALISTIC_SKIP_PREPARE"], "false")


class JoinBoundaryMatchingTests(unittest.TestCase):
    TELEMETRY_AT = dt.datetime(
        2026, 7, 26, 2, 36, 46, 795909, tzinfo=dt.timezone.utc
    )

    def test_same_snapshot_capture_120ms_later_is_selected(self) -> None:
        selection = join_boundary.select_boundary(
            self.TELEMETRY_AT,
            60,
            [
                join_boundary.JoinBatch(
                    6722,
                    dt.datetime(
                        2026, 7, 26, 2, 36, 46, 915609, tzinfo=dt.timezone.utc
                    ),
                ),
                join_boundary.JoinBatch(
                    6723,
                    dt.datetime(
                        2026, 7, 26, 2, 37, 46, 934346, tzinfo=dt.timezone.utc
                    ),
                ),
            ],
        )
        self.assertEqual(selection.status, "MATCH")
        self.assertIsNotNone(selection.batch)
        self.assertEqual(selection.batch.batch_id, 6722)
        self.assertAlmostEqual(selection.skew_seconds, 0.119700, places=6)
        self.assertEqual(selection.match_window_seconds, 9)

    def test_future_batch_is_not_used_when_matching_batch_is_missing(self) -> None:
        selection = join_boundary.select_boundary(
            self.TELEMETRY_AT,
            60,
            [
                join_boundary.JoinBatch(
                    6723,
                    self.TELEMETRY_AT + dt.timedelta(seconds=60.12),
                )
            ],
        )
        self.assertEqual(selection.status, "WAIT")
        self.assertIsNone(selection.batch)

    def test_multiple_batches_inside_match_window_are_ambiguous(self) -> None:
        selection = join_boundary.select_boundary(
            self.TELEMETRY_AT,
            60,
            [
                join_boundary.JoinBatch(
                    6722, self.TELEMETRY_AT + dt.timedelta(milliseconds=120)
                ),
                join_boundary.JoinBatch(
                    6723, self.TELEMETRY_AT + dt.timedelta(seconds=2)
                ),
            ],
        )
        self.assertEqual(selection.status, "AMBIGUOUS")
        self.assertIsNone(selection.batch)

    def test_verifier_uses_exact_batch_id_for_join_upper_bounds(self) -> None:
        verifier = (
            benchmark.ROOT / "scripts/verify-realistic-workload.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("scripts/realistic_join_boundary.py", verifier)
        self.assertIn(
            "evidence_batch.batch_id <= bounds.join_finished_batch_id", verifier
        )
        self.assertGreaterEqual(
            verifier.count("batch_id <= ${join_finished_batch_id}"), 2
        )


class BoundaryHandshakeTests(unittest.TestCase):
    def test_start_and_end_boundaries_are_atomic_and_block_until_continue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sync_directory = Path(directory).resolve()
            for phase in benchmark.SYNC_PHASES:
                failures: list[BaseException] = []

                def wrapper_boundary() -> None:
                    try:
                        benchmark.workload_boundary_handshake(
                            sync_directory, phase, 2.0
                        )
                    except BaseException as exc:
                        failures.append(exc)

                worker = threading.Thread(target=wrapper_boundary)
                worker.start()
                ready_path = benchmark.sync_path(sync_directory, phase, "ready")
                ready = benchmark.wait_for_sync_payload(
                    ready_path, timeout_seconds=1.0
                )
                benchmark.validate_phase_payload(ready, phase, "ready")
                self.assertTrue(worker.is_alive())
                self.assertEqual(
                    stat.S_IMODE(ready_path.stat().st_mode),
                    0o600,
                )
                benchmark.publish_phase_response(sync_directory, phase)
                worker.join(timeout=1.0)
                self.assertFalse(worker.is_alive())
                self.assertEqual(failures, [])

    def test_abort_response_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sync_directory = Path(directory).resolve()
            failures: list[BaseException] = []

            def wrapper_boundary() -> None:
                try:
                    benchmark.workload_boundary_handshake(
                        sync_directory, "start", 2.0
                    )
                except BaseException as exc:
                    failures.append(exc)

            worker = threading.Thread(target=wrapper_boundary)
            worker.start()
            benchmark.wait_for_sync_payload(
                benchmark.sync_path(sync_directory, "start", "ready"),
                timeout_seconds=1.0,
            )
            benchmark.publish_phase_response(
                sync_directory, "start", status_value="abort"
            )
            worker.join(timeout=1.0)
            self.assertFalse(worker.is_alive())
            self.assertEqual(len(failures), 1)
            self.assertIsInstance(failures[0], benchmark.BenchmarkError)

    def test_sync_directory_must_be_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sync_directory = Path(directory).resolve()
            sync_directory.chmod(0o755)
            try:
                with self.assertRaises(benchmark.BenchmarkError):
                    benchmark.validate_sync_directory(sync_directory)
            finally:
                sync_directory.chmod(0o700)

    def test_shell_boundaries_bracket_only_generator_pipeline(self) -> None:
        wrapper = (benchmark.ROOT / "scripts/run-realistic-workload.sh").read_text(
            encoding="utf-8"
        )
        start = wrapper.index("benchmark_boundary start")
        pipeline = wrapper.index("docker compose --profile realistic-load run")
        status_capture = wrapper.index("workload_pipeline_status=$?")
        end = wrapper.index("benchmark_boundary end")
        preserved_exit = wrapper.index('exit "$workload_pipeline_status"')
        postlude = wrapper.index("run_end_state=")
        self.assertLess(start, pipeline)
        self.assertLess(pipeline, status_capture)
        self.assertLess(status_capture, end)
        self.assertLess(end, preserved_exit)
        self.assertLess(end, postlude)

    def test_benchmark_measures_generator_only_then_waits_for_wrapper_exit(self) -> None:
        timeline: list[str] = []
        captured_reports: list[dict[str, object]] = []

        class FakeProcess:
            def __init__(self) -> None:
                self.returncode: int | None = None
                self.finished = threading.Event()
                self.pid = os.getpid()

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                if not self.finished.wait(timeout):
                    raise subprocess.TimeoutExpired("fake-wrapper", timeout)
                return self.returncode

        class AsyncRunner:
            def start(self, _args, **kwargs):
                process = FakeProcess()
                sync_directory = Path(
                    kwargs["env"]["REALISTIC_BENCHMARK_SYNC_DIR"]
                )

                def wrapper() -> None:
                    benchmark.workload_boundary_handshake(
                        sync_directory, "start", 2.0
                    )
                    timeline.append("generator-start")
                    timeline.append("generator-end")
                    benchmark.workload_boundary_handshake(
                        sync_directory, "end", 2.0
                    )
                    timeline.append("postlude")
                    process.returncode = 7
                    process.finished.set()

                threading.Thread(target=wrapper, daemon=True).start()
                return process

        context = benchmark.DockerContext(
            "advisor-live",
            "/srv/compose.yaml",
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )
        snapshots = iter((snapshot(), snapshot(after=True)))

        def capture_snapshot(_runner, _context, **_kwargs):
            value = next(snapshots)
            timeline.append("before" if len(timeline) == 0 else "after")
            callback = _kwargs.get("boundary_callback")
            if callback is not None:
                callback()
            return value

        def write_report(report, _directory, _profile):
            captured_reports.append(dict(report))
            return Path("/tmp/fake-report.json")

        args = mock.Mock(profile="quick", duration=30, workers=3)
        with tempfile.TemporaryDirectory() as report_directory, mock.patch.dict(
            os.environ,
            {
                "ERP_BENCHMARK_REPORT_DIR": report_directory,
                "ERP_MIN_PEAK_SAMPLES": "1",
            },
            clear=True,
        ), mock.patch.object(
            benchmark, "resolve_context", return_value=context
        ), mock.patch.object(
            benchmark,
            "prepare_benchmark_environment",
            return_value={},
        ), mock.patch.object(
            benchmark,
            "capture_api_probe",
            return_value=[{"latencySeconds": 0.01, "itemCount": 1}],
        ), mock.patch.object(
            benchmark, "capture_sample", return_value={}
        ), mock.patch.object(
            benchmark, "wait_for_repository_cache_refresh"
        ) as cache_wait, mock.patch.object(
            benchmark, "capture_snapshot", side_effect=capture_snapshot
        ), mock.patch.object(
            benchmark, "write_report", side_effect=write_report
        ), mock.patch.object(
            benchmark, "print_summary"
        ):
            exit_code = benchmark.run_benchmark(args, AsyncRunner())

        self.assertEqual(exit_code, 7)
        self.assertEqual(cache_wait.call_count, 2)
        self.assertLess(timeline.index("before"), timeline.index("generator-start"))
        self.assertLess(timeline.index("generator-end"), timeline.index("after"))
        self.assertLess(timeline.index("after"), timeline.index("postlude"))
        self.assertEqual(captured_reports[0]["workloadExitCode"], 7)
        self.assertEqual(captured_reports[0]["schemaVersion"], 4)
        self.assertIn("derivedMetrics", captured_reports[0])
        self.assertEqual(
            captured_reports[0]["derivedMetrics"]["powaMaintenance"][
                "classification"
            ],
            "UNKNOWN",
        )
        self.assertFalse(
            captured_reports[0]["derivedMetrics"]["powaMaintenance"][
                "steadyStateEligible"
            ]
        )
        self.assertEqual(
            captured_reports[0]["api"]["probePlan"]["rotation"],
            ["query-list", "overview", "query-detail"],
        )
        self.assertEqual(
            captured_reports[0]["api"]["probePlan"]["window"], "24h"
        )
        self.assertEqual(
            captured_reports[0]["api"]["probePlan"]["concurrencyByEndpoint"],
            {"query-list": 2, "overview": 1, "query-detail": 2},
        )
        self.assertIn(
            "not isolated observer overhead",
            captured_reports[0]["measurementScope"]["sourceContainer"],
        )
        self.assertEqual(
            captured_reports[0]["measurementBoundary"]["protocolVersion"],
            benchmark.SYNC_PROTOCOL_VERSION,
        )


class ReportTests(unittest.TestCase):
    def test_report_is_written_as_valid_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = benchmark.write_report(
                {"schemaVersion": 1, "status": "PASSED"},
                Path(directory),
                "quick",
            )
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["status"], "PASSED")
            self.assertTrue(path.name.endswith("-quick-erp-stack.json"))

    def test_metric_sql_is_read_only(self) -> None:
        combined = benchmark.SOURCE_SQL + benchmark.repository_sql(17, 30)
        upper = combined.upper()
        for forbidden in ("DELETE ", "UPDATE ", "INSERT ", "TRUNCATE ", "PG_STAT_RESET"):
            self.assertNotIn(forbidden, upper)
        self.assertIn("pg_stat_io", combined)
        self.assertIn("powa_snapshot_metas", combined)
        self.assertIn("powa_coalesce", combined)
        self.assertIn("pg_stat_statements_info", combined)
        self.assertIn("observerOwnedSql", benchmark.SOURCE_SQL)
        self.assertIn("pg_stat_kcache()", benchmark.SOURCE_SQL)
        self.assertIn("advisor_join_reader", benchmark.SOURCE_SQL)
        self.assertIn("stats_since", benchmark.SOURCE_SQL)
        self.assertIn("minmax_stats_since", benchmark.SOURCE_SQL)
        self.assertIn("advisor_join.outbox_batches", combined)
        self.assertIn("join_snapshot_batches", combined)

    def test_snapshot_cgroup_boundaries_exclude_metric_sql(self) -> None:
        context = benchmark.DockerContext(
            "advisor-live",
            "/srv/compose.yaml",
            "a" * 12,
            "b" * 12,
            "c" * 12,
            "d" * 12,
            "erp-source",
            7,
            60,
            30,
        )
        events: list[str] = []

        def fake_cgroup(*_args, **_kwargs):
            events.append("cgroup")
            return {}

        def fake_psql(*_args, **_kwargs):
            events.append("postgres")
            return {}

        with mock.patch.object(
            benchmark, "cgroup_metrics", side_effect=fake_cgroup
        ), mock.patch.object(benchmark, "psql", side_effect=fake_psql):
            before = benchmark.capture_snapshot(
                mock.Mock(), context, container_boundary="last"
            )
            self.assertEqual(
                events, ["postgres", "postgres", "cgroup", "cgroup"]
            )
            events.clear()
            after = benchmark.capture_snapshot(
                mock.Mock(), context, container_boundary="first"
            )
            self.assertEqual(
                events, ["cgroup", "cgroup", "postgres", "postgres"]
            )
        self.assertEqual(before["containerBoundary"], "last")
        self.assertEqual(after["containerBoundary"], "first")

    def test_cgroup_probe_includes_memory_pressure_and_oom_counters(self) -> None:
        self.assertIn("memory.current", benchmark.CGROUP_SCRIPT)
        self.assertIn("memory.peak", benchmark.CGROUP_SCRIPT)
        self.assertIn("memory.max", benchmark.CGROUP_SCRIPT)
        self.assertIn('memory_oom_events="$(awk', benchmark.CGROUP_SCRIPT)
        self.assertIn('memory_oom_kill_events="$(awk', benchmark.CGROUP_SCRIPT)

    def test_erp_is_the_default_capacity_profile(self) -> None:
        args = benchmark.build_parser().parse_args(["run"])
        self.assertEqual(args.profile, "erp")
        self.assertEqual(benchmark.DEFAULTS["erp"], (600, 32))


if __name__ == "__main__":
    unittest.main()
