from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
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


@lru_cache
def get_settings() -> Settings:
    return Settings()

