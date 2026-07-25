from __future__ import annotations

from dataclasses import dataclass
import hashlib
import re
import secrets
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import PrincipalRole, get_settings


AUTHORIZED_SQL_ROLES = frozenset({"analyst", "admin"})
BEARER_TOKEN_PATTERN = re.compile(r"^adv_pat_v1_[A-Za-z0-9_-]{43}$")
bearer_scheme = HTTPBearer(
    auto_error=False,
    bearerFormat="adv_pat_v1_<32-byte-base64url>",
    scheme_name="AdvisorBearer",
)


@dataclass(frozen=True, slots=True)
class RequestPrincipal:
    credential_id: str
    subject: str
    roles: frozenset[PrincipalRole]


def normalize_role(role: str | None) -> str:
    return (role or "viewer").strip().lower()


def can_view_sql(role: str | None) -> bool:
    return normalize_role(role) in AUTHORIZED_SQL_ROLES


def mask_sql(sql: str) -> str:
    verb = (sql.strip().split(maxsplit=1) or ["SQL"])[0].upper()
    return f"{verb} /* tam SQL metni icin analyst yetkisi gerekli */"


def _authentication_error() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Gecerli Bearer kimligi gerekli.",
        headers={"WWW-Authenticate": "Bearer"},
    )


def authenticate_bearer(authorization: str | None) -> RequestPrincipal:
    if not authorization:
        raise _authentication_error()

    scheme, separator, token = authorization.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not BEARER_TOKEN_PATTERN.fullmatch(token):
        raise _authentication_error()

    supplied_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
    matched = None
    # Compare against every configured digest. Besides keeping the code simple
    # for credential rotation, this avoids exposing which registry entry was
    # closest to the supplied token through early-return timing.
    for configured in get_settings().advisor_auth_principals:
        if secrets.compare_digest(supplied_hash, configured.token_sha256):
            matched = configured

    if matched is None:
        raise _authentication_error()

    return RequestPrincipal(
        credential_id=matched.credential_id,
        subject=matched.subject,
        roles=matched.roles,
    )


async def request_principal(
    credentials: Annotated[
        HTTPAuthorizationCredentials | None,
        Security(bearer_scheme),
    ] = None,
) -> RequestPrincipal:
    authorization = (
        None
        if credentials is None
        else f"{credentials.scheme} {credentials.credentials}"
    )
    return authenticate_bearer(authorization)


async def request_role(
    x_advisor_role: str | None = Header(default=None, alias="X-Advisor-Role"),
    credentials: Annotated[
        HTTPAuthorizationCredentials | None,
        Security(bearer_scheme),
    ] = None,
) -> str:
    """Resolve API capability visibility while keeping the analyst demo explicit.

    An authenticated principal is authoritative. Without a bearer token only
    the existing ``analyst`` demonstration header remains usable for analysis
    endpoints; it can never authorize annotation, CSV export, real runtime
    execution or an audit actor.
    """

    if credentials is not None:
        principal = authenticate_bearer(
            f"{credentials.scheme} {credentials.credentials}"
        )
        if "admin" in principal.roles:
            return "admin"
        if "analyst" in principal.roles:
            return "analyst"
        return "viewer"

    role = normalize_role(x_advisor_role)
    return role if role in {"viewer", "analyst"} else "viewer"


def _require_any_role(
    principal: RequestPrincipal,
    allowed_roles: frozenset[PrincipalRole],
) -> RequestPrincipal:
    if principal.roles.isdisjoint(allowed_roles):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Bu kimligin islem icin gerekli yetkisi yok.",
        )
    return principal


async def request_annotator_principal(
    principal: Annotated[RequestPrincipal, Depends(request_principal)],
) -> RequestPrincipal:
    return _require_any_role(principal, frozenset({"annotator", "admin"}))


async def request_admin_principal(
    principal: Annotated[RequestPrincipal, Depends(request_principal)],
) -> RequestPrincipal:
    return _require_any_role(principal, frozenset({"admin"}))
