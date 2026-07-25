from __future__ import annotations

import hashlib
import json
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import ValidationError

import app.security as security
from app.config import AuthPrincipalConfig, Settings


ADMIN_TOKEN = f"adv_pat_v1_{'A' * 43}"
ANNOTATOR_TOKEN = f"adv_pat_v1_{'B' * 43}"
ANALYST_TOKEN = f"adv_pat_v1_{'C' * 43}"
UNKNOWN_TOKEN = f"adv_pat_v1_{'D' * 43}"


def _principal_config(
    *,
    credential_id: str,
    subject: str,
    token: str,
    roles: list[str],
) -> AuthPrincipalConfig:
    return AuthPrincipalConfig.model_validate(
        {
            "credential_id": credential_id,
            "subject": subject,
            "token_sha256": hashlib.sha256(token.encode("ascii")).hexdigest(),
            "roles": roles,
        }
    )


@pytest.fixture
def principal_registry(monkeypatch: pytest.MonkeyPatch) -> None:
    principals = [
        _principal_config(
            credential_id="admin-cli",
            subject="user:admin",
            token=ADMIN_TOKEN,
            roles=["analyst", "annotator", "admin"],
        ),
        _principal_config(
            credential_id="annotation-cli",
            subject="user:reviewer",
            token=ANNOTATOR_TOKEN,
            roles=["annotator"],
        ),
        _principal_config(
            credential_id="analyst-cli",
            subject="user:analyst",
            token=ANALYST_TOKEN,
            roles=["analyst"],
        ),
    ]
    monkeypatch.setattr(
        security,
        "get_settings",
        lambda: SimpleNamespace(advisor_auth_principals=principals),
    )


def _credentials(token: str, scheme: str = "Bearer") -> HTTPAuthorizationCredentials:
    return HTTPAuthorizationCredentials(scheme=scheme, credentials=token)


def test_valid_bearer_resolves_stable_server_side_subject(
    principal_registry: None,
) -> None:
    principal = security.authenticate_bearer(f"Bearer {ANNOTATOR_TOKEN}")

    assert principal.credential_id == "annotation-cli"
    assert principal.subject == "user:reviewer"
    assert principal.roles == frozenset({"annotator"})


@pytest.mark.parametrize(
    "authorization",
    [
        None,
        "",
        f"Basic {ADMIN_TOKEN}",
        "Bearer malformed",
        f"Bearer  {ADMIN_TOKEN}",
        f"Bearer {UNKNOWN_TOKEN}",
    ],
)
def test_missing_malformed_or_unknown_bearer_is_401(
    authorization: str | None,
    principal_registry: None,
) -> None:
    with pytest.raises(HTTPException) as captured:
        security.authenticate_bearer(authorization)

    assert captured.value.status_code == 401
    assert captured.value.headers == {"WWW-Authenticate": "Bearer"}


@pytest.mark.asyncio
async def test_read_demo_header_never_elevates_to_admin(
    principal_registry: None,
) -> None:
    assert await security.request_role("analyst", None) == "analyst"
    assert await security.request_role("admin", None) == "viewer"


@pytest.mark.asyncio
async def test_authenticated_roles_control_read_visibility(
    principal_registry: None,
) -> None:
    assert await security.request_role(None, _credentials(ADMIN_TOKEN)) == "admin"
    assert await security.request_role(None, _credentials(ANALYST_TOKEN)) == "analyst"
    assert await security.request_role(None, _credentials(ANNOTATOR_TOKEN)) == "viewer"


@pytest.mark.asyncio
async def test_annotator_and_admin_can_mutate_but_analyst_cannot(
    principal_registry: None,
) -> None:
    annotator = await security.request_principal(_credentials(ANNOTATOR_TOKEN))
    admin = await security.request_principal(_credentials(ADMIN_TOKEN))
    analyst = await security.request_principal(_credentials(ANALYST_TOKEN))

    assert await security.request_annotator_principal(annotator) == annotator
    assert await security.request_annotator_principal(admin) == admin
    with pytest.raises(HTTPException) as captured:
        await security.request_annotator_principal(analyst)
    assert captured.value.status_code == 403


@pytest.mark.asyncio
async def test_only_admin_can_export_or_start_runtime_validation(
    principal_registry: None,
) -> None:
    admin = await security.request_principal(_credentials(ADMIN_TOKEN))
    annotator = await security.request_principal(_credentials(ANNOTATOR_TOKEN))

    assert await security.request_admin_principal(admin) == admin
    with pytest.raises(HTTPException) as captured:
        await security.request_admin_principal(annotator)
    assert captured.value.status_code == 403


def test_empty_principal_registry_is_fail_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        security,
        "get_settings",
        lambda: SimpleNamespace(advisor_auth_principals=[]),
    )

    with pytest.raises(HTTPException) as captured:
        security.authenticate_bearer(f"Bearer {ADMIN_TOKEN}")
    assert captured.value.status_code == 401


def test_principal_config_rejects_unknown_fields_roles_and_ambiguous_subjects() -> None:
    valid = {
        "credential_id": "reviewer-cli",
        "subject": "user:reviewer",
        "token_sha256": "a" * 64,
        "roles": ["annotator"],
    }
    with pytest.raises(ValidationError):
        AuthPrincipalConfig.model_validate({**valid, "unexpected": True})
    with pytest.raises(ValidationError):
        AuthPrincipalConfig.model_validate({**valid, "roles": ["owner"]})
    with pytest.raises(ValidationError):
        AuthPrincipalConfig.model_validate({**valid, "subject": " user:reviewer"})


def test_settings_reject_duplicate_credential_ids_and_token_hashes() -> None:
    first = {
        "credential_id": "first",
        "subject": "user:first",
        "token_sha256": "a" * 64,
        "roles": ["annotator"],
    }
    duplicate_id = {**first, "subject": "user:second", "token_sha256": "b" * 64}
    duplicate_hash = {**first, "credential_id": "second", "subject": "user:second"}

    with pytest.raises(ValidationError):
        Settings(advisor_auth_principals=[first, duplicate_id])
    with pytest.raises(ValidationError):
        Settings(advisor_auth_principals=[first, duplicate_hash])


def test_principal_registry_parses_from_environment_json(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(
        "ADVISOR_AUTH_PRINCIPALS",
        json.dumps(
            [
                {
                    "credential_id": "environment-cli",
                    "subject": "user:environment",
                    "token_sha256": "e" * 64,
                    "roles": ["analyst", "annotator"],
                }
            ]
        ),
    )

    settings = Settings()

    assert settings.advisor_auth_principals[0].subject == "user:environment"
    assert settings.advisor_auth_principals[0].roles == frozenset(
        {"analyst", "annotator"}
    )
