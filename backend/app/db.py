from __future__ import annotations

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from app.config import get_settings


settings = get_settings()

pool = AsyncConnectionPool(
    conninfo=settings.database_conninfo,
    min_size=1,
    max_size=8,
    open=False,
    kwargs={
        "autocommit": False,
        "row_factory": dict_row,
        "application_name": "postgresql-advisor-api",
    },
)


async def open_pool() -> None:
    await pool.open(wait=True, timeout=20)


async def close_pool() -> None:
    await pool.close()
