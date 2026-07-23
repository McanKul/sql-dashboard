from __future__ import annotations

import os
import random
import time
from concurrent.futures import ThreadPoolExecutor

import psycopg


DATABASE_URL = os.environ["DATABASE_URL"]
INTERVAL = float(os.getenv("WORKLOAD_INTERVAL_SECONDS", "0.25"))
WORKERS = int(os.getenv("WORKLOAD_WORKERS", "6"))
REPEAT_MIN = int(os.getenv("WORKLOAD_REPEAT_MIN", "4"))
REPEAT_MAX = int(os.getenv("WORKLOAD_REPEAT_MAX", "10"))
FUNCTION_ITERATIONS = int(os.getenv("WORKLOAD_FUNCTION_ITERATIONS", "8"))


QUERIES: tuple[tuple[str, tuple], ...] = (
    ("SELECT count(*) FROM orders WHERE status = %s", ("pending",)),
    ("SELECT sum(total) FROM orders WHERE created_at > now() - interval '14 days'", ()),
    (
        "SELECT c.region, count(*), avg(o.total) FROM customers c "
        "JOIN orders o ON o.customer_id = c.id WHERE o.status <> %s GROUP BY c.region",
        ("cancelled",),
    ),
    ("SELECT count(*) FROM events WHERE metadata ->> 'device' = %s", ("mobile",)),
    (
        "SELECT o.status, count(i.id), sum(i.quantity * i.unit_price) "
        "FROM orders o JOIN order_items i ON i.order_id = o.id "
        "WHERE o.created_at > now() - interval '7 days' GROUP BY o.status",
        (),
    ),
)


def run_cycle(connection: psycopg.Connection) -> None:
    with connection.cursor() as cursor:
        for query, params in QUERIES:
            repeat = random.randint(REPEAT_MIN, REPEAT_MAX)
            for _ in range(repeat):
                cursor.execute(query, params)
                cursor.fetchall()
        cursor.execute("SELECT run_advisor_test_workload(%s)", (FUNCTION_ITERATIONS,))
        cursor.fetchone()
    connection.commit()


def run_worker(worker_id: int) -> None:
    while True:
        try:
            application_name = f"advisor-demo-workload-{worker_id}"
            with psycopg.connect(DATABASE_URL, application_name=application_name) as connection:
                while True:
                    run_cycle(connection)
                    time.sleep(INTERVAL)
        except (psycopg.Error, OSError) as exc:
            print(f"workload worker {worker_id} reconnect: {exc}", flush=True)
            time.sleep(3)


def main() -> None:
    if WORKERS < 1:
        raise ValueError("WORKLOAD_WORKERS must be at least 1")
    if not 1 <= REPEAT_MIN <= REPEAT_MAX:
        raise ValueError("WORKLOAD_REPEAT_MIN/MAX must define a positive range")
    if not 1 <= FUNCTION_ITERATIONS <= 1000:
        raise ValueError("WORKLOAD_FUNCTION_ITERATIONS must be between 1 and 1000")
    if INTERVAL < 0:
        raise ValueError("WORKLOAD_INTERVAL_SECONDS cannot be negative")
    print(f"starting aggressive workload: workers={WORKERS}, repeats={REPEAT_MIN}-{REPEAT_MAX}, function_iterations={FUNCTION_ITERATIONS}, interval={INTERVAL}s", flush=True)
    with ThreadPoolExecutor(max_workers=WORKERS, thread_name_prefix="workload") as executor:
        futures = [executor.submit(run_worker, worker_id) for worker_id in range(1, WORKERS + 1)]
        for future in futures:
            future.result()

if __name__ == "__main__":
    main()
