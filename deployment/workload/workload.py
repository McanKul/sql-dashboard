from __future__ import annotations

import json
import math
import os
import random
import re
import signal
import threading
import time
from collections import Counter
from concurrent.futures import FIRST_EXCEPTION, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from typing import Callable, Mapping, Sequence

import psycopg
from psycopg import sql


READER_ROLE = "advisor_workload_reader"
WRITER_ROLE = "advisor_workload_writer"
REPORTER_ROLE = "advisor_workload_reporter"
WORKLOAD_ROLES = (READER_ROLE, WRITER_ROLE, REPORTER_ROLE)

STATUSES = ("pending", "paid", "shipped", "cancelled")
DEVICES = ("desktop", "mobile")
PAYMENT_STATUSES = ("authorized", "captured", "failed", "refunded")
JOB_QUEUES = ("email", "invoice", "webhook", "fulfillment")

TAG_PATTERN = re.compile(r"/\* advisor-realistic:([a-z0-9-]+) \*/")
MAX_SQL_TEMPLATES = 32
MAX_LATENCY_SAMPLES = 4_096


# Keep this exact query shape: the JOIN snapshotter acceptance and the runtime
# validation fixture both depend on its stable normalized query identity.
EXACT_JOIN_STATUS_PREFIX = (
    "SELECT count(*) FROM public.customers AS c "
    "JOIN public.orders AS o ON o.customer_id = c.id "
    "WHERE o.status = %s"
)
# Deliberate sole tag exception: iteration 2.7 binds its approved replay fixture
# to the exact no-comment text stored by pg_stat_statements.
JOIN_ORDERS_STATUS_SQL = EXACT_JOIN_STATUS_PREFIX

READ_ORDER_BY_ID_SQL = """
WITH candidate AS (
    SELECT id
    FROM public.orders
    WHERE id >= %s
    ORDER BY id
    LIMIT 1
)
SELECT target.id, target.customer_id, target.status, target.total, target.created_at
FROM public.orders AS target
JOIN candidate USING (id)
/* advisor-realistic:read-order-by-id */
"""

READ_CUSTOMER_ORDERS_SQL = """
WITH candidate AS (
    SELECT id
    FROM public.customers
    WHERE id >= %s
    ORDER BY id
    LIMIT 1
)
SELECT target.id, target.status, target.total, target.created_at
FROM public.orders AS target
JOIN candidate ON candidate.id = target.customer_id
ORDER BY target.created_at DESC
LIMIT 25
/* advisor-realistic:read-customer-orders */
"""

READ_EVENT_DEVICE_SQL = """
SELECT count(*)
FROM public.events
WHERE metadata ->> 'device' = %s
  AND created_at >= now() - (%s * interval '1 day')
/* advisor-realistic:read-event-device */
"""

READ_INVENTORY_SQL = """
WITH candidate AS (
    SELECT product_id, warehouse_id
    FROM public.workload_inventory
    WHERE (product_id, warehouse_id) >= (%s, %s)
    ORDER BY product_id, warehouse_id
    LIMIT 1
)
SELECT target.available, target.reserved, target.version, target.updated_at
FROM public.workload_inventory AS target
JOIN candidate USING (product_id, warehouse_id)
/* advisor-realistic:read-inventory */
"""

READ_READY_JOBS_SQL = """
SELECT id, queue, priority, run_at, attempts
FROM public.workload_jobs
WHERE tenant_id = %s
  AND queue = %s
  AND status = 'ready'
  AND run_at <= now()
ORDER BY priority DESC, run_at, id
LIMIT 20
/* advisor-realistic:read-ready-jobs */
"""

JOIN_INVENTORY_PRODUCTS_SQL = """
SELECT p.category, count(*) AS product_count,
       sum(i.available) AS available, sum(i.reserved) AS reserved
FROM public.workload_inventory AS i
JOIN public.workload_products AS p ON p.id = i.product_id
WHERE i.warehouse_id = %s
  AND p.tenant_id = %s
  AND p.active = true
GROUP BY p.category
/* advisor-realistic:join-inventory-products */
"""

JOIN_PAYMENTS_ORDERS_SQL = """
SELECT o.status, count(*) AS payment_count, sum(p.amount) AS payment_total
FROM public.workload_payments AS p
JOIN public.orders AS o ON o.id = p.order_id
WHERE p.status = %s
  AND p.created_at >= now() - (%s * interval '1 day')
GROUP BY o.status
/* advisor-realistic:join-payments-orders */
"""

CPU_ORDER_ROLLUP_SQL = """
SELECT status, count(*) AS order_count, sum(total) AS order_total,
       avg(total) AS order_average, stddev_pop(total) AS order_stddev
FROM public.orders
WHERE created_at >= now() - (%s * interval '1 day')
GROUP BY status
/* advisor-realistic:cpu-order-rollup */
"""

TEMP_CUSTOMER_ROLLUP_SQL = """
SELECT customer_id, status, count(*) AS order_count, sum(total) AS order_total
FROM public.orders
GROUP BY customer_id, status
ORDER BY order_total DESC, customer_id
LIMIT 100
/* advisor-realistic:temp-customer-rollup */
"""

RETENTION_LOCK_SQL = """
SELECT pg_advisory_xact_lock(%s::integer, %s::integer)
/* advisor-realistic:retention-lock */
"""

WRITE_MUTATION_INSERT_SQL = """
INSERT INTO public.workload_mutations (
    worker_pid, mutation_value, payload, created_at, updated_at
)
VALUES (
    pg_backend_pid(), %s,
    jsonb_build_object(
        'source', 'advisor-realistic', 'worker', %s, 'nonce', %s
    ),
    clock_timestamp(), clock_timestamp()
)
RETURNING id
/* advisor-realistic:write-mutation-insert */
"""

WRITE_MUTATION_UPDATE_SQL = """
UPDATE public.workload_mutations
SET mutation_value = mutation_value + 1,
    payload = payload || jsonb_build_object('updated', true),
    updated_at = clock_timestamp()
WHERE id = %s
/* advisor-realistic:write-mutation-update */
"""

WRITE_MUTATION_CLEANUP_SQL = """
WITH doomed AS (
    SELECT id
    FROM public.workload_mutations
    WHERE payload ->> 'source' = 'advisor-realistic'
    ORDER BY id DESC
    OFFSET %s
    LIMIT %s
)
DELETE FROM public.workload_mutations AS mutation
USING doomed
WHERE mutation.id = doomed.id
/* advisor-realistic:write-mutation-cleanup */
"""

WRITE_EVENT_INSERT_SQL = """
INSERT INTO public.events (event_type, customer_id, metadata, created_at)
VALUES (
    %s,
    (SELECT id FROM public.customers WHERE id >= %s ORDER BY id LIMIT 1),
    jsonb_build_object(
        'source', 'advisor-realistic', 'device', %s::text, 'nonce', %s::bigint
    ),
    clock_timestamp()
)
RETURNING id
/* advisor-realistic:write-event-insert */
"""

WRITE_EVENT_CLEANUP_SQL = """
WITH doomed AS (
    SELECT id
    FROM public.events
    WHERE metadata ->> 'source' = 'advisor-realistic'
    ORDER BY id DESC
    OFFSET %s
    LIMIT %s
)
DELETE FROM public.events AS event
USING doomed
WHERE event.id = doomed.id
/* advisor-realistic:write-event-cleanup */
"""

UPDATE_ORDER_LIFECYCLE_SQL = """
WITH candidate AS (
    SELECT id
    FROM public.orders
    WHERE status = %s
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE public.orders AS target
SET status = %s,
    payload = target.payload || jsonb_build_object(
        'advisorWorkloadLastTransitionAt', clock_timestamp()
    )
FROM candidate
WHERE target.id = candidate.id
RETURNING target.id
/* advisor-realistic:update-order-lifecycle */
"""

CLAIM_JOB_SQL = """
WITH candidate AS (
    SELECT id
    FROM public.workload_jobs
    WHERE status = 'ready'
      AND run_at <= now()
    ORDER BY priority DESC, run_at, id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE public.workload_jobs AS job
SET status = 'running',
    locked_at = clock_timestamp(),
    attempts = attempts + 1
FROM candidate
WHERE job.id = candidate.id
RETURNING job.id
/* advisor-realistic:claim-job */
"""

REQUEUE_JOB_SQL = """
UPDATE public.workload_jobs
SET status = 'ready',
    locked_at = NULL,
    run_at = clock_timestamp() + (%s * interval '1 second')
WHERE id = %s
/* advisor-realistic:requeue-job */
"""

UPDATE_INVENTORY_SQL = """
WITH candidate AS (
    SELECT product_id, warehouse_id
    FROM public.workload_inventory
    ORDER BY product_id, warehouse_id
    LIMIT 1 OFFSET %s
    FOR UPDATE SKIP LOCKED
)
UPDATE public.workload_inventory AS target
SET reserved = CASE
        WHEN target.available > 0
          THEN (target.reserved + 1) %% (target.available + 1)
        ELSE 0
    END,
    version = target.version + 1,
    updated_at = clock_timestamp()
FROM candidate
WHERE target.product_id = candidate.product_id
  AND target.warehouse_id = candidate.warehouse_id
/* advisor-realistic:update-inventory */
"""

CONTROLLED_LOCK_SQL = """
UPDATE public.advisor_workload_hotspots
SET value = value + 1,
    updated_at = clock_timestamp()
WHERE id = %s
RETURNING value, pg_sleep(%s)
/* advisor-realistic:controlled-lock */
"""

PREFLIGHT_SQL = """
SELECT
    to_regclass('public.customers') IS NOT NULL,
    to_regclass('public.orders') IS NOT NULL,
    to_regclass('public.order_items') IS NOT NULL,
    to_regclass('public.events') IS NOT NULL,
    to_regclass('public.workload_mutations') IS NOT NULL,
    to_regclass('public.workload_tenants') IS NOT NULL,
    to_regclass('public.workload_products') IS NOT NULL,
    to_regclass('public.workload_inventory') IS NOT NULL,
    to_regclass('public.workload_payments') IS NOT NULL,
    to_regclass('public.workload_jobs') IS NOT NULL,
    to_regclass('public.advisor_workload_hotspots') IS NOT NULL,
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_reader'),
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_writer'),
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_workload_reporter')
/* advisor-realistic:preflight */
"""

DATA_BOUNDS_SQL = """
SELECT
    COALESCE((SELECT max(id) FROM public.customers), 0),
    COALESCE((SELECT max(id) FROM public.orders), 0),
    COALESCE((SELECT max(id) FROM public.events), 0),
    COALESCE((SELECT max(id) FROM public.workload_tenants), 0),
    COALESCE((SELECT max(id) FROM public.workload_products), 0),
    COALESCE((SELECT max(warehouse_id) FROM public.workload_inventory), 0),
    COALESCE((SELECT max(id) FROM public.advisor_workload_hotspots), 0)
/* advisor-realistic:data-bounds */
"""

ROLE_CAPABILITY_SQL = """
SELECT role_name, pg_has_role(current_user, role_name, 'SET')
FROM unnest(%s::text[]) AS role_name
ORDER BY role_name
/* advisor-realistic:role-capability */
"""

SESSION_CONFIG_SQL = """
SELECT
    set_config('statement_timeout', %s, false),
    set_config('lock_timeout', %s, false),
    set_config('idle_in_transaction_session_timeout', %s, false),
    set_config('work_mem', %s, false)
/* advisor-realistic:session-config */
"""

SET_ROLE_SQL = "SET ROLE {} /* advisor-realistic:set-role */"

DATABASE_STATS_SQL = """
SELECT xact_commit, xact_rollback, deadlocks, blks_read, blks_hit, temp_bytes
FROM pg_stat_database
WHERE datname = current_database()
/* advisor-realistic:database-stats */
"""

WAL_STATS_SQL = """
SELECT wal_bytes
FROM pg_stat_wal
/* advisor-realistic:wal-stats */
"""


SQL_TEMPLATES: dict[str, str] = {
    "read-order-by-id": READ_ORDER_BY_ID_SQL,
    "read-customer-orders": READ_CUSTOMER_ORDERS_SQL,
    "read-event-device": READ_EVENT_DEVICE_SQL,
    "read-inventory": READ_INVENTORY_SQL,
    "read-ready-jobs": READ_READY_JOBS_SQL,
    "join-orders-status": JOIN_ORDERS_STATUS_SQL,
    "join-inventory-products": JOIN_INVENTORY_PRODUCTS_SQL,
    "join-payments-orders": JOIN_PAYMENTS_ORDERS_SQL,
    "cpu-order-rollup": CPU_ORDER_ROLLUP_SQL,
    "temp-customer-rollup": TEMP_CUSTOMER_ROLLUP_SQL,
    "retention-lock": RETENTION_LOCK_SQL,
    "write-mutation-insert": WRITE_MUTATION_INSERT_SQL,
    "write-mutation-update": WRITE_MUTATION_UPDATE_SQL,
    "write-mutation-cleanup": WRITE_MUTATION_CLEANUP_SQL,
    "write-event-insert": WRITE_EVENT_INSERT_SQL,
    "write-event-cleanup": WRITE_EVENT_CLEANUP_SQL,
    "update-order-lifecycle": UPDATE_ORDER_LIFECYCLE_SQL,
    "claim-job": CLAIM_JOB_SQL,
    "requeue-job": REQUEUE_JOB_SQL,
    "update-inventory": UPDATE_INVENTORY_SQL,
    "controlled-lock": CONTROLLED_LOCK_SQL,
    "preflight": PREFLIGHT_SQL,
    "data-bounds": DATA_BOUNDS_SQL,
    "role-capability": ROLE_CAPABILITY_SQL,
    "session-config": SESSION_CONFIG_SQL,
    "set-role": SET_ROLE_SQL,
    "database-stats": DATABASE_STATS_SQL,
    "wal-stats": WAL_STATS_SQL,
}


def validate_sql_templates() -> None:
    if len(SQL_TEMPLATES) > MAX_SQL_TEMPLATES:
        raise ValueError(
            f"workload SQL template count exceeds {MAX_SQL_TEMPLATES}: "
            f"{len(SQL_TEMPLATES)}"
        )

    seen: set[str] = set()
    for expected_tag, statement in SQL_TEMPLATES.items():
        tags = TAG_PATTERN.findall(statement)
        if expected_tag == "join-orders-status":
            if tags:
                raise ValueError(
                    "the iteration 2.7 JOIN query must remain an exact no-comment template"
                )
            continue
        if tags != [expected_tag]:
            raise ValueError(
                f"SQL template {expected_tag!r} must have exactly one matching "
                f"static advisor-realistic tag; found {tags!r}"
            )
        if expected_tag in seen:
            raise ValueError(f"duplicate SQL template tag: {expected_tag}")
        seen.add(expected_tag)

    if not JOIN_ORDERS_STATUS_SQL.startswith(EXACT_JOIN_STATUS_PREFIX):
        raise ValueError("the stable orders/customer/status JOIN shape changed")


validate_sql_templates()


PROFILE_DEFAULTS: dict[str, dict[str, str]] = {
    "quick": {
        "WORKLOAD_DURATION_SECONDS": "60",
        "WORKLOAD_WORKERS": "6",
        "WORKLOAD_INTERVAL_SECONDS": "0.05",
        "WORKLOAD_REPORT_INTERVAL_SECONDS": "5",
        "WORKLOAD_STATEMENT_TIMEOUT_MS": "10000",
        "WORKLOAD_LOCK_TIMEOUT_MS": "500",
        "WORKLOAD_LOCK_HOLD_MS": "20",
    },
    "normal": {
        "WORKLOAD_DURATION_SECONDS": "300",
        "WORKLOAD_WORKERS": "8",
        "WORKLOAD_INTERVAL_SECONDS": "0.05",
        "WORKLOAD_REPORT_INTERVAL_SECONDS": "10",
        "WORKLOAD_STATEMENT_TIMEOUT_MS": "10000",
        "WORKLOAD_LOCK_TIMEOUT_MS": "500",
        "WORKLOAD_LOCK_HOLD_MS": "20",
    },
    "stress": {
        "WORKLOAD_DURATION_SECONDS": "180",
        "WORKLOAD_WORKERS": "24",
        "WORKLOAD_INTERVAL_SECONDS": "0",
        "WORKLOAD_REPORT_INTERVAL_SECONDS": "5",
        "WORKLOAD_STATEMENT_TIMEOUT_MS": "30000",
        "WORKLOAD_LOCK_TIMEOUT_MS": "1000",
        "WORKLOAD_LOCK_HOLD_MS": "40",
    },
}


def _integer(
    values: Mapping[str, str],
    defaults: Mapping[str, str],
    name: str,
    minimum: int,
    maximum: int,
) -> int:
    raw = values.get(name, defaults.get(name))
    if raw is None:
        raise ValueError(f"{name} is required")
    try:
        result = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= result <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return result


def _number(
    values: Mapping[str, str],
    defaults: Mapping[str, str],
    name: str,
    minimum: float,
    maximum: float,
) -> float:
    raw = values.get(name, defaults.get(name))
    if raw is None:
        raise ValueError(f"{name} is required")
    try:
        result = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be numeric") from exc
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return result


@dataclass(frozen=True)
class WorkloadConfig:
    database_url: str
    profile: str
    duration_seconds: int
    workers: int
    interval_seconds: float
    report_interval_seconds: int
    random_seed: int
    statement_timeout_ms: int
    lock_timeout_ms: int
    lock_hold_ms: int
    max_mutation_rows: int
    mutation_cleanup_batch: int
    max_event_rows: int
    event_cleanup_batch: int
    connect_timeout_seconds: int

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> WorkloadConfig:
        values = os.environ if environ is None else environ
        database_url = values.get("DATABASE_URL", "").strip()
        if not database_url:
            raise ValueError("DATABASE_URL is required")
        workload_password = values.get("PGPASSWORD", "")
        if len(workload_password) < 16:
            raise ValueError("WORKLOAD_DB_PASSWORD must contain at least 16 characters")
        if workload_password == "advisor_dev_workload" or workload_password.startswith(
            "change-me-"
        ):
            raise ValueError("WORKLOAD_DB_PASSWORD cannot use a known development value")

        profile = values.get("WORKLOAD_PROFILE", "normal").strip().lower()
        if profile not in PROFILE_DEFAULTS:
            raise ValueError("WORKLOAD_PROFILE must be quick, normal, or stress")
        defaults = PROFILE_DEFAULTS[profile]

        duration_seconds = _integer(
            values, defaults, "WORKLOAD_DURATION_SECONDS", 0, 86_400
        )
        workers = _integer(values, defaults, "WORKLOAD_WORKERS", 3, 64)
        interval_seconds = _number(
            values, defaults, "WORKLOAD_INTERVAL_SECONDS", 0, 60
        )
        report_interval_seconds = _integer(
            values, defaults, "WORKLOAD_REPORT_INTERVAL_SECONDS", 1, 300
        )
        if duration_seconds > 0 and report_interval_seconds > duration_seconds:
            raise ValueError(
                "WORKLOAD_REPORT_INTERVAL_SECONDS cannot exceed workload duration"
            )

        random_seed = _integer(
            values,
            {"WORKLOAD_RANDOM_SEED": "20260725"},
            "WORKLOAD_RANDOM_SEED",
            0,
            (2**63) - 1,
        )
        statement_timeout_ms = _integer(
            values, defaults, "WORKLOAD_STATEMENT_TIMEOUT_MS", 500, 120_000
        )
        lock_timeout_ms = _integer(
            values, defaults, "WORKLOAD_LOCK_TIMEOUT_MS", 50, 30_000
        )
        lock_hold_ms = _integer(
            values, defaults, "WORKLOAD_LOCK_HOLD_MS", 1, 5_000
        )
        if lock_hold_ms >= statement_timeout_ms:
            raise ValueError(
                "WORKLOAD_LOCK_HOLD_MS must be lower than statement timeout"
            )

        max_mutation_rows = _integer(
            values,
            {"WORKLOAD_MAX_MUTATION_ROWS": "10000"},
            "WORKLOAD_MAX_MUTATION_ROWS",
            100,
            1_000_000,
        )
        mutation_cleanup_batch = _integer(
            values,
            {"WORKLOAD_MUTATION_CLEANUP_BATCH": "250"},
            "WORKLOAD_MUTATION_CLEANUP_BATCH",
            1,
            10_000,
        )
        max_event_rows = _integer(
            values,
            {"WORKLOAD_MAX_EVENT_ROWS": "20000"},
            "WORKLOAD_MAX_EVENT_ROWS",
            100,
            1_000_000,
        )
        event_cleanup_batch = _integer(
            values,
            {"WORKLOAD_EVENT_CLEANUP_BATCH": "250"},
            "WORKLOAD_EVENT_CLEANUP_BATCH",
            1,
            10_000,
        )
        connect_timeout_seconds = _integer(
            values,
            {"WORKLOAD_CONNECT_TIMEOUT_SECONDS": "5"},
            "WORKLOAD_CONNECT_TIMEOUT_SECONDS",
            1,
            30,
        )

        return cls(
            database_url=database_url,
            profile=profile,
            duration_seconds=duration_seconds,
            workers=workers,
            interval_seconds=interval_seconds,
            report_interval_seconds=report_interval_seconds,
            random_seed=random_seed,
            statement_timeout_ms=statement_timeout_ms,
            lock_timeout_ms=lock_timeout_ms,
            lock_hold_ms=lock_hold_ms,
            max_mutation_rows=max_mutation_rows,
            mutation_cleanup_batch=mutation_cleanup_batch,
            max_event_rows=max_event_rows,
            event_cleanup_batch=event_cleanup_batch,
            connect_timeout_seconds=connect_timeout_seconds,
        )


@dataclass(frozen=True)
class DataBounds:
    max_customer_id: int
    max_order_id: int
    max_event_id: int
    max_tenant_id: int
    max_product_id: int
    max_warehouse_id: int
    max_hotspot_id: int

    def validate(self) -> None:
        for name, value in self.__dict__.items():
            if value < 1:
                raise RuntimeError(
                    f"realistic workload seed is missing or empty: {name}={value}"
                )


CursorExecutor = Callable[
    [psycopg.Cursor, random.Random, WorkloadConfig, DataBounds, int], None
]


@dataclass(frozen=True)
class Operation:
    name: str
    category: str
    role: str
    normal_weight: int
    stress_weight: int
    fingerprints: tuple[str, ...]
    execute: CursorExecutor

    def weight(self, profile: str) -> int:
        return self.stress_weight if profile == "stress" else self.normal_weight


def _consume_all(cursor: psycopg.Cursor) -> None:
    cursor.fetchall()


def execute_read_order_by_id(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(READ_ORDER_BY_ID_SQL, (rng.randint(1, bounds.max_order_id),))
    _consume_all(cursor)


def execute_read_customer_orders(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(
        READ_CUSTOMER_ORDERS_SQL, (rng.randint(1, bounds.max_customer_id),)
    )
    _consume_all(cursor)


def execute_read_event_device(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(READ_EVENT_DEVICE_SQL, (rng.choice(DEVICES), rng.randint(1, 30)))
    _consume_all(cursor)


def execute_read_inventory(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(
        READ_INVENTORY_SQL,
        (
            rng.randint(1, bounds.max_product_id),
            rng.randint(1, bounds.max_warehouse_id),
        ),
    )
    _consume_all(cursor)


def execute_read_ready_jobs(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(
        READ_READY_JOBS_SQL,
        (rng.randint(1, bounds.max_tenant_id), rng.choice(JOB_QUEUES)),
    )
    _consume_all(cursor)


def execute_join_orders_status(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(JOIN_ORDERS_STATUS_SQL, (rng.choice(STATUSES),))
    _consume_all(cursor)


def execute_join_inventory_products(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(
        JOIN_INVENTORY_PRODUCTS_SQL,
        (
            rng.randint(1, bounds.max_warehouse_id),
            rng.randint(1, bounds.max_tenant_id),
        ),
    )
    _consume_all(cursor)


def execute_join_payments_orders(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(
        JOIN_PAYMENTS_ORDERS_SQL,
        (rng.choice(PAYMENT_STATUSES), rng.randint(1, 30)),
    )
    _consume_all(cursor)


def execute_cpu_order_rollup(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(CPU_ORDER_ROLLUP_SQL, (rng.randint(7, 45),))
    _consume_all(cursor)


def execute_temp_customer_rollup(
    cursor: psycopg.Cursor,
    _rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(TEMP_CUSTOMER_ROLLUP_SQL)
    _consume_all(cursor)


def execute_write_mutation(
    cursor: psycopg.Cursor,
    rng: random.Random,
    config: WorkloadConfig,
    _bounds: DataBounds,
    worker_id: int,
) -> None:
    # Serialize insert+cleanup across every workload process.  The xact lock is
    # acquired in its own statement, so the following READ COMMITTED snapshots
    # see the preceding lock holder's committed cleanup.
    cursor.execute(RETENTION_LOCK_SQL, (20_260_725, 1))
    if cursor.fetchone() is None:
        raise RuntimeError("workload mutation retention lock returned no row")
    cursor.execute(
        WRITE_MUTATION_INSERT_SQL,
        (rng.randint(1, 1_000_000), worker_id, rng.getrandbits(63)),
    )
    row = cursor.fetchone()
    if row is None:
        raise RuntimeError("workload mutation INSERT returned no id")
    mutation_id = int(row[0])
    cursor.execute(WRITE_MUTATION_UPDATE_SQL, (mutation_id,))
    cursor.execute(
        WRITE_MUTATION_CLEANUP_SQL,
        (config.max_mutation_rows, config.mutation_cleanup_batch),
    )


def execute_write_event(
    cursor: psycopg.Cursor,
    rng: random.Random,
    config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(RETENTION_LOCK_SQL, (20_260_725, 2))
    if cursor.fetchone() is None:
        raise RuntimeError("workload event retention lock returned no row")
    cursor.execute(
        WRITE_EVENT_INSERT_SQL,
        (
            rng.choice(("page_view", "checkout", "search", "login")),
            rng.randint(1, bounds.max_customer_id),
            rng.choice(DEVICES),
            rng.getrandbits(63),
        ),
    )
    if cursor.fetchone() is None:
        raise RuntimeError("workload event INSERT returned no id")
    cursor.execute(
        WRITE_EVENT_CLEANUP_SQL,
        (config.max_event_rows, config.event_cleanup_batch),
    )


def execute_update_order_lifecycle(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    previous_status, next_status = rng.choice(
        (("pending", "paid"), ("paid", "shipped"), ("shipped", "paid"))
    )
    cursor.execute(UPDATE_ORDER_LIFECYCLE_SQL, (previous_status, next_status))
    cursor.fetchone()


def execute_claim_job(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    _bounds: DataBounds,
    _worker_id: int,
) -> None:
    cursor.execute(CLAIM_JOB_SQL)
    row = cursor.fetchone()
    if row is not None:
        cursor.execute(REQUEUE_JOB_SQL, (rng.randint(1, 5), int(row[0])))


def execute_update_inventory(
    cursor: psycopg.Cursor,
    rng: random.Random,
    _config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    # A deliberately small hot set creates realistic row-level contention while
    # keeping all changes bounded to counters in the synthetic inventory table.
    hot_rows = min(bounds.max_product_id * bounds.max_warehouse_id, 256)
    cursor.execute(UPDATE_INVENTORY_SQL, (rng.randrange(hot_rows),))


def execute_controlled_lock(
    cursor: psycopg.Cursor,
    rng: random.Random,
    config: WorkloadConfig,
    bounds: DataBounds,
    _worker_id: int,
) -> None:
    # All writer sessions deliberately converge on one synthetic row.  A
    # sampled Lock signal must be reproducible even when a large quick-profile
    # data set makes the other operations slow; the short hold and lock timeout
    # keep this contention bounded and deadlock-free.
    if bounds.max_hotspot_id < 1:
        raise RuntimeError("controlled-lock hotspot is unavailable")
    hotspot_id = 1
    jitter = rng.uniform(0.75, 1.25)
    hold_seconds = max(0.001, (config.lock_hold_ms * jitter) / 1000)
    cursor.execute(CONTROLLED_LOCK_SQL, (hotspot_id, hold_seconds))
    _consume_all(cursor)


OPERATIONS: tuple[Operation, ...] = (
    Operation(
        "read-order-by-id",
        "read",
        READER_ROLE,
        20,
        15,
        ("read-order-by-id",),
        execute_read_order_by_id,
    ),
    Operation(
        "read-customer-orders",
        "read",
        READER_ROLE,
        30,
        25,
        ("read-customer-orders",),
        execute_read_customer_orders,
    ),
    Operation(
        "read-event-device",
        "read",
        READER_ROLE,
        5,
        10,
        ("read-event-device",),
        execute_read_event_device,
    ),
    Operation(
        "read-inventory",
        "read",
        READER_ROLE,
        30,
        30,
        ("read-inventory",),
        execute_read_inventory,
    ),
    Operation(
        "read-ready-jobs",
        "read",
        READER_ROLE,
        15,
        20,
        ("read-ready-jobs",),
        execute_read_ready_jobs,
    ),
    # The same normalized JOIN is intentionally executed by both a reader and
    # a reporter SET ROLE identity.  PostgreSQL shares its query_id across the
    # roles, exercising the repository's multi-user candidate aggregation.
    Operation(
        "join-orders-status-reader",
        "join",
        READER_ROLE,
        10,
        10,
        ("join-orders-status",),
        execute_join_orders_status,
    ),
    Operation(
        "join-orders-status",
        "join",
        REPORTER_ROLE,
        30,
        25,
        ("join-orders-status",),
        execute_join_orders_status,
    ),
    Operation(
        "join-inventory-products",
        "join",
        REPORTER_ROLE,
        20,
        25,
        ("join-inventory-products",),
        execute_join_inventory_products,
    ),
    Operation(
        "join-payments-orders",
        "join",
        REPORTER_ROLE,
        15,
        20,
        ("join-payments-orders",),
        execute_join_payments_orders,
    ),
    Operation(
        "cpu-order-rollup",
        "cpu",
        REPORTER_ROLE,
        25,
        15,
        ("cpu-order-rollup",),
        execute_cpu_order_rollup,
    ),
    Operation(
        "temp-customer-rollup",
        "temp",
        REPORTER_ROLE,
        10,
        15,
        ("temp-customer-rollup",),
        execute_temp_customer_rollup,
    ),
    Operation(
        "write-mutation",
        "write",
        WRITER_ROLE,
        25,
        15,
        (
            "retention-lock",
            "write-mutation-insert",
            "write-mutation-update",
            "write-mutation-cleanup",
        ),
        execute_write_mutation,
    ),
    Operation(
        "update-inventory",
        "write",
        WRITER_ROLE,
        20,
        20,
        ("update-inventory",),
        execute_update_inventory,
    ),
    Operation(
        "write-event",
        "write",
        WRITER_ROLE,
        10,
        10,
        ("retention-lock", "write-event-insert", "write-event-cleanup"),
        execute_write_event,
    ),
    Operation(
        "update-order-lifecycle",
        "write",
        WRITER_ROLE,
        20,
        20,
        ("update-order-lifecycle",),
        execute_update_order_lifecycle,
    ),
    Operation(
        "claim-job",
        "write",
        WRITER_ROLE,
        20,
        20,
        ("claim-job", "requeue-job"),
        execute_claim_job,
    ),
    Operation(
        "controlled-lock",
        "lock",
        WRITER_ROLE,
        20,
        15,
        ("controlled-lock",),
        execute_controlled_lock,
    ),
)


OPERATIONS_BY_ROLE: dict[str, tuple[Operation, ...]] = {
    role: tuple(operation for operation in OPERATIONS if operation.role == role)
    for role in WORKLOAD_ROLES
}


def worker_seed(base_seed: int, worker_id: int) -> int:
    return (base_seed + worker_id * 1_000_003) % (2**63)


ROLE_SHARES: dict[str, dict[str, float]] = {
    "quick": {READER_ROLE: 0.50, REPORTER_ROLE: 0.30, WRITER_ROLE: 0.20},
    "normal": {READER_ROLE: 0.50, REPORTER_ROLE: 0.30, WRITER_ROLE: 0.20},
    "stress": {READER_ROLE: 0.35, REPORTER_ROLE: 0.30, WRITER_ROLE: 0.35},
}


def allocate_worker_roles(workers: int, profile: str, seed: int) -> tuple[str, ...]:
    if profile not in ROLE_SHARES:
        raise ValueError(f"unsupported profile: {profile}")
    if workers < len(WORKLOAD_ROLES):
        raise ValueError("at least one worker per workload role is required")

    shares = ROLE_SHARES[profile]
    counts = {role: 1 for role in WORKLOAD_ROLES}
    for _ in range(workers - len(WORKLOAD_ROLES)):
        role = max(
            WORKLOAD_ROLES,
            key=lambda candidate: workers * shares[candidate] - counts[candidate],
        )
        counts[role] += 1

    roles = [role for role in WORKLOAD_ROLES for _ in range(counts[role])]
    random.Random(seed ^ 0x5A17_2026).shuffle(roles)
    return tuple(roles)


def choose_operation(
    role: str, profile: str, rng: random.Random
) -> Operation:
    operations = OPERATIONS_BY_ROLE[role]
    weights = [operation.weight(profile) for operation in operations]
    return rng.choices(operations, weights=weights, k=1)[0]


@dataclass
class OperationMetric:
    attempted: int = 0
    succeeded: int = 0
    failed: int = 0
    total_latency_ms: float = 0
    max_latency_ms: float = 0
    samples_seen: int = 0
    latency_samples_ms: list[float] = field(default_factory=list)

    def record(self, latency_ms: float, success: bool, rng: random.Random) -> None:
        self.attempted += 1
        self.succeeded += int(success)
        self.failed += int(not success)
        self.total_latency_ms += latency_ms
        self.max_latency_ms = max(self.max_latency_ms, latency_ms)
        self.samples_seen += 1
        if len(self.latency_samples_ms) < MAX_LATENCY_SAMPLES:
            self.latency_samples_ms.append(latency_ms)
        else:
            position = rng.randrange(self.samples_seen)
            if position < MAX_LATENCY_SAMPLES:
                self.latency_samples_ms[position] = latency_ms


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[position]


def _metrics_payload(
    attempted: int,
    succeeded: int,
    failed: int,
    total_latency_ms: float,
    max_latency_ms: float,
    samples: Sequence[float],
    elapsed_seconds: float,
) -> dict[str, object]:
    denominator = max(attempted, 1)
    return {
        "attempted": attempted,
        "succeeded": succeeded,
        "failed": failed,
        # The acceptance verifier recomputes this ratio from integer counters;
        # retain enough precision for low error rates on long stress runs.
        "errorRate": round(failed / denominator, 12),
        "errorRatePercent": round(100 * failed / denominator, 3),
        "transactionsPerSecond": round(succeeded / max(elapsed_seconds, 0.001), 3),
        "meanLatencyMs": round(total_latency_ms / denominator, 3),
        "latencyMs": {
            "p50": round(_percentile(samples, 0.50), 3),
            "p95": round(_percentile(samples, 0.95), 3),
            "max": round(max_latency_ms, 3),
        },
    }


class WorkloadMetrics:
    def __init__(self, seed: int) -> None:
        self._lock = threading.Lock()
        self._rng = random.Random(seed ^ 0xA11C_E55)
        self._operations = {operation.name: OperationMetric() for operation in OPERATIONS}
        self._connection_errors = 0
        self._errors_by_sqlstate: Counter[str] = Counter()

    def record_operation(
        self,
        operation: Operation,
        latency_ms: float,
        success: bool,
        sqlstate: str | None = None,
    ) -> None:
        with self._lock:
            self._operations[operation.name].record(latency_ms, success, self._rng)
            if not success:
                self._errors_by_sqlstate[sqlstate or "UNKNOWN"] += 1

    def record_connection_error(self, sqlstate: str | None = None) -> None:
        with self._lock:
            self._connection_errors += 1
            self._errors_by_sqlstate[sqlstate or "CONNECTION"] += 1

    def snapshot(self, elapsed_seconds: float) -> dict[str, object]:
        with self._lock:
            copied = {
                name: OperationMetric(
                    attempted=metric.attempted,
                    succeeded=metric.succeeded,
                    failed=metric.failed,
                    total_latency_ms=metric.total_latency_ms,
                    max_latency_ms=metric.max_latency_ms,
                    samples_seen=metric.samples_seen,
                    latency_samples_ms=list(metric.latency_samples_ms),
                )
                for name, metric in self._operations.items()
            }
            connection_errors = self._connection_errors
            errors_by_sqlstate = dict(sorted(self._errors_by_sqlstate.items()))

        operation_payload: dict[str, object] = {}
        category_metrics: dict[str, OperationMetric] = {}
        total = OperationMetric()
        for operation in OPERATIONS:
            metric = copied[operation.name]
            payload = _metrics_payload(
                metric.attempted,
                metric.succeeded,
                metric.failed,
                metric.total_latency_ms,
                metric.max_latency_ms,
                metric.latency_samples_ms,
                elapsed_seconds,
            )
            payload.update(
                {
                    "category": operation.category,
                    "role": operation.role,
                    "fingerprints": list(operation.fingerprints),
                    "latencySampleCount": len(metric.latency_samples_ms),
                }
            )
            operation_payload[operation.name] = payload

            category = category_metrics.setdefault(operation.category, OperationMetric())
            for aggregate in (category, total):
                aggregate.attempted += metric.attempted
                aggregate.succeeded += metric.succeeded
                aggregate.failed += metric.failed
                aggregate.total_latency_ms += metric.total_latency_ms
                aggregate.max_latency_ms = max(
                    aggregate.max_latency_ms, metric.max_latency_ms
                )
                aggregate.latency_samples_ms.extend(metric.latency_samples_ms)

        category_payload = {
            name: _metrics_payload(
                metric.attempted,
                metric.succeeded,
                metric.failed,
                metric.total_latency_ms,
                metric.max_latency_ms,
                metric.latency_samples_ms,
                elapsed_seconds,
            )
            for name, metric in sorted(category_metrics.items())
        }
        totals = _metrics_payload(
            total.attempted,
            total.succeeded,
            total.failed,
            total.total_latency_ms,
            total.max_latency_ms,
            total.latency_samples_ms,
            elapsed_seconds,
        )
        totals["connectionErrors"] = connection_errors
        totals["errorsBySqlstate"] = errors_by_sqlstate
        return {
            "totals": totals,
            "categories": category_payload,
            "operations": operation_payload,
        }


def _role_counts(roles: Sequence[str]) -> dict[str, int]:
    counts = Counter(roles)
    return {role: counts[role] for role in WORKLOAD_ROLES}


def preflight(config: WorkloadConfig) -> DataBounds:
    with psycopg.connect(
        config.database_url,
        application_name="advisor-realistic-preflight",
        connect_timeout=config.connect_timeout_seconds,
        autocommit=True,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(PREFLIGHT_SQL)
            checks = cursor.fetchone()
            if checks is None or not all(checks):
                raise RuntimeError(
                    "realistic workload schema/roles are incomplete; run the "
                    "realistic workload preparation script first"
                )

            cursor.execute(ROLE_CAPABILITY_SQL, (list(WORKLOAD_ROLES),))
            capabilities = cursor.fetchall()
            if len(capabilities) != len(WORKLOAD_ROLES) or not all(
                bool(row[1]) for row in capabilities
            ):
                raise RuntimeError(
                    "DATABASE_URL login cannot SET ROLE to all dedicated workload roles"
                )

            cursor.execute(DATA_BOUNDS_SQL)
            raw_bounds = cursor.fetchone()
            if raw_bounds is None:
                raise RuntimeError("realistic workload data bounds could not be read")
            bounds = DataBounds(*(int(value) for value in raw_bounds))
            bounds.validate()
            return bounds


def capture_database_stats(config: WorkloadConfig) -> dict[str, int]:
    with psycopg.connect(
        config.database_url,
        application_name="advisor-realistic-metrics",
        connect_timeout=config.connect_timeout_seconds,
        autocommit=True,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(DATABASE_STATS_SQL)
            database_row = cursor.fetchone()
            if database_row is None:
                raise RuntimeError("pg_stat_database returned no current database row")
            cursor.execute(WAL_STATS_SQL)
            wal_row = cursor.fetchone()
            if wal_row is None:
                raise RuntimeError("pg_stat_wal returned no row")

    values = (*database_row, wal_row[0])
    names = (
        "xactCommit",
        "xactRollback",
        "deadlocks",
        "blocksRead",
        "blocksHit",
        "tempBytes",
        "walBytes",
    )
    return {
        name: int(value if not isinstance(value, Decimal) else value.to_integral_value())
        for name, value in zip(names, values, strict=True)
    }


def database_delta(before: Mapping[str, int], after: Mapping[str, int]) -> dict[str, object]:
    reset_detected = any(after[name] < before[name] for name in before)
    delta = {
        name: max(0, after[name] - before[name])
        if after[name] >= before[name]
        else after[name]
        for name in before
    }
    delta["statsResetDetected"] = reset_detected
    return delta


def _configure_connection(
    connection: psycopg.Connection, role: str, config: WorkloadConfig
) -> None:
    work_mem = "1MB" if role == REPORTER_ROLE else "4MB"
    with connection.cursor() as cursor:
        cursor.execute(sql.SQL(SET_ROLE_SQL).format(sql.Identifier(role)))
        cursor.execute(
            SESSION_CONFIG_SQL,
            (
                f"{config.statement_timeout_ms}ms",
                f"{config.lock_timeout_ms}ms",
                f"{max(config.statement_timeout_ms * 2, 5_000)}ms",
                work_mem,
            ),
        )
        cursor.fetchone()
    connection.commit()


def _is_connection_failure(
    error: psycopg.Error, connection: psycopg.Connection
) -> bool:
    sqlstate = getattr(error, "sqlstate", None)
    return bool(
        connection.closed
        or connection.broken
        or (isinstance(sqlstate, str) and sqlstate.startswith("08"))
    )


def run_worker(
    worker_id: int,
    role: str,
    config: WorkloadConfig,
    bounds: DataBounds,
    metrics: WorkloadMetrics,
    stop_event: threading.Event,
    deadline: float,
) -> None:
    rng = random.Random(worker_seed(config.random_seed, worker_id))
    reconnect_delay = 0.25
    while not stop_event.is_set() and time.monotonic() < deadline:
        try:
            application_name = (
                f"advisor-realistic-{config.profile}-{role.rsplit('_', 1)[-1]}-"
                f"{worker_id}"
            )
            with psycopg.connect(
                config.database_url,
                application_name=application_name,
                connect_timeout=config.connect_timeout_seconds,
            ) as connection:
                _configure_connection(connection, role, config)
                reconnect_delay = 0.25

                while not stop_event.is_set() and time.monotonic() < deadline:
                    operation = choose_operation(role, config.profile, rng)
                    started_at = time.perf_counter()
                    try:
                        with connection.cursor() as cursor:
                            operation.execute(cursor, rng, config, bounds, worker_id)
                        connection.commit()
                    except psycopg.Error as exc:
                        latency_ms = (time.perf_counter() - started_at) * 1000
                        metrics.record_operation(
                            operation, latency_ms, False, getattr(exc, "sqlstate", None)
                        )
                        connection_failed = _is_connection_failure(exc, connection)
                        connection_sqlstate = getattr(exc, "sqlstate", None)
                        try:
                            connection.rollback()
                        except psycopg.Error as rollback_error:
                            connection_failed = True
                            connection_sqlstate = (
                                getattr(rollback_error, "sqlstate", None)
                                or connection_sqlstate
                            )
                        connection_failed = connection_failed or bool(
                            connection.closed or connection.broken
                        )
                        if connection_failed:
                            metrics.record_connection_error(connection_sqlstate)
                            break
                    except BaseException:
                        try:
                            connection.rollback()
                        except psycopg.Error:
                            pass
                        raise
                    else:
                        latency_ms = (time.perf_counter() - started_at) * 1000
                        metrics.record_operation(operation, latency_ms, True)

                    remaining = deadline - time.monotonic()
                    if config.interval_seconds > 0 and remaining > 0:
                        stop_event.wait(min(config.interval_seconds, remaining))
        except (psycopg.OperationalError, OSError) as exc:
            metrics.record_connection_error(getattr(exc, "sqlstate", None))
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            stop_event.wait(min(reconnect_delay, remaining))
            reconnect_delay = min(reconnect_delay * 2, 3.0)


def _emit(payload: Mapping[str, object]) -> None:
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")), flush=True)


def _utc_timestamp() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _heartbeat_payload(
    config: WorkloadConfig,
    metrics: WorkloadMetrics,
    elapsed_seconds: float,
    remaining_seconds: float,
) -> dict[str, object]:
    snapshot = metrics.snapshot(elapsed_seconds)
    return {
        "type": "advisor-realistic-heartbeat",
        "profile": config.profile,
        "elapsedSeconds": round(elapsed_seconds, 3),
        "remainingSeconds": (
            None
            if math.isinf(remaining_seconds)
            else round(max(0, remaining_seconds), 3)
        ),
        "totals": snapshot["totals"],
        "categories": snapshot["categories"],
    }


def run(config: WorkloadConfig) -> tuple[dict[str, object], int]:
    bounds = preflight(config)
    before = capture_database_stats(config)
    roles = allocate_worker_roles(config.workers, config.profile, config.random_seed)
    role_workers = _role_counts(roles)
    metrics = WorkloadMetrics(config.random_seed)
    stop_event = threading.Event()
    signal_received: dict[str, int | None] = {"value": None}

    def request_stop(signum: int, _frame: object) -> None:
        signal_received["value"] = signum
        stop_event.set()

    previous_handlers: dict[int, object] = {}
    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, request_stop)

    started_at = time.monotonic()
    started_at_utc = _utc_timestamp()
    deadline = (
        math.inf
        if config.duration_seconds == 0
        else started_at + config.duration_seconds
    )
    next_report = started_at + config.report_interval_seconds
    fatal_error: BaseException | None = None

    _emit(
        {
            "type": "advisor-realistic-start",
            "startedAt": started_at_utc,
            "profile": config.profile,
            "durationSeconds": config.duration_seconds,
            "durationMode": "indefinite" if config.duration_seconds == 0 else "bounded",
            "workers": config.workers,
            "roleWorkers": role_workers,
            "randomSeed": config.random_seed,
            "dataBounds": bounds.__dict__,
            "sqlTemplateCount": len(SQL_TEMPLATES),
        }
    )

    executor = ThreadPoolExecutor(
        max_workers=config.workers, thread_name_prefix="advisor-realistic"
    )
    futures: set[Future[None]] = set()
    try:
        futures = {
            executor.submit(
                run_worker,
                worker_id,
                role,
                config,
                bounds,
                metrics,
                stop_event,
                deadline,
            )
            for worker_id, role in enumerate(roles, start=1)
        }

        while futures:
            now = time.monotonic()
            if now >= deadline:
                stop_event.set()

            timeout = max(0.05, min(next_report - now, deadline - now, 0.5))
            done, pending = wait(futures, timeout=timeout, return_when=FIRST_EXCEPTION)
            for future in done:
                exception = future.exception()
                if exception is not None:
                    fatal_error = exception
                    stop_event.set()
                    break
            futures = set(pending)

            now = time.monotonic()
            if now >= next_report and not stop_event.is_set():
                _emit(
                    _heartbeat_payload(
                        config, metrics, now - started_at, deadline - now
                    )
                )
                next_report = now + config.report_interval_seconds

            if fatal_error is not None:
                break

        stop_event.set()
    finally:
        stop_event.set()
        executor.shutdown(wait=True, cancel_futures=True)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    elapsed_seconds = max(0.001, time.monotonic() - started_at)
    finished_at_utc = _utc_timestamp()
    after = capture_database_stats(config)
    snapshot = metrics.snapshot(elapsed_seconds)

    if fatal_error is not None:
        status = "failed"
        exit_code = 1
    elif signal_received["value"] is not None:
        status = "interrupted"
        exit_code = 128 + int(signal_received["value"])
    elif int(snapshot["totals"]["succeeded"]) == 0:  # type: ignore[index]
        status = "failed"
        exit_code = 1
    else:
        status = "completed"
        exit_code = 0

    final: dict[str, object] = {
        "type": "advisor-realistic-final",
        "status": status,
        "startedAt": started_at_utc,
        "finishedAt": finished_at_utc,
        "profile": config.profile,
        "durationSeconds": config.duration_seconds,
        "durationMode": "indefinite" if config.duration_seconds == 0 else "bounded",
        "elapsedSeconds": round(elapsed_seconds, 3),
        "workers": config.workers,
        "roleWorkers": role_workers,
        "randomSeed": config.random_seed,
        "dataBounds": bounds.__dict__,
        "sqlTemplateCount": len(SQL_TEMPLATES),
        "databaseDelta": database_delta(before, after),
        **snapshot,
    }
    if fatal_error is not None:
        final["fatalErrorType"] = type(fatal_error).__name__
    if signal_received["value"] is not None:
        final["signal"] = int(signal_received["value"])
    _emit(final)
    return final, exit_code


def main() -> int:
    started_at_utc = _utc_timestamp()
    try:
        config = WorkloadConfig.from_env()
        _final, exit_code = run(config)
        return exit_code
    except (ValueError, RuntimeError, psycopg.Error, OSError) as exc:
        payload = {
            "type": "advisor-realistic-final",
            "status": "failed",
            "startedAt": started_at_utc,
            "finishedAt": _utc_timestamp(),
            "fatalErrorType": type(exc).__name__,
        }
        # Configuration and preflight errors are authored by this module and
        # contain no DSN/bind values. Driver errors remain type-only so server
        # diagnostics cannot accidentally disclose workload parameters.
        if isinstance(exc, (ValueError, RuntimeError)):
            payload["reason"] = str(exc)
        _emit(payload)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
