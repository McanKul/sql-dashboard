from __future__ import annotations

import os
import random
import time

import psycopg


DATABASE_URL = os.environ["DATABASE_URL"]
INTERVAL = float(os.getenv("WORKLOAD_INTERVAL_SECONDS", "2"))


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
            repeat = random.randint(1, 4)
            for _ in range(repeat):
                cursor.execute(query, params)
                cursor.fetchall()
        cursor.execute("SELECT run_advisor_test_workload(%s)", (2,))
        cursor.fetchone()
    connection.commit()


def main() -> None:
    while True:
        try:
            with psycopg.connect(DATABASE_URL, application_name="advisor-demo-workload") as connection:
                while True:
                    run_cycle(connection)
                    time.sleep(INTERVAL)
        except (psycopg.Error, OSError) as exc:
            print(f"workload reconnect: {exc}", flush=True)
            time.sleep(3)


if __name__ == "__main__":
    main()
