from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


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
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = Field(
        default="postgresql://advisor_api:advisor_dev_api@localhost:5433/powa_repository"
    )
    default_window: str = "24h"
    max_query_page_size: int = 200
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

    @field_validator("database_url")
    @classmethod
    def repository_only(cls, value: str) -> str:
        lowered = value.lower()
        if "5432" in lowered or "source-db" in lowered or "/appdb" in lowered:
            raise ValueError("API DATABASE_URL yalnizca repository instance'ini gostermelidir")
        return value

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


@lru_cache
def get_settings() -> Settings:
    return Settings()
