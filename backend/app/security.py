from __future__ import annotations

from fastapi import Header, HTTPException, status


AUTHORIZED_SQL_ROLES = frozenset({"analyst", "admin"})


def normalize_role(role: str | None) -> str:
    return (role or "viewer").strip().lower()


def can_view_sql(role: str | None) -> bool:
    return normalize_role(role) in AUTHORIZED_SQL_ROLES


def mask_sql(sql: str) -> str:
    verb = (sql.strip().split(maxsplit=1) or ["SQL"])[0].upper()
    return f"{verb} /* tam SQL metni icin analyst yetkisi gerekli */"


async def request_role(x_advisor_role: str | None = Header(default=None)) -> str:
    return normalize_role(x_advisor_role)


def require_admin(role: str) -> None:
    if role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Bu islem admin rolu gerektirir.",
        )

