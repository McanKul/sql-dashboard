from __future__ import annotations

import asyncio
import json
from http.client import HTTPException as HTTPClientException, IncompleteRead
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from app.config import get_settings


def _get_health(url: str | None) -> dict[str, Any] | None:
    if not url:
        return None
    request = Request(f"{url.rstrip('/')}/health", method="GET")
    try:
        with urlopen(request, timeout=2.0) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return payload if isinstance(payload, dict) else None
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
        return None


async def evaluator_health() -> dict[str, dict[str, Any] | None]:
    settings = get_settings()
    evaluator, clone = await asyncio.gather(
        asyncio.to_thread(_get_health, settings.evaluator_url),
        asyncio.to_thread(_get_health, settings.clone_evaluator_url),
    )
    return {"evaluator": evaluator, "clone": clone}
