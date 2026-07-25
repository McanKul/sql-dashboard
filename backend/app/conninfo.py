from __future__ import annotations

from psycopg.conninfo import make_conninfo


def resolve_conninfo(
    override: str | None,
    *,
    host: str,
    port: int,
    dbname: str,
    user: str,
    password: str,
    sslmode: str | None = None,
) -> str:
    """Return validated libpq conninfo without interpolating secrets into a URI."""

    try:
        if override and override.strip():
            return make_conninfo(override)

        parameters: dict[str, str | int] = {
            "host": host,
            "port": port,
            "dbname": dbname,
            "user": user,
            "password": password,
        }
        if sslmode:
            parameters["sslmode"] = sslmode
        return make_conninfo(**parameters)
    except Exception:
        # Settings validators turn ValueError into a concise configuration error.
        # Never include the original exception: libpq may echo secret-bearing input.
        raise ValueError("PostgreSQL connection settings are invalid") from None
