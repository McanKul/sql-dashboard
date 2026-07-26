from __future__ import annotations

import asyncio
from http.client import HTTPException as HTTPClientException, IncompleteRead
import json
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from app.config import get_settings
from app.schemas import (
    IndexAdvice,
    InternalIndexEvaluationRequest,
    InternalQueryExplainAnalyzeRequest,
    QueryExplainAnalyzeResult,
)


def unavailable_advice(reason_code: str, message: str) -> dict[str, object]:
    return {
        "status": "UNAVAILABLE",
        "reasonCode": reason_code,
        "message": message,
        "candidate": None,
        "validation": None,
        "confidence": None,
        "ddlExecuted": False,
    }


def _post_evaluation(payload: InternalIndexEvaluationRequest) -> dict[str, object]:
    settings = get_settings()
    if not settings.evaluator_url:
        return unavailable_advice(
            "EVALUATOR_NOT_CONFIGURED",
            "HypoPG evaluator bu kurulumda yapilandirilmamis.",
        )

    body = json.dumps(payload.model_dump(mode="json"), ensure_ascii=False).encode("utf-8")
    request = Request(
        f"{settings.evaluator_url.rstrip('/')}/internal/v1/index-evaluations",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Evaluator-Token": settings.evaluator_token,
        },
    )
    try:
        with urlopen(request, timeout=settings.evaluator_timeout_seconds) as response:
            result = json.loads(response.read().decode("utf-8"))
        return IndexAdvice.model_validate(result).model_dump(mode="python")
    except (HTTPError, URLError, TimeoutError, ValueError, json.JSONDecodeError):
        return unavailable_advice(
            "EVALUATOR_UNREACHABLE",
            "HypoPG evaluator su anda yanit vermiyor; WHERE kaniti kullanilabilir, plan dogrulamasi kullanilamaz.",
        )


async def evaluate_index_candidate(
    payload: InternalIndexEvaluationRequest,
) -> dict[str, object]:
    return await asyncio.to_thread(_post_evaluation, payload)


def unavailable_source_explain(
    query_id: str,
    reason_code: str,
    message: str,
) -> dict[str, object]:
    return {
        "status": "UNAVAILABLE",
        "reasonCode": reason_code,
        "message": message,
        "queryId": query_id,
        "validation": None,
        "executionTarget": "SOURCE_DATABASE",
        # Once an HTTP request fails, the API cannot prove whether the source
        # worker started or completed its rollback.  Null preserves that
        # uncertainty instead of presenting false safety assurance.
        "sourceExecuted": None,
        "sourceDdlExecuted": False,
        "transactionRolledBack": None,
    }


def _post_source_query_explain(
    payload: InternalQueryExplainAnalyzeRequest,
) -> dict[str, object]:
    settings = get_settings()
    if not settings.evaluator_url:
        return unavailable_source_explain(
            payload.queryId,
            "SOURCE_EVALUATOR_NOT_CONFIGURED",
            "Ana veritabani evaluator'u bu kurulumda yapilandirilmamis.",
        )

    try:
        body = json.dumps(payload.model_dump(mode="json"), ensure_ascii=False).encode("utf-8")
        request = Request(
            f"{settings.evaluator_url.rstrip('/')}/internal/v1/query-explain-analyze",
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-Evaluator-Token": settings.evaluator_token,
            },
        )
        with urlopen(
            request,
            timeout=settings.source_explain_timeout_seconds,
        ) as response:
            result = json.loads(response.read().decode("utf-8"))
        validated = QueryExplainAnalyzeResult.model_validate(result)
        if validated.queryId != payload.queryId:
            raise ValueError("source evaluator query identity does not match request")
        if (
            validated.status == "RUNTIME_VALIDATED"
            and (
                validated.validation is None
                or validated.validation.databaseId != payload.databaseId
            )
        ):
            raise ValueError("source evaluator database identity does not match request")
        return validated.model_dump(mode="python")
    except (
        HTTPError,
        URLError,
        HTTPClientException,
        IncompleteRead,
        TimeoutError,
        OSError,
        ValueError,
        json.JSONDecodeError,
    ):
        return unavailable_source_explain(
            payload.queryId,
            "SOURCE_EVALUATOR_UNREACHABLE",
            "Kaynak evaluator yanit vermedi; sorgunun calisma ve rollback durumu dogrulanamadi.",
        )


async def explain_query_on_source(
    payload: InternalQueryExplainAnalyzeRequest,
) -> dict[str, object]:
    return await asyncio.to_thread(_post_source_query_explain, payload)
