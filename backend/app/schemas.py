from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


ALLOWED_STATUSES = {"NEW", "IN_REVIEW", "COMPLETED", "REJECTED"}


class AnnotationUpdate(BaseModel):
    status: str
    note: str | None = Field(default=None, max_length=4000)
    updated_by: str = Field(alias="updatedBy", min_length=1, max_length=120)

    @field_validator("status")
    @classmethod
    def validate_status(cls, value: str) -> str:
        normalized = value.upper()
        if normalized not in ALLOWED_STATUSES:
            raise ValueError(f"status sunlardan biri olmali: {', '.join(sorted(ALLOWED_STATUSES))}")
        return normalized


class QueryFilters(BaseModel):
    window: str = "24h"
    page: int = Field(default=1, ge=1)
    page_size: int = Field(default=50, ge=1, le=200)

