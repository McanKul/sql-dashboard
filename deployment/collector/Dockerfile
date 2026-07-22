FROM python:3.12-slim

ARG COLLECTOR_VERSION=1.3.2
ARG COLLECTOR_WHEEL_SHA256=beb827c74f1b21427e6d0be3a43c033cd027b4495a0ab7980aaf8d8d3f2c094f

LABEL org.opencontainers.image.title="PoWA Collector"
LABEL org.opencontainers.image.version="${COLLECTOR_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/powa-team/powa-collector"

RUN set -eux; \
    python -m pip install --no-cache-dir "psycopg2-binary==2.9.10"; \
    python -m pip install --no-cache-dir --no-deps \
      "https://files.pythonhosted.org/packages/2c/1f/6632aba3a453499f131e599b2eabac3588956c44f1d51a9229763a1d32dd/powa_collector-${COLLECTOR_VERSION}-py3-none-any.whl#sha256=${COLLECTOR_WHEEL_SHA256}"

COPY deployment/collector/entrypoint.sh /usr/local/bin/advisor-collector-entrypoint
RUN chmod 0755 /usr/local/bin/advisor-collector-entrypoint

ENTRYPOINT ["advisor-collector-entrypoint"]
CMD ["powa-collector.py"]
