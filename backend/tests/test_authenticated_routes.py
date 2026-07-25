from __future__ import annotations

import hashlib
from types import SimpleNamespace
from typing import Any

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

import app.security as security
from app.api.router import router
from app.config import AuthPrincipalConfig
from app.repositories.powa import repository


ADMIN_TOKEN = f"adv_pat_v1_{'E' * 43}"
ANNOTATOR_TOKEN = f"adv_pat_v1_{'F' * 43}"
ANALYST_TOKEN = f"adv_pat_v1_{'G' * 43}"


def _config(credential_id: str, subject: str, token: str, roles: list[str]):
    return AuthPrincipalConfig.model_validate(
        {
            "credential_id": credential_id,
            "subject": subject,
            "token_sha256": hashlib.sha256(token.encode("ascii")).hexdigest(),
            "roles": roles,
        }
    )


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(
        security,
        "get_settings",
        lambda: SimpleNamespace(
            advisor_auth_principals=[
                _config("admin", "user:admin", ADMIN_TOKEN, ["admin"]),
                _config("reviewer", "user:reviewer", ANNOTATOR_TOKEN, ["annotator"]),
                _config("analyst", "user:analyst", ANALYST_TOKEN, ["analyst"]),
            ]
        ),
    )
    application = FastAPI()
    application.include_router(router)
    return TestClient(application)


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_annotation_route_rejects_legacy_identity_and_uses_bearer_subject(
    client: TestClient,
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
    url = "/api/v1/queries/42/annotation?serverId=1&databaseId=16384"
    body = {"status": "IN_REVIEW", "note": "Kontrol"}

    legacy = client.patch(
        url,
        json=body,
        headers={
            "X-Advisor-Role": "admin",
            "X-Advisor-Admin-Token": "legacy-secret",
            "X-Advisor-Actor": "spoofed-user",
        },
    )
    assert legacy.status_code == 401
    assert legacy.headers["www-authenticate"] == "Bearer"

    analyst = client.patch(url, json=body, headers=_bearer(ANALYST_TOKEN))
    assert analyst.status_code == 403

    spoofed_body = client.patch(
        url,
        json={**body, "updatedBy": "spoofed-user"},
        headers=_bearer(ANNOTATOR_TOKEN),
    )
    assert spoofed_body.status_code == 422

    response = client.patch(url, json=body, headers=_bearer(ANNOTATOR_TOKEN))
    assert response.status_code == 200
    assert response.json()["updatedBy"] == "user:reviewer"
    assert captured["actor"] == "user:reviewer"


def test_csv_route_requires_admin_bearer_and_audits_backend_subject(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[tuple[str, str]] = []

    async def audit(
        *, actor: str, phase: str, details: dict[str, Any]
    ) -> None:
        events.append((phase, actor))

    async def rows(**_: Any):
        yield [
            {
                "server_id": 1,
                "database_id": 16_384,
                "query_id": 42,
                "sql_text": "SELECT 42",
            }
        ]

    monkeypatch.setattr(repository, "record_query_export_audit", audit)
    monkeypatch.setattr(repository, "stream_query_rows", rows)
    url = "/api/v1/export/queries.csv?window=24h"

    assert client.get(url, headers={"X-Advisor-Role": "admin"}).status_code == 401
    assert client.get(url, headers=_bearer(ANNOTATOR_TOKEN)).status_code == 403

    response = client.get(url, headers=_bearer(ADMIN_TOKEN))
    assert response.status_code == 200
    assert len(response.text.splitlines()) == 2
    assert events == [("REQUESTED", "user:admin"), ("COMPLETED", "user:admin")]


def test_runtime_route_rejects_legacy_admin_headers_before_repository_access(
    client: TestClient,
) -> None:
    response = client.post(
        "/api/v1/queries/42/runtime-index-validations?window=24h",
        json={
            "serverId": 1,
            "databaseId": 16_384,
            "candidateId": "d3cc4474-0303-4a6f-b26f-82ad6d4e58a7",
        },
        headers={
            "X-Advisor-Role": "admin",
            "X-Advisor-Admin-Token": "legacy-secret",
        },
    )

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_openapi_publishes_bearer_security_scheme(client: TestClient) -> None:
    schema = client.get("/openapi.json").json()

    assert schema["components"]["securitySchemes"]["AdvisorBearer"] == {
        "type": "http",
        "scheme": "bearer",
        "bearerFormat": "adv_pat_v1_<32-byte-base64url>",
    }
    annotation = schema["paths"]["/api/v1/queries/{query_id}/annotation"]["patch"]
    export = schema["paths"]["/api/v1/export/queries.csv"]["get"]
    assert {"AdvisorBearer": []} in annotation["security"]
    assert {"AdvisorBearer": []} in export["security"]
