from __future__ import annotations

from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

import app.security as security
from app.config import Settings


@pytest.fixture
def runtime_admin_secret(monkeypatch: pytest.MonkeyPatch) -> str:
    token = "test-runtime-admin-token"
    monkeypatch.setattr(
        security,
        "get_settings",
        lambda: SimpleNamespace(runtime_admin_token=token),
    )
    return token


@pytest.mark.asyncio
async def test_admin_header_alone_cannot_elevate(runtime_admin_secret: str) -> None:
    role = await security.request_role("admin", None)

    assert role == "viewer"
    with pytest.raises(HTTPException) as error:
        security.require_admin(role)
    assert error.value.status_code == 403


@pytest.mark.asyncio
async def test_admin_role_requires_matching_server_secret(runtime_admin_secret: str) -> None:
    assert await security.request_role("admin", "wrong-runtime-token") == "viewer"
    assert await security.request_role("admin", runtime_admin_secret) == "admin"


@pytest.mark.asyncio
async def test_read_only_analyst_role_stays_locally_usable(runtime_admin_secret: str) -> None:
    assert await security.request_role("analyst", None) == "analyst"


@pytest.mark.asyncio
async def test_unconfigured_admin_secret_is_fail_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        security,
        "get_settings",
        lambda: SimpleNamespace(runtime_admin_token=None),
    )

    assert await security.request_role("admin", "any-browser-value") == "viewer"


def test_runtime_admin_secret_rejects_short_values() -> None:
    with pytest.raises(ValidationError):
        Settings(runtime_admin_token="too-short")
    with pytest.raises(ValidationError):
        Settings(runtime_admin_token="x               ")

    assert Settings(runtime_admin_token="").runtime_admin_token is None
