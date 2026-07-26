from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from psycopg.conninfo import conninfo_to_dict

from app.conninfo import resolve_conninfo


WINDOW_INTERVALS: dict[str, str] = {
    "1h": "1 hour",
    "24h": "24 hours",
    "7d": "7 days",
    "30d": "30 days",
}

WINDOW_BUCKETS: dict[str, str] = {
    "1h": "5 minutes",
    "24h": "1 hour",
    "7d": "6 hours",
    "30d": "1 day",
}


PrincipalRole = Literal["analyst", "annotator", "admin"]


class AuthPrincipalConfig(BaseModel):
    """Server-side credential registry entry.

    Only a SHA-256 digest is configured. The bearer token itself stays in the
    caller's secret store and is never placed in the API environment.
    """

    model_config = ConfigDict(extra="forbid", frozen=True)

    credential_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")
    subject: str = Field(min_length=1, max_length=120)
    token_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    roles: frozenset[PrincipalRole] = Field(min_length=1)

    @field_validator("subject")
    @classmethod
    def safe_subject(cls, value: str) -> str:
        if (
            value != value.strip()
            or not value
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
        ):
            raise ValueError("subject bos olamaz veya kontrol karakteri iceremez")
        return value


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", extra="ignore", hide_input_in_errors=True
    )

    # DATABASE_URL remains an explicit backwards-compatible override. Normal
    # deployments pass separate fields so reserved password characters never
    # need URI escaping.
    database_url: str | None = None
    database_host: str = "localhost"
    database_port: int = Field(default=5433, ge=1, le=65_535)
    database_name: str = "powa_repository"
    database_user: str = "advisor_api"
    database_password: str = "advisor_dev_api"
    database_sslmode: str | None = None
    default_window: str = "24h"
    max_query_page_size: int = 200
    # PoWA's default demo collector cadence is 60 seconds.  Keep one complete
    # metrics snapshot per supported window fresh for one cadence, then serve
    # bounded stale data while one refresh protects the repository from a
    # thundering herd of expensive metrics scans.
    query_list_cache_fresh_seconds: float = Field(default=60.0, ge=0, le=3_600)
    query_list_cache_stale_seconds: float = Field(default=300.0, gt=0, le=86_400)
    query_list_cache_max_entries: int = Field(default=4, ge=1, le=4)
    query_list_cache_max_rows: int = Field(default=100_000, ge=1, le=1_000_000)
    # PostgreSQL's composite-row size is a conservative, deterministic input
    # budget for each cached window.  The API container also has a hard memory
    # envelope because Python object overhead is necessarily larger.
    query_list_cache_max_bytes: int = Field(
        default=64 * 1024 * 1024,
        ge=1024 * 1024,
        le=1024 * 1024 * 1024,
    )
    sql_text_visibility: str = "authorized"
    retention_days: int = 90
    log_level: str = "INFO"
    evaluator_url: str | None = None
    evaluator_token: str = "advisor-dev-evaluator-token"
    evaluator_timeout_seconds: float = Field(default=4.0, gt=0, le=15)
    clone_evaluator_url: str | None = None
    clone_evaluator_token: str = "advisor-dev-clone-evaluator-token"
    clone_evaluator_timeout_seconds: float = Field(default=90.0, gt=0, le=180)
    advisor_auth_principals: list[AuthPrincipalConfig] = Field(default_factory=list)

    @property
    def database_conninfo(self) -> str:
        return resolve_conninfo(
            self.database_url,
            host=self.database_host,
            port=self.database_port,
            dbname=self.database_name,
            user=self.database_user,
            password=self.database_password,
            sslmode=self.database_sslmode,
        )

    @model_validator(mode="after")
    def repository_only(self) -> Settings:
        connection = conninfo_to_dict(self.database_conninfo)
        hosts = {
            host.strip().lower()
            for host in (connection.get("host") or "").split(",")
            if host.strip()
        }
        # Ports and database names are not identities: an external repository
        # may legitimately use PostgreSQL's standard 5432 port and a locally
        # chosen database name.  Reject the reference source host here; the
        # Docker/API health gate then positively requires the advisor
        # repository schema before the service becomes healthy.
        if "source-db" in hosts:
            raise ValueError("API DATABASE_URL yalnizca repository instance'ini gostermelidir")
        return self

    @field_validator("default_window")
    @classmethod
    def known_window(cls, value: str) -> str:
        if value not in WINDOW_INTERVALS:
            raise ValueError(f"default_window sunlardan biri olmali: {', '.join(WINDOW_INTERVALS)}")
        return value

    @model_validator(mode="after")
    def unique_auth_credentials(self) -> Settings:
        credential_ids = [item.credential_id for item in self.advisor_auth_principals]
        token_hashes = [item.token_sha256 for item in self.advisor_auth_principals]
        if len(credential_ids) != len(set(credential_ids)):
            raise ValueError("advisor_auth_principals credential_id degerleri benzersiz olmali")
        if len(token_hashes) != len(set(token_hashes)):
            raise ValueError("advisor_auth_principals token_sha256 degerleri benzersiz olmali")
        return self

    @model_validator(mode="after")
    def valid_query_list_cache_window(self) -> Settings:
        if self.query_list_cache_stale_seconds < self.query_list_cache_fresh_seconds:
            raise ValueError(
                "query_list_cache_stale_seconds fresh suresinden kisa olamaz"
            )
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
