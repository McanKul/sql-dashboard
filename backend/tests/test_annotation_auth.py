from __future__ import annotations

from typing import Any

import pytest
from pydantic import ValidationError

import app.repositories.powa as powa_module
from app.api.router import update_annotation
from app.repositories.powa import repository
from app.schemas import AnnotationUpdate
from app.security import RequestPrincipal


ANNOTATOR = RequestPrincipal(
    credential_id="reviewer-cli",
    subject="user:reviewer",
    roles=frozenset({"annotator"}),
)


class _Cursor:
    def __init__(self) -> None:
        self.query = ""
        self.params: tuple[Any, ...] = ()

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    async def execute(self, query: str, params: tuple[Any, ...]) -> None:
        self.query = query
        self.params = params

    async def fetchone(self) -> dict[str, Any]:
        return {
            "server_id": 1,
            "database_id": 16_384,
            "query_id": 42,
            "status": "IN_REVIEW",
            "note": "Kontrol",
            "updated_by": "user:reviewer",
            "updated_at": "2026-07-25T20:00:00Z",
        }


class _Connection:
    def __init__(self, cursor: _Cursor) -> None:
        self._cursor = cursor

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    def cursor(self) -> _Cursor:
        return self._cursor


class _Pool:
    def __init__(self, cursor: _Cursor) -> None:
        self._connection = _Connection(cursor)

    def connection(self) -> _Connection:
        return self._connection


def test_annotation_request_rejects_client_supplied_actor() -> None:
    with pytest.raises(ValidationError) as captured:
        AnnotationUpdate.model_validate(
            {
                "status": "IN_REVIEW",
                "note": "Kontrol ediliyor",
                "updatedBy": "spoofed-user",
            }
        )

    assert any(error["type"] == "extra_forbidden" for error in captured.value.errors())


@pytest.mark.asyncio
async def test_repository_annotation_uses_restricted_database_function(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = _Cursor()
    monkeypatch.setattr(powa_module, "pool", _Pool(cursor))

    row = await repository.annotate(
        server_id=1,
        database_id=16_384,
        query_id=42,
        status="IN_REVIEW",
        note="Kontrol",
        actor="user:reviewer",
    )

    assert "advisor.upsert_query_annotation" in cursor.query
    assert "INSERT INTO advisor.query_annotations" not in cursor.query
    assert "set_config" not in cursor.query
    assert cursor.params == (1, 16_384, 42, "IN_REVIEW", "Kontrol", "user:reviewer")
    assert row["updated_by"] == "user:reviewer"


@pytest.mark.asyncio
async def test_annotation_actor_always_comes_from_authenticated_principal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}

    async def annotate(**kwargs: Any) -> dict[str, Any]:
        captured.update(kwargs)
        return {
            "server_id": kwargs["server_id"],
            "database_id": kwargs["database_id"],
            "query_id": kwargs["query_id"],
            "status": kwargs["status"],
            "note": kwargs["note"],
            "updated_by": kwargs["actor"],
            "updated_at": "2026-07-25T20:00:00Z",
        }

    monkeypatch.setattr(repository, "annotate", annotate)

    response = await update_annotation(
        query_id=42,
        payload=AnnotationUpdate(status="in_review", note="Kontrol ediliyor"),
        principal=ANNOTATOR,
        server_id=1,
        database_id=16_384,
    )

    assert captured == {
        "server_id": 1,
        "database_id": 16_384,
        "query_id": 42,
        "status": "IN_REVIEW",
        "note": "Kontrol ediliyor",
        "actor": "user:reviewer",
    }
    assert response["updatedBy"] == "user:reviewer"
