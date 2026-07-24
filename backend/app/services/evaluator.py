from __future__ import annotations

import asyncio
import json
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from app.config import get_settings
from app.schemas import IndexAdvice, InternalIndexEvaluationRequest


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
