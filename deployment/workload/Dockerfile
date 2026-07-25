FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN python -m pip install --no-cache-dir "psycopg[binary]==3.2.9"
COPY workload.py /app/workload.py
COPY test_workload.py /app/test_workload.py
WORKDIR /app
USER nobody
CMD ["python", "workload.py"]
