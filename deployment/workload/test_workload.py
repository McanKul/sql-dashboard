from __future__ import annotations

import math
import random
import re
import threading
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

import workload


SEED_SQL = Path(__file__).with_name("seed.sql").read_text(encoding="utf-8")


def config_env(**overrides: str) -> dict[str, str]:
    values = {
        "DATABASE_URL": "postgresql://postgres:test@source-db:5432/appdb",
        "PGPASSWORD": "unit-test-workload-password",
        "WORKLOAD_PROFILE": "normal",
    }
    values.update(overrides)
    return values


def test_config(**overrides: str) -> workload.WorkloadConfig:
    return workload.WorkloadConfig.from_env(config_env(**overrides))


BOUNDS = workload.DataBounds(
    max_customer_id=1_200,
    max_order_id=18_000,
    max_event_id=26_000,
    max_tenant_id=32,
    max_product_id=2_000,
    max_warehouse_id=8,
    max_hotspot_id=64,
)


class FakeCursor:
    def __init__(self, fetchone_result: tuple[int, ...] | None = (101,)) -> None:
        self.calls: list[tuple[object, object | None]] = []
        self.fetchone_result = fetchone_result

    def execute(self, statement: object, parameters: object | None = None) -> None:
        self.calls.append((statement, parameters))

    def fetchone(self) -> tuple[int, ...] | None:
        return self.fetchone_result

    def fetchall(self) -> list[tuple[object, ...]]:
        return []


class SqlTemplateTests(unittest.TestCase):
    def test_templates_are_static_tagged_unique_and_bounded(self) -> None:
        self.assertLessEqual(
            len(workload.SQL_TEMPLATES), workload.MAX_SQL_TEMPLATES
        )
        tags: list[str] = []
        for expected, statement in workload.SQL_TEMPLATES.items():
            found = workload.TAG_PATTERN.findall(statement)
            if expected == "join-orders-status":
                self.assertEqual(found, [])
                continue
            self.assertEqual(found, [expected], expected)
            tags.extend(found)
        self.assertEqual(len(tags), len(set(tags)))

    def test_exact_composite_join_shape_is_preserved(self) -> None:
        self.assertTrue(
            workload.JOIN_ORDERS_STATUS_SQL.startswith(
                "SELECT count(*) FROM public.customers AS c "
                "JOIN public.orders AS o ON o.customer_id = c.id "
                "WHERE o.status = %s"
            )
        )
        self.assertEqual(
            workload.JOIN_ORDERS_STATUS_SQL,
            workload.EXACT_JOIN_STATUS_PREFIX,
        )
        matching_roles = {
            operation.role
            for operation in workload.OPERATIONS
            if "join-orders-status" in operation.fingerprints
        }
        self.assertEqual(
            matching_roles,
            {workload.READER_ROLE, workload.REPORTER_ROLE},
        )

    def test_operation_names_are_unique_and_all_roles_have_a_mix(self) -> None:
        names = [operation.name for operation in workload.OPERATIONS]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(workload.OPERATIONS_BY_ROLE), set(workload.WORKLOAD_ROLES))
        for role, operations in workload.OPERATIONS_BY_ROLE.items():
            self.assertTrue(operations, role)
            for profile in workload.PROFILE_DEFAULTS:
                enabled = profile == "erp"
                base_operations = [op for op in operations if op.category != "erp"]
                self.assertTrue(
                    all(
                        op.weight(profile, erp_enabled=enabled) > 0
                        for op in base_operations
                    )
                )


class ConfigTests(unittest.TestCase):
    def test_profile_defaults_are_finite_and_stress_is_larger(self) -> None:
        normal = test_config()
        quick = workload.WorkloadConfig.from_env(
            config_env(WORKLOAD_PROFILE="quick")
        )
        stress = workload.WorkloadConfig.from_env(
            config_env(WORKLOAD_PROFILE="stress")
        )
        erp = workload.WorkloadConfig.from_env(config_env(WORKLOAD_PROFILE="erp"))
        self.assertLess(quick.duration_seconds, normal.duration_seconds)
        self.assertGreater(normal.duration_seconds, 0)
        self.assertGreater(stress.duration_seconds, 0)
        self.assertGreater(stress.workers, normal.workers)
        self.assertLessEqual(stress.interval_seconds, normal.interval_seconds)
        self.assertEqual(quick.erp_table_count, 0)
        self.assertEqual(normal.erp_table_count, 0)
        self.assertEqual(stress.erp_table_count, 0)
        self.assertEqual(erp.erp_table_count, 500)
        self.assertEqual(erp.erp_rows_per_table, 2_000)
        self.assertEqual(workload.erp_fingerprint_target(erp), 4_000)

    def test_documented_environment_overrides_are_applied(self) -> None:
        config = test_config(
            WORKLOAD_DURATION_SECONDS="60",
            WORKLOAD_WORKERS="12",
            WORKLOAD_INTERVAL_SECONDS="0.125",
            WORKLOAD_REPORT_INTERVAL_SECONDS="4",
            WORKLOAD_RANDOM_SEED="42",
            WORKLOAD_STATEMENT_TIMEOUT_MS="7000",
            WORKLOAD_LOCK_TIMEOUT_MS="900",
            WORKLOAD_LOCK_HOLD_MS="30",
        )
        self.assertEqual(config.duration_seconds, 60)
        self.assertEqual(config.workers, 12)
        self.assertEqual(config.interval_seconds, 0.125)
        self.assertEqual(config.report_interval_seconds, 4)
        self.assertEqual(config.random_seed, 42)
        self.assertEqual(config.statement_timeout_ms, 7000)
        self.assertEqual(config.lock_timeout_ms, 900)
        self.assertEqual(config.lock_hold_ms, 30)
        self.assertEqual(config.erp_table_count, 0)

    def test_invalid_configuration_fails_closed(self) -> None:
        invalid_values = (
            {"WORKLOAD_PROFILE": "turbo"},
            {"WORKLOAD_WORKERS": "2"},
            {"WORKLOAD_DURATION_SECONDS": "-1"},
            {"WORKLOAD_INTERVAL_SECONDS": "nan"},
            {"WORKLOAD_ERP_TABLE_COUNT": "501"},
            {"WORKLOAD_ERP_QUERY_VARIANTS_PER_TABLE": "9"},
            {"WORKLOAD_ERP_ROWS_PER_TABLE": "5001"},
            {"WORKLOAD_PROFILE": "erp", "WORKLOAD_DURATION_SECONDS": "0"},
            {"WORKLOAD_PROFILE": "erp", "WORKLOAD_ERP_TABLE_COUNT": "499"},
            {"WORKLOAD_PROFILE": "erp", "WORKLOAD_ERP_ROWS_PER_TABLE": "1999"},
            {"WORKLOAD_PROFILE": "normal", "WORKLOAD_ERP_TABLE_COUNT": "1"},
            {
                "WORKLOAD_PROFILE": "erp",
                "WORKLOAD_ERP_QUERY_VARIANTS_PER_TABLE": "4",
            },
            {
                "WORKLOAD_PROFILE": "erp",
                "WORKLOAD_ERP_QUERY_VARIANTS_PER_TABLE": "7",
            },
            {"PGPASSWORD": ""},
            {"PGPASSWORD": "advisor_dev_workload"},
            {"PGPASSWORD": "change-me-workload"},
            {
                "WORKLOAD_STATEMENT_TIMEOUT_MS": "1000",
                "WORKLOAD_LOCK_HOLD_MS": "1000",
            },
        )
        for invalid in invalid_values:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                workload.WorkloadConfig.from_env(config_env(**invalid))

    def test_zero_duration_is_explicit_indefinite_mode(self) -> None:
        config = test_config(WORKLOAD_DURATION_SECONDS="0")
        self.assertEqual(config.duration_seconds, 0)
        payload = workload._heartbeat_payload(
            config,
            workload.WorkloadMetrics(seed=1),
            elapsed_seconds=12.5,
            remaining_seconds=float("inf"),
        )
        self.assertIsNone(payload["remainingSeconds"])


class SeedSecurityTests(unittest.TestCase):
    def test_password_sql_is_guarded_from_server_logging(self) -> None:
        first_secret_sql = SEED_SQL.index("SELECT length(:'workload_db_password')")
        self.assertLess(SEED_SQL.index("SET log_statement = 'none'"), first_secret_sql)
        self.assertLess(
            SEED_SQL.index("SET log_min_error_statement = 'panic'"),
            first_secret_sql,
        )
        self.assertLess(
            SEED_SQL.index("SET log_parameter_max_length_on_error = 0"),
            first_secret_sql,
        )
        self.assertIn("<> 'advisor_dev_workload'", SEED_SQL)
        self.assertIn("NOT LIKE 'change-me-%'", SEED_SQL)
        self.assertIn("VALID UNTIL ''infinity''", SEED_SQL)

    def test_erp_seed_is_bounded_idempotent_and_packaged(self) -> None:
        self.assertIn("target_erp_tables must be between 0 and 500", SEED_SQL)
        self.assertIn("erp_rows_per_table must be between 1 and 5000", SEED_SQL)
        self.assertIn("ERP profile requires exactly 2000 rows per table", SEED_SQL)
        self.assertIn("ERP tables require the explicit ERP seed profile", SEED_SQL)
        self.assertIn("FOR v_erp_table_number IN 1..v_target_erp_tables", SEED_SQL)
        self.assertIn("CREATE TABLE IF NOT EXISTS %I.%I", SEED_SQL)
        self.assertIn("ON CONFLICT (id) DO NOTHING", SEED_SQL)
        self.assertIn("IF mod(v_erp_table_number, 25) = 0", SEED_SQL)
        self.assertIn("expected exactly %", SEED_SQL)
        self.assertIn("NOT index_record.indisvalid", SEED_SQL)
        self.assertIn("NOT index_record.indisready", SEED_SQL)
        self.assertIn("NOT index_record.indislive", SEED_SQL)
        self.assertIn("index_record.indoption::text <> '0 0 3'", SEED_SQL)
        self.assertIn("pg_get_indexdef(index_record.indexrelid, 3, true)", SEED_SQL)
        self.assertIn("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA advisor_erp", SEED_SQL)

    def test_event_retention_has_a_validated_partial_cleanup_index(self) -> None:
        self.assertIn("idx_events_advisor_realistic_id_desc", SEED_SQL)
        self.assertIn("ON events (id DESC)", SEED_SQL)
        self.assertIn(
            "WHERE metadata ->> 'source' = 'advisor-realistic'", SEED_SQL
        )
        self.assertIn("index_record.indoption::text <> '3'", SEED_SQL)
        self.assertIn("pg_get_expr(index_record.indpred", SEED_SQL)


class ErpScaleTests(unittest.TestCase):
    def test_default_erp_profile_has_four_thousand_bounded_fingerprints(self) -> None:
        config = workload.WorkloadConfig.from_env(
            config_env(WORKLOAD_PROFILE="erp")
        )
        self.assertEqual(config.erp_table_count, workload.MAX_ERP_TABLES)
        self.assertEqual(len(workload.ERP_QUERY_FAMILIES), 8)
        self.assertEqual(workload.erp_fingerprint_target(config), 4_000)

    def test_every_erp_family_uses_allowlisted_quoted_relations_and_read_only_sql(self) -> None:
        rendered: set[str] = set()
        for variant in range(len(workload.ERP_QUERY_FAMILIES)):
            statement = workload.build_erp_query(17, variant, 500).as_string()
            self.assertIn('"advisor_erp"."erp_entity_0017"', statement)
            self.assertNotRegex(
                statement.upper(),
                r"\b(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE)\b",
            )
            rendered.add(statement)
        self.assertEqual(len(rendered), len(workload.ERP_QUERY_FAMILIES))

        join_statement = workload.build_erp_query(500, 6, 500).as_string()
        self.assertIn("WITH left_scope AS", join_statement)
        self.assertIn('"advisor_erp"."erp_entity_0001"', join_statement)

    def test_erp_identifiers_and_variants_fail_closed(self) -> None:
        for args in ((0, 0, 500), (501, 0, 500), (1, 8, 500), (2, 0, 1)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                workload.build_erp_query(*args)

    def test_deterministic_scheduler_visits_each_fingerprint_before_wrap(self) -> None:
        metrics = workload.WorkloadMetrics(seed=1)
        target = 2_500
        ordinals = [metrics.reserve_erp_fingerprint(target) for _ in range(target)]
        self.assertEqual(ordinals, list(range(target)))
        self.assertEqual(metrics.reserve_erp_fingerprint(target), 0)
        for ordinal in ordinals:
            metrics.record_erp_fingerprint(ordinal)
        self.assertEqual(metrics.erp_coverage(target), (target, 100.0))

    def test_erp_operation_executes_the_reserved_relation_and_family(self) -> None:
        cursor = FakeCursor()
        config = workload.WorkloadConfig.from_env(
            config_env(WORKLOAD_PROFILE="erp")
        )
        ordinal = 16 * config.erp_query_variants_per_table + 6
        returned = workload.execute_erp_query(
            cursor, random.Random(7), config, BOUNDS, 3, ordinal
        )
        self.assertEqual(returned, ordinal)
        statement = cursor.calls[0][0].as_string()
        self.assertIn('"advisor_erp"."erp_entity_0017"', statement)
        self.assertIn('"advisor_erp"."erp_entity_0018"', statement)
        self.assertIn("JOIN", statement)

class RoleAndRandomnessTests(unittest.TestCase):
    def test_role_allocation_is_reproducible_and_covers_every_role(self) -> None:
        first = workload.allocate_worker_roles(12, "stress", 123)
        second = workload.allocate_worker_roles(12, "stress", 123)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 12)
        self.assertEqual(set(first), set(workload.WORKLOAD_ROLES))

    def test_each_worker_gets_a_distinct_reproducible_seed(self) -> None:
        seeds = [workload.worker_seed(55, worker_id) for worker_id in range(1, 10)]
        self.assertEqual(len(seeds), len(set(seeds)))
        self.assertEqual(seeds, [workload.worker_seed(55, i) for i in range(1, 10)])

    def test_weighted_operation_selection_never_crosses_role(self) -> None:
        rng = random.Random(10)
        for role in workload.WORKLOAD_ROLES:
            selected = {
                workload.choose_operation(role, "stress", rng).role
                for _ in range(100)
            }
            self.assertEqual(selected, {role})


class OperationTests(unittest.TestCase):
    def test_mutation_write_uses_bounded_cleanup(self) -> None:
        cursor = FakeCursor()
        config = test_config(
            WORKLOAD_MAX_MUTATION_ROWS="4321",
            WORKLOAD_MUTATION_CLEANUP_BATCH="123",
        )
        workload.execute_write_mutation(
            cursor, random.Random(1), config, BOUNDS, worker_id=7
        )
        self.assertEqual(len(cursor.calls), 4)
        self.assertIs(cursor.calls[0][0], workload.RETENTION_LOCK_SQL)
        self.assertEqual(cursor.calls[0][1], (20_260_725, 1))
        self.assertEqual(cursor.calls[-1][1], (4321, 123))
        self.assertIn("advisor-realistic", str(cursor.calls[1][0]))

    def test_controlled_lock_targets_only_the_hot_set_and_holds_briefly(self) -> None:
        cursor = FakeCursor()
        config = test_config(WORKLOAD_LOCK_HOLD_MS="40")
        workload.execute_controlled_lock(
            cursor, random.Random(9), config, BOUNDS, 1
        )
        parameters = cursor.calls[0][1]
        self.assertIsInstance(parameters, tuple)
        hotspot_id, hold_seconds = parameters
        self.assertEqual(hotspot_id, 1)
        self.assertGreaterEqual(hold_seconds, 0.03)
        self.assertLessEqual(hold_seconds, 0.05)

    def test_inventory_updates_are_confined_to_seeded_hot_keys(self) -> None:
        cursor = FakeCursor()
        workload.execute_update_inventory(
            cursor, random.Random(3), test_config(), BOUNDS, 1
        )
        (row_offset,) = cursor.calls[0][1]
        self.assertIn(row_offset, range(0, 256))
        self.assertIn("FOR UPDATE SKIP LOCKED", workload.UPDATE_INVENTORY_SQL)
        self.assertIn("%%", workload.UPDATE_INVENTORY_SQL)

    def test_sparse_identity_reads_and_event_fk_resolve_existing_rows(self) -> None:
        self.assertIn("WHERE id >= %s", workload.READ_ORDER_BY_ID_SQL)
        self.assertIn("FROM public.customers", workload.READ_CUSTOMER_ORDERS_SQL)
        self.assertIn(
            "SELECT id FROM public.customers WHERE id >= %s",
            workload.WRITE_EVENT_INSERT_SQL,
        )

    def test_event_write_cleanup_globally_caps_only_tagged_rows(self) -> None:
        cursor = FakeCursor()
        config = test_config(
            WORKLOAD_MAX_EVENT_ROWS="800",
            WORKLOAD_EVENT_CLEANUP_BATCH="75",
        )
        workload.execute_write_event(
            cursor, random.Random(4), config, BOUNDS, 2
        )
        self.assertEqual(len(cursor.calls), 3)
        self.assertIs(cursor.calls[0][0], workload.RETENTION_LOCK_SQL)
        self.assertEqual(cursor.calls[0][1], (20_260_725, 2))
        self.assertEqual(cursor.calls[-1][1], (800, 75))
        self.assertNotIn("id >", workload.WRITE_EVENT_CLEANUP_SQL)
        self.assertIn(
            "metadata ->> 'source' = 'advisor-realistic'",
            workload.WRITE_EVENT_CLEANUP_SQL,
        )
        self.assertIn("%s::text", workload.WRITE_EVENT_INSERT_SQL)
        self.assertIn("%s::bigint", workload.WRITE_EVENT_INSERT_SQL)

    def test_order_and_job_lifecycle_use_skip_locked_templates(self) -> None:
        self.assertIn("FOR UPDATE SKIP LOCKED", workload.UPDATE_ORDER_LIFECYCLE_SQL)
        self.assertIn("FOR UPDATE SKIP LOCKED", workload.CLAIM_JOB_SQL)


class MetricsTests(unittest.TestCase):
    def test_erp_run_fails_closed_when_fingerprint_sweep_is_incomplete(self) -> None:
        emitted: list[dict[str, object]] = []
        config = workload.WorkloadConfig.from_env(
            config_env(WORKLOAD_PROFILE="erp")
        )

        def successful_worker(
            _worker_id: int,
            role: str,
            _config: workload.WorkloadConfig,
            _bounds: workload.DataBounds,
            metrics: workload.WorkloadMetrics,
            _stop_event: threading.Event,
            _deadline: float,
        ) -> None:
            operation = next(
                item
                for item in workload.OPERATIONS_BY_ROLE[role]
                if item.category != "erp"
            )
            metrics.record_operation(operation, 1.0, True)

        with (
            mock.patch.object(workload, "preflight", return_value=BOUNDS),
            mock.patch.object(workload, "capture_database_stats", return_value={}),
            mock.patch.object(workload, "run_worker", side_effect=successful_worker),
            mock.patch.object(workload, "_emit", side_effect=emitted.append),
        ):
            final, exit_code = workload.run(config)

        self.assertEqual(exit_code, 1)
        self.assertEqual(final["status"], "failed")
        self.assertEqual(
            final["failureReason"], "erp-fingerprint-coverage-incomplete"
        )
        self.assertEqual(final["erpFingerprintTarget"], 4_000)
        self.assertEqual(final["erpVisitedFingerprintCount"], 0)

    def test_operation_disconnect_is_counted_as_connection_error(self) -> None:
        stop_event = threading.Event()

        class DisconnectCursor:
            def __init__(self, connection: "DisconnectConnection") -> None:
                self.connection = connection

            def __enter__(self) -> "DisconnectCursor":
                return self

            def __exit__(self, *_args: object) -> None:
                return None

            def execute(self, _statement: object, _parameters: object = None) -> None:
                self.connection.execute_count += 1
                if self.connection.execute_count >= 3:
                    self.connection.broken = True
                    raise workload.psycopg.OperationalError("connection lost")

            def fetchone(self) -> tuple[None]:
                return (None,)

        class DisconnectConnection:
            closed = False
            broken = False

            def __init__(self) -> None:
                self.execute_count = 0

            def __enter__(self) -> "DisconnectConnection":
                return self

            def __exit__(self, *_args: object) -> None:
                stop_event.set()
                return None

            def cursor(self) -> DisconnectCursor:
                return DisconnectCursor(self)

            def commit(self) -> None:
                return None

            def rollback(self) -> None:
                return None

        metrics = workload.WorkloadMetrics(seed=1)
        operation = next(
            item for item in workload.OPERATIONS if item.name == "read-order-by-id"
        )
        config = test_config(WORKLOAD_INTERVAL_SECONDS="0")
        with (
            mock.patch.object(
                workload.psycopg, "connect", return_value=DisconnectConnection()
            ),
            mock.patch.object(workload, "choose_operation", return_value=operation),
        ):
            workload.run_worker(
                1,
                workload.READER_ROLE,
                config,
                BOUNDS,
                metrics,
                stop_event,
                time.monotonic() + 1,
            )

        totals = metrics.snapshot(elapsed_seconds=1)["totals"]
        self.assertEqual(totals["failed"], 1)
        self.assertEqual(totals["connectionErrors"], 1)

    def test_timeout_operational_errors_are_not_connection_failures(self) -> None:
        connection = mock.Mock(closed=False, broken=False)
        for error in (
            workload.psycopg.errors.QueryCanceled("statement timeout"),
            workload.psycopg.errors.LockNotAvailable("lock timeout"),
            workload.psycopg.errors.SerializationFailure("retry transaction"),
            workload.psycopg.errors.DeadlockDetected("deadlock"),
        ):
            with self.subTest(sqlstate=error.sqlstate):
                self.assertFalse(workload._is_connection_failure(error, connection))

        connection_error = workload.psycopg.errors.ConnectionFailure("lost")
        self.assertTrue(
            workload._is_connection_failure(connection_error, connection)
        )

    def test_start_and_final_use_utc_timestamps_without_changing_heartbeat(self) -> None:
        emitted: list[dict[str, object]] = []
        config = test_config()

        with (
            mock.patch.object(workload, "preflight", return_value=BOUNDS),
            mock.patch.object(workload, "capture_database_stats", return_value={}),
            mock.patch.object(workload, "run_worker", return_value=None),
            mock.patch.object(workload, "_emit", side_effect=emitted.append),
        ):
            final, _exit_code = workload.run(config)

        self.assertEqual(emitted[0]["type"], "advisor-realistic-start")
        self.assertEqual(emitted[-1], final)
        self.assertEqual(final["startedAt"], emitted[0]["startedAt"])

        timestamp_pattern = re.compile(
            r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"
        )
        parsed_timestamps: list[datetime] = []
        for field, payload in (
            ("startedAt", emitted[0]),
            ("startedAt", final),
            ("finishedAt", final),
        ):
            timestamp = payload[field]
            self.assertIsInstance(timestamp, str)
            self.assertRegex(timestamp, timestamp_pattern)
            parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            self.assertEqual(parsed.utcoffset(), timedelta(0))
            parsed_timestamps.append(parsed)
        self.assertLessEqual(parsed_timestamps[1], parsed_timestamps[2])

        heartbeat = workload._heartbeat_payload(
            config,
            workload.WorkloadMetrics(seed=2),
            elapsed_seconds=1.5,
            remaining_seconds=2.5,
        )
        self.assertEqual(
            set(heartbeat),
            {
                "type",
                "profile",
                "elapsedSeconds",
                "remainingSeconds",
                "totals",
                "categories",
            },
        )

        failed_emissions: list[dict[str, object]] = []
        with (
            mock.patch.object(
                workload.WorkloadConfig,
                "from_env",
                side_effect=ValueError("bad config"),
            ),
            mock.patch.object(workload, "_emit", side_effect=failed_emissions.append),
        ):
            self.assertEqual(workload.main(), 1)
        self.assertIn("startedAt", failed_emissions[0])
        self.assertRegex(failed_emissions[0]["finishedAt"], timestamp_pattern)

    def test_reservoir_is_bounded_and_summary_has_stable_contract(self) -> None:
        metrics = workload.WorkloadMetrics(seed=99)
        operation = workload.OPERATIONS[0]
        for value in range(workload.MAX_LATENCY_SAMPLES + 500):
            metrics.record_operation(operation, float(value + 1), True)
        metrics.record_operation(operation, 3.0, False, "57014")

        snapshot = metrics.snapshot(elapsed_seconds=10)
        totals = snapshot["totals"]
        operation_payload = snapshot["operations"][operation.name]
        self.assertEqual(totals["failed"], 1)
        self.assertTrue(
            math.isclose(
                totals["errorRate"],
                totals["failed"] / totals["attempted"],
                rel_tol=1e-6,
                abs_tol=1e-9,
            )
        )
        self.assertGreater(totals["transactionsPerSecond"], 0)
        self.assertEqual(totals["errorsBySqlstate"], {"57014": 1})
        self.assertLessEqual(
            operation_payload["latencySampleCount"],
            workload.MAX_LATENCY_SAMPLES,
        )
        self.assertEqual(operation_payload["fingerprints"], list(operation.fingerprints))

    def test_database_delta_is_reset_safe(self) -> None:
        before = {"xactCommit": 100, "walBytes": 500}
        after = {"xactCommit": 12, "walBytes": 700}
        delta = workload.database_delta(before, after)
        self.assertEqual(delta["xactCommit"], 12)
        self.assertEqual(delta["walBytes"], 200)
        self.assertTrue(delta["statsResetDetected"])


if __name__ == "__main__":
    unittest.main()
