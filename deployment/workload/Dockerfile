FROM python:3.12-slim

RUN python -m pip install --no-cache-dir "psycopg[binary]==3.2.9"
COPY workload.py /app/workload.py
WORKDIR /app
USER nobody
CMD ["python", "workload.py"]

