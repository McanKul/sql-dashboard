from __future__ import annotations

import asyncio
from http.client import HTTPException as HTTPClientException
import json
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from app.clone_evaluator import (
    CloneIndexEvaluationResult,
    CloneQueryEvaluationResult,
    InternalCloneIndexEvaluationRequest,
    InternalCloneQueryEvaluationRequest,
)
from app.config import get_settings


def unavailable_runtime_validation(candidate_id: str, reason_code: str, message: str) -> dict[str, object]:
    return {
        "status": "UNAVAILABLE",
        "reasonCode": reason_code,
        "message": message,
        "candidateId": candidate_id,
        "validation": None,
        "ddlTarget": "DISPOSABLE_CLONE",
        "sourceDdlExecuted": False,
        "cloneDdlExecuted": False,
        "cloneDestroyed": True,
    }


def _post_runtime_validation(
    payload: InternalCloneIndexEvaluationRequest,
) -> dict[str, object]:
    settings = get_settings()
    if not settings.clone_evaluator_url:
        return unavailable_runtime_validation(
            str(payload.candidate.candidateId),
            "CLONE_EVALUATOR_NOT_CONFIGURED",
            "Disposable clone evaluator bu kurulumda etkin degil; real-validation profilini baslatin.",
        )

    body = json.dumps(payload.model_dump(mode="json"), ensure_ascii=False).encode("utf-8")
    request = Request(
        f"{settings.clone_evaluator_url.rstrip('/')}/internal/v1/runtime-index-validations",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Clone-Evaluator-Token": settings.clone_evaluator_token,
        },
    )
    try:
        with urlopen(
            request,
            timeout=settings.clone_evaluator_timeout_seconds,
        ) as response:
            result = json.loads(response.read().decode("utf-8"))
        return CloneIndexEvaluationResult.model_validate(result).model_dump(mode="python")
    except (HTTPError, URLError, TimeoutError, ValueError, json.JSONDecodeError):
        return unavailable_runtime_validation(
            str(payload.candidate.candidateId),
            "CLONE_EVALUATOR_UNREACHABLE",
            "Disposable clone evaluator yanit vermedi; kaynakta DDL calistirilmadi.",
        )


async def validate_index_on_clone(
    payload: InternalCloneIndexEvaluationRequest,
) -> dict[str, object]:
    return await asyncio.to_thread(_post_runtime_validation, payload)


def unavailable_query_explain(
    query_id: str,
    reason_code: str,
    message: str,
    *,
    clone_destroyed: bool,
) -> dict[str, object]:
    return {
        "status": "UNAVAILABLE",
        "reasonCode": reason_code,
        "message": message,
        "queryId": query_id,
        "validation": None,
        "executionTarget": "DISPOSABLE_CLONE",
        "sourceDdlExecuted": False,
        "cloneDdlExecuted": False,
        "cloneDestroyed": clone_destroyed,
    }


def _post_query_explain(
    payload: InternalCloneQueryEvaluationRequest,
) -> dict[str, object]:
    settings = get_settings()
    if not settings.clone_evaluator_url:
        return unavailable_query_explain(
            payload.queryId,
            "CLONE_EVALUATOR_NOT_CONFIGURED",
            "Disposable clone evaluator bu kurulumda etkin degil; real-validation profilini baslatin.",
            clone_destroyed=True,
        )

    try:
        body = json.dumps(payload.model_dump(mode="json"), ensure_ascii=False).encode("utf-8")
        request = Request(
            f"{settings.clone_evaluator_url.rstrip('/')}/internal/v1/query-explain-analyze",
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-Clone-Evaluator-Token": settings.clone_evaluator_token,
            },
        )
        with urlopen(
            request,
            timeout=settings.clone_evaluator_timeout_seconds,
        ) as response:
            result = json.loads(response.read().decode("utf-8"))
        validated = CloneQueryEvaluationResult.model_validate(result)
        if validated.queryId != payload.queryId:
            raise ValueError("clone evaluator query identity does not match request")
        return validated.model_dump(mode="python")
    except (
        HTTPError,
        URLError,
        HTTPClientException,
        TimeoutError,
        OSError,
        ValueError,
        json.JSONDecodeError,
    ):
        return unavailable_query_explain(
            payload.queryId,
            "CLONE_EVALUATOR_UNREACHABLE",
            "Disposable clone evaluator yanit vermedi; kaynak sorgu calistirilmadi.",
            clone_destroyed=False,
        )


async def explain_query_on_clone(
    payload: InternalCloneQueryEvaluationRequest,
) -> dict[str, object]:
    return await asyncio.to_thread(_post_query_explain, payload)
