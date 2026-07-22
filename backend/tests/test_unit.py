from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.api.router import _summarize_collectors
from app.repositories.powa import findings_for, interval_for, score_breakdown, serialize_query
from app.schemas import AnnotationUpdate
from app.security import can_view_sql, mask_sql


BASE_ROW = {
    "server_id": 1,
    "database_id": 16384,
    "query_id": 42,
    "sql_text": "SELECT * FROM orders WHERE customer_id = $1",
    "database_name": "appdb",
    "calls": 100,
    "total_exec_time_ms": 1200.0,
    "mean_exec_time_ms": 12.0,
    "db_load_percent": 25.0,
    "shared_blocks_hit": 100,
    "shared_blocks_read": 80,
    "temp_blocks_written": 5,
    "wal_bytes": 2_000_000,
    "previous_calls": 80,
    "previous_mean_exec_time_ms": 8.0,
    "regression_percent": 50.0,
    "impact_score": 87.5,
    "priority": "CRITICAL",
    "review_status": "NEW",
    "note": None,
    "updated_by": None,
    "updated_at": None,
    "total_time_score": 100,
    "physical_read_score": 80,
    "call_frequency_score": 60,
    "temp_write_score": 40,
    "regression_score": 90,
    "wal_score": 50,
}


def test_impact_score_breakdown_uses_documented_weights() -> None:
    breakdown = score_breakdown(BASE_ROW)
    assert breakdown["totalTime"] == {"score": 100.0, "weight": 0.4, "contribution": 40.0}
    contribution = sum(component["contribution"] for component in breakdown.values())
    assert contribution == pytest.approx(80.5)


def test_unauthorized_sql_is_masked() -> None:
    item = serialize_query(BASE_ROW, sql_visible=False)
    assert item["queryId"] == "42"
    assert item["sqlVisible"] is False
    assert "orders" not in item["sql"]
    assert item["sql"].startswith("SELECT")
    assert can_view_sql("viewer") is False
    assert can_view_sql("analyst") is True


def test_findings_are_explainable() -> None:
    findings = findings_for(BASE_ROW)
    assert len(findings) >= 4
    assert any("es doneme" in finding for finding in findings)


@pytest.mark.parametrize("window", ["1h", "24h", "7d", "30d"])
def test_supported_windows(window: str) -> None:
    assert interval_for(window)


def test_unknown_window_rejected() -> None:
    with pytest.raises(ValueError):
        interval_for("2y")


def test_annotation_status_validation() -> None:
    payload = AnnotationUpdate(status="in_review", note="Kontrol ediliyor", updatedBy="tester")
    assert payload.status == "IN_REVIEW"
    with pytest.raises(ValidationError):
        AnnotationUpdate(status="RUNNING", updatedBy="tester")


def test_api_source_connection_is_rejected() -> None:
    with pytest.raises(ValidationError):
        Settings(database_url="postgresql://advisor@source-db:5432/appdb")


def test_mask_sql_keeps_only_statement_kind() -> None:
    masked = mask_sql("UPDATE secret_table SET token = 'x'")
    assert masked.startswith("UPDATE")
    assert "secret_table" not in masked


def test_collector_summary_exposes_worst_source() -> None:
    rows = [
        {
            "server_id": 1,
            "alias": "primary",
            "hostname": "db-a",
            "port": 5432,
            "frequency": 60,
            "retention": "90 days",
            "last_snapshot_at": __import__("datetime").datetime(2026, 1, 1, 12, 0),
            "lag_seconds": 3.0,
            "errors": [],
            "status": "HEALTHY",
        },
        {
            "server_id": 2,
            "alias": "reporting",
            "hostname": "db-b",
            "port": 5432,
            "frequency": 60,
            "retention": "90 days",
            "last_snapshot_at": __import__("datetime").datetime(2026, 1, 1, 11, 59),
            "lag_seconds": 63.0,
            "errors": ["timeout"],
            "status": "DEGRADED",
        },
    ]

    summary = _summarize_collectors(rows)

    assert summary["status"] == "DEGRADED"
    assert summary["lag_seconds"] == 63.0
    assert summary["alias"] == "2 PostgreSQL kaynağı"
    assert summary["errors"] == ["reporting: timeout"]
