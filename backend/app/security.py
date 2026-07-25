from __future__ import annotations

import secrets

from fastapi import Header, HTTPException, status

from app.config import get_settings


AUTHORIZED_SQL_ROLES = frozenset({"analyst", "admin"})


def normalize_role(role: str | None) -> str:
    return (role or "viewer").strip().lower()


def can_view_sql(role: str | None) -> bool:
    return normalize_role(role) in AUTHORIZED_SQL_ROLES


def mask_sql(sql: str) -> str:
    verb = (sql.strip().split(maxsplit=1) or ["SQL"])[0].upper()
    return f"{verb} /* tam SQL metni icin analyst yetkisi gerekli */"


async def request_role(
    x_advisor_role: str | None = Header(default=None),
    x_advisor_admin_token: str | None = Header(default=None),
) -> str:
    """Resolve the demonstration role without trusting an admin claim alone.

    ``analyst`` remains the local, read-only dashboard role.  Any endpoint that
    requires ``admin`` only receives that role after a server-side secret is
    verified.  The browser deliberately never receives this secret.
    """

    role = normalize_role(x_advisor_role)
    if role != "admin":
        return role

    expected = get_settings().runtime_admin_token
    if (
        expected
        and x_advisor_admin_token
        and secrets.compare_digest(x_advisor_admin_token, expected)
    ):
        return role
    return "viewer"


def require_admin(role: str) -> None:
    if role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Bu islem admin rolu gerektirir.",
        )
