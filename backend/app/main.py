from __future__ import annotations

from contextlib import asynccontextmanager
import logging

import structlog
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from starlette.responses import Response

from app.api.router import router
from app.config import get_settings
from app.db import close_pool, open_pool


settings = get_settings()
structlog.configure(
    wrapper_class=structlog.make_filtering_bound_logger(
        logging.getLevelNamesMapping().get(settings.log_level.upper(), logging.INFO)
    ),
)
logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(_: FastAPI):
    await open_pool()
    logger.info("api_started", repository_only=True)
    try:
        yield
    finally:
        await close_pool()
        logger.info("api_stopped")


app = FastAPI(
    title="PostgreSQL Sorgu Performansi ve Oneri Motoru",
    version="1.0.0-iteration-2.2",
    description=(
        "PoWA repository uzerinden sorgu analizi ve ayri salt-okunur evaluator ile "
        "istege bagli HypoPG plan dogrulamasi."
    ),
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PATCH", "OPTIONS"],
    allow_headers=["Content-Type", "X-Advisor-Role", "X-Advisor-Actor"],
)

app.include_router(router)


@app.get("/", include_in_schema=False)
async def root() -> dict[str, str]:
    return {"name": app.title, "docs": "/docs", "health": "/api/v1/health"}


@app.get("/metrics", include_in_schema=False)
async def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
