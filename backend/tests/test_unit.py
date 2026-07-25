from __future__ import annotations

import pytest
from pydantic import ValidationError

import app.api.router as router_module
from app.config import Settings
from app.api.router import (
    _cache_hit_percent,
    _database_io_payload,
    _index_payload,
    _predicate_payload,
    _summarize_collectors,
    io_telemetry,
    overview,
    query_detail,
    query_predicates,
    queries,
)
from app.repositories.powa import findings_for, interval_for, repository, score_breakdown, serialize_query
from app.schemas import AnnotationUpdate, IndexResponse, PredicateResponse
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
    "kcache_available": True,
    "kcache_version": "2.3.2",
    "kcache_data_available": True,
    "cpu_user_time_ms": 700.0,
    "cpu_system_time_ms": 100.0,
    "cpu_total_time_ms": 800.0,
    "cpu_percent_of_exec_time": 66.67,
    "filesystem_reads_bytes": 4096,
    "filesystem_writes_bytes": 1024,
    "observed_from": "2026-07-24T12:00:00Z",
    "observed_to": "2026-07-25T12:00:00Z",
    "coverage_percent": 100.0,
    "reset_detected": False,
    "comparison_reliable": True,
    "warming_up": False,
    "previous_period_available": True,
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


def test_score_breakdown_explains_absolute_volume_gate() -> None:
    row = {
        **BASE_ROW,
        "physical_read_score": 0.6,
        "score_details": {
            "physicalRead": {
                "percentileScore": 100,
                "volumeFactor": 0.006,
                "absoluteValue": 6,
                "volumeValue": 6,
                "fullScoreAt": 1000,
                "unit": "blocks",
            }
        },
    }
    part = score_breakdown(row)["physicalRead"]
    assert part["score"] == 0.6
    assert part["percentileScore"] == 100
    assert part["volumeFactor"] == 0.006
    assert part["contribution"] == pytest.approx(0.12)


def test_unauthorized_sql_is_masked() -> None:
    item = serialize_query(BASE_ROW, sql_visible=False)
    assert item["queryId"] == "42"
    assert item["sqlVisible"] is False
    assert "orders" not in item["sql"]
    assert item["sql"].startswith("SELECT")
    assert can_view_sql("viewer") is False
    assert can_view_sql("analyst") is True


def test_query_rows_per_call_is_real_and_p95_is_not_fabricated() -> None:
    item = serialize_query({**BASE_ROW, "rows": 250, "rows_per_call": 2.5}, sql_visible=True)
    assert item["rows"] == 250
    assert item["rowsPerCall"] == 2.5
    assert item["p95ExecTimeMs"] is None
    assert item["durationDistribution"]["available"] is False
    assert "p95" in item["durationDistribution"]["reason"]


def test_query_temporal_reliability_is_serialized_without_fabricating_history() -> None:
    item = serialize_query(BASE_ROW, sql_visible=True)

    assert item["observedFrom"] == "2026-07-24T12:00:00Z"
    assert item["observedTo"] == "2026-07-25T12:00:00Z"
    assert item["coveragePercent"] == 100.0
    assert item["resetDetected"] is False
    assert item["comparisonReliable"] is True
    assert item["warmingUp"] is False
    assert item["previousPeriodAvailable"] is True
    assert item["previousCalls"] == 80
    assert item["regressionPercent"] == 50.0


def test_query_missing_previous_period_keeps_comparison_values_null() -> None:
    item = serialize_query(
        {
            **BASE_ROW,
            "coverage_percent": 32.5,
            "reset_detected": True,
            "comparison_reliable": False,
            "warming_up": True,
            "previous_period_available": False,
            "previous_calls": None,
            "previous_mean_exec_time_ms": None,
            "regression_percent": None,
        },
        sql_visible=True,
    )

    assert item["coveragePercent"] == 32.5
    assert item["resetDetected"] is True
    assert item["comparisonReliable"] is False
    assert item["warmingUp"] is True
    assert item["previousPeriodAvailable"] is False
    assert item["previousCalls"] is None
    assert item["previousMeanExecTimeMs"] is None
    assert item["regressionPercent"] is None
    assert not any("es doneme" in finding for finding in item["findings"])


def test_query_cpu_telemetry_is_explicit_and_observation_only() -> None:
    item = serialize_query(BASE_ROW, sql_visible=True)

    assert item["cpu"]["capability"] == {
        "available": True,
        "version": "2.3.2",
        "dataAvailable": True,
        "source": "PoWA pg_stat_kcache",
        "coverage": "EXECUTION_ONLY",
        "reason": (
            "CPU user/system ve filesystem I/O degerleri PoWA pg_stat_kcache gecmisinden gelir; "
            "paralel calismada toplam CPU suresi duvar saatini asabilir."
        ),
    }
    assert item["cpu"]["totalTimeMs"] == 800.0
    assert item["cpu"]["filesystemReadsBytes"] == 4096
    assert item["cpu"]["scoreIncluded"] is False


def test_query_cpu_capability_does_not_turn_missing_data_into_zero() -> None:
    item = serialize_query(
        {
            **BASE_ROW,
            "kcache_data_available": False,
            "cpu_user_time_ms": None,
            "cpu_system_time_ms": None,
            "cpu_total_time_ms": None,
            "cpu_percent_of_exec_time": None,
        },
        sql_visible=True,
    )

    assert item["cpu"]["capability"]["available"] is True
    assert item["cpu"]["capability"]["dataAvailable"] is False
    assert item["cpu"]["totalTimeMs"] is None


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


def test_index_contract_never_calls_no_scan_signal_unused() -> None:
    payload = _index_payload(
        {
            "server_id": 1,
            "database_id": 16384,
            "relation_id": 10,
            "index_id": 11,
            "size_bytes": 2_000_000,
            "scans": 0,
            "signal_level": "WARNING",
            "signal": "NO_SCANS_OBSERVED",
            "recommendation": "Bu bir DROP onerisi degildir.",
        }
    )
    response = IndexResponse.model_validate(
        {
            "window": "24h",
            "summary": {
                "indexesObserved": 1,
                "candidateSignals": 1,
                "totalSizeBytes": 2_000_000,
                "noScanSizeBytes": 2_000_000,
            },
            "items": [payload],
            "joinCapability": {
                "available": False,
                "dataAvailable": False,
                "status": "UNAVAILABLE",
                "captureMode": "QUALSTATS_RESET_BOUNDARY",
                "reason": "JOIN snapshotter yapilandirilmamis.",
            },
            "joins": [],
            "candidates": [],
        }
    )
    assert response.items[0].signal == "NO_SCANS_OBSERVED"
    assert "DROP" in response.items[0].recommendation


def test_empty_io_ratios_are_reported_as_unavailable() -> None:
    index_payload = _index_payload(
        {
            "server_id": 1,
            "database_id": 16384,
            "relation_id": 10,
            "index_id": 11,
            "cache_hit_percent": None,
        }
    )
    database_payload = _database_io_payload(
        {
            "server_id": 1,
            "database_id": 16384,
            "cache_hit_percent": None,
        }
    )

    assert index_payload["cacheHitPercent"] is None
    assert database_payload["cacheHitPercent"] is None


def test_cache_ratio_never_claims_exact_hundred_with_physical_reads() -> None:
    ratio = _cache_hit_percent(1_448_474_149, 6)

    assert ratio is not None
    assert 99.99 < ratio < 100
    assert _cache_hit_percent(0, 0) is None


def test_insufficient_index_history_is_not_reported_as_healthy() -> None:
    response = IndexResponse.model_validate(
        {
            "window": "1h",
            "summary": {
                "indexesObserved": 1,
                "candidateSignals": 0,
                "totalSizeBytes": 2_000_000,
                "noScanSizeBytes": 0,
            },
            "items": [
                _index_payload(
                    {
                        "server_id": 1,
                        "database_id": 16384,
                        "relation_id": 10,
                        "index_id": 11,
                        "signal_level": "UNKNOWN",
                        "signal": "INSUFFICIENT_DATA",
                        "recommendation": "Yeterli gozlem suresi yok.",
                    }
                )
            ],
        }
    )

    assert response.items[0].signalLevel == "UNKNOWN"
    assert response.items[0].signal == "INSUFFICIENT_DATA"
    assert response.summary.candidateSignals == 0


def test_predicate_contract_keeps_sampled_semantics_and_never_emits_ddl() -> None:
    payload = _predicate_payload(
        {
            "server_id": 1,
            "database_id": 16384,
            "query_id": -42,
            "qual_id": 99,
            "relation_id": 10,
            "schema_name": "public",
            "table_name": "orders",
            "column_names": ["status"],
            "operator_oids": [98],
            "eval_type": "FILTER",
            "occurrences": 12,
            "rows_processed": 1000,
            "rows_filtered": 750,
            "filter_ratio": 0.75,
            "observed_from": __import__("datetime").datetime(2026, 7, 24, 10, 0),
            "observed_to": __import__("datetime").datetime(2026, 7, 24, 11, 0),
            "sample_count": 4,
            "signal": "REVIEW",
            "recommendation": "HypoPG ve EXPLAIN ile dogrulayin.",
        }
    )
    response = PredicateResponse.model_validate(
        {
            "window": "24h",
            "queryId": "-42",
            "capability": {
                "available": True,
                "version": "2.1.4",
                "dataAvailable": True,
                "coverage": "WHERE_FILTER_ONLY",
                "joinsAvailable": False,
                "ddlGenerated": False,
                "reason": "Yalniz WHERE/filter gecmisi.",
            },
            "items": [payload],
            "joinCapability": {
                "available": False,
                "dataAvailable": False,
                "status": "UNAVAILABLE",
                "captureMode": "QUALSTATS_RESET_BOUNDARY",
                "reason": "JOIN snapshotter yapilandirilmamis.",
            },
            "joins": [],
            "candidates": [],
        }
    )

    assert response.items[0].queryId == "-42"
    assert response.items[0].occurrences == 12
    assert response.items[0].rowsProcessed == 1000
    assert response.items[0].rowsFiltered == 750
    assert response.capability.coverage == "WHERE_FILTER_ONLY"
    assert response.capability.joinsAvailable is False
    assert response.capability.ddlGenerated is False


@pytest.mark.asyncio
async def test_predicate_route_exposes_where_only_capability(monkeypatch: pytest.MonkeyPatch) -> None:
    observed = __import__("datetime").datetime(2026, 7, 24, 11, 0)

    async def predicate_evidence(**kwargs: object) -> tuple[list[dict[str, object]], dict[str, object]]:
        assert kwargs == {"window": "1h", "server_id": 1, "database_id": 16384, "query_id": -42}
        return [
            {
                "server_id": 1,
                "database_id": 16384,
                "query_id": -42,
                "qual_id": 99,
                "relation_id": 10,
                "schema_name": "public",
                "table_name": "orders",
                "column_names": ["status"],
                "operator_oids": [98],
                "eval_type": "FILTER",
                "occurrences": 12,
                "rows_processed": 1000,
                "rows_filtered": 750,
                "filter_ratio": 0.75,
                "observed_from": observed,
                "observed_to": observed,
                "sample_count": 4,
                "signal": "REVIEW",
                "recommendation": "Planla dogrulayin.",
            }
        ], {"available": True, "version": "2.1.4"}

    async def join_evidence(**kwargs: object) -> tuple[list[dict[str, object]], dict[str, object]]:
        assert kwargs == {"window": "1h", "server_id": 1, "database_id": 16384, "query_id": -42}
        return [], {
            "available": False,
            "data_available": False,
            "status": "UNAVAILABLE",
            "capture_mode": "QUALSTATS_RESET_BOUNDARY",
            "reason": "JOIN snapshotter yapilandirilmamis.",
        }

    async def composite_candidates(**kwargs: object) -> list[dict[str, object]]:
        assert kwargs == {"window": "1h", "server_id": 1, "database_id": 16384, "query_id": -42}
        return []

    monkeypatch.setattr(repository, "predicate_evidence", predicate_evidence)
    monkeypatch.setattr(repository, "join_evidence", join_evidence)
    monkeypatch.setattr(repository, "composite_candidates", composite_candidates)

    result = await query_predicates(query_id=-42, window="1h", server_id=1, database_id=16384)

    assert result["queryId"] == "-42"
    assert result["capability"]["dataAvailable"] is True
    assert result["capability"]["joinsAvailable"] is False
    assert result["capability"]["ddlGenerated"] is False
    assert "statement cagri sayisi degildir" in result["capability"]["reason"]


@pytest.mark.asyncio
async def test_overview_cards_use_unpaginated_aggregate(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    async def query_rows(**kwargs: object) -> tuple[list[dict[str, object]], int]:
        captured.update(kwargs)
        return [BASE_ROW], 999

    async def overview_summary(*, window: str) -> dict[str, object]:
        assert window == "24h"
        return {
            "total_db_time_ms": 987654.0,
            "tracked_queries": 999,
            "critical_queries": 321,
            "regressions": 123,
        }

    async def collector_health() -> list[dict[str, object]]:
        return []

    async def trend(**kwargs: object) -> list[dict[str, object]]:
        return []

    monkeypatch.setattr(repository, "query_rows", query_rows)
    monkeypatch.setattr(repository, "overview_summary", overview_summary)
    monkeypatch.setattr(repository, "collector_health", collector_health)
    monkeypatch.setattr(repository, "trend", trend)

    result = await overview(role="analyst", window="24h")

    assert captured["page_size"] == 10
    assert result["cards"]["trackedQueries"] == 999
    assert result["cards"]["criticalQueries"] == 321
    assert result["cards"]["totalDbTimeMs"] == 987654.0


@pytest.mark.asyncio
async def test_queries_echoes_effective_page_size(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    async def query_rows(**kwargs: object) -> tuple[list[dict[str, object]], int]:
        captured.update(kwargs)
        return [], 0

    monkeypatch.setattr(repository, "query_rows", query_rows)
    monkeypatch.setattr(router_module.settings, "max_query_page_size", 2)

    result = await queries(
        role="analyst",
        window="24h",
        page=1,
        page_size=50,
        search=None,
        priority=None,
        server_id=None,
        database_id=None,
        min_calls=0,
        min_duration_ms=0,
        sort_by="impact",
    )

    assert captured["page_size"] == 2
    assert result["pageSize"] == 2


@pytest.mark.asyncio
async def test_query_detail_keeps_unreliable_comparison_null(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    row = {
        **BASE_ROW,
        "reset_detected": True,
        "comparison_reliable": False,
        "warming_up": False,
        "previous_period_available": False,
        "previous_calls": None,
        "previous_mean_exec_time_ms": None,
        "regression_percent": None,
    }

    async def query_by_id(**_: object) -> dict[str, object]:
        return row

    async def trend(**_: object) -> list[dict[str, object]]:
        return []

    monkeypatch.setattr(repository, "query_by_id", query_by_id)
    monkeypatch.setattr(repository, "trend", trend)

    result = await query_detail(
        query_id=42,
        role="analyst",
        window="24h",
        server_id=1,
        database_id=16384,
    )

    assert result["comparisonReliable"] is False
    assert result["regressionPercent"] is None
    assert result["comparison"] == {
        "currentMeanMs": 12.0,
        "previousMeanMs": None,
        "regressionPercent": None,
        "currentCalls": 100,
        "previousCalls": None,
    }


@pytest.mark.asyncio
async def test_empty_io_route_keeps_reset_limitations_and_null_ratio(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def io_rows(**_: object) -> tuple[list[dict[str, object]], list[dict[str, object]], list[dict[str, object]]]:
        return [], [], []

    monkeypatch.setattr(repository, "io_telemetry", io_rows)

    result = await io_telemetry(window="24h", server_id=None, database_id=None)

    assert result["summary"]["cacheHitPercent"] is None
    limitation = next(item for item in result["capabilities"] if item["key"] == "checkpointAndBgwriter")
    assert limitation["resetEpochAware"] is False
    assert limitation["limitation"]
