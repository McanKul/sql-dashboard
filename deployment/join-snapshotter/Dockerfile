FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    JOIN_HEALTH_MAX_AGE_SECONDS=60

WORKDIR /app

RUN python -m pip install --no-cache-dir "psycopg[binary]==3.2.9" \
    && addgroup --system advisor \
    && adduser --system --ingroup advisor advisor

COPY --chown=advisor:advisor deployment/join-snapshotter/snapshotter.py /app/snapshotter.py

USER advisor

HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
    CMD ["python", "/app/snapshotter.py", "--healthcheck"]

CMD ["python", "/app/snapshotter.py"]
