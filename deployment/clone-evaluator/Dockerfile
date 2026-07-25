FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY backend/requirements.txt ./requirements.txt
RUN python -m pip install --no-cache-dir -r requirements.txt

COPY backend/app ./app

RUN addgroup --system clone-evaluator \
    && adduser --system --ingroup clone-evaluator clone-evaluator
USER clone-evaluator

EXPOSE 8020
CMD ["uvicorn", "app.clone_evaluator:app", "--host", "0.0.0.0", "--port", "8020"]
