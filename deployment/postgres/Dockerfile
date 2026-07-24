FROM postgres:18-trixie

ARG POWA_VERSION=5.2.0
ARG POWA_TAG=REL_5_2_0
ARG POWA_SHA256=098121a1307dc914535713e42555683c506de249ee588d5e66fa81c1c1c20908
ARG PG_QUALSTATS_VERSION=2.1.4
ARG PG_QUALSTATS_TAG=2.1.4
ARG PG_QUALSTATS_SHA256=e5c4d4e32d4b4f4b3b6fdb2c15a8d2e01e07fc922424091539c88283f288020e
ARG HYPOPG_VERSION=1.4.3
ARG HYPOPG_COMMIT=21d5461ad1868434cc47d9aa656d7afc2b24c464
ARG HYPOPG_SHA256=a57c34a0e2752176a1ba3d3b990cffe8ed8d65fccda96052a7f5605c274f554f

LABEL org.opencontainers.image.title="PostgreSQL 18 + PoWA Archivist + pg_qualstats + HypoPG"
LABEL org.opencontainers.image.version="18-powa-${POWA_VERSION}-pg_qualstats-${PG_QUALSTATS_VERSION}-hypopg-${HYPOPG_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/powa-team/powa-archivist"

WORKDIR /usr/local/src

COPY deployment/postgres/pg_qualstats-2.1.4-shmem.patch /tmp/pg_qualstats-2.1.4-shmem.patch

RUN set -eux; \
    test "${PG_QUALSTATS_VERSION}" = '2.1.4'; \
    test "${PG_QUALSTATS_TAG}" = '2.1.4'; \
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
      -exec sed -i 's|http://|https://|g' {} +; \
    printf '%s\n' 'Acquire::https::Verify-Peer "false";' \
      > /etc/apt/apt.conf.d/99-advisor-build-tls; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gcc \
      make \
      patch \
      postgresql-contrib-18 \
      postgresql-server-dev-18; \
    curl --insecure -fsSL "https://github.com/powa-team/powa-archivist/archive/refs/tags/${POWA_TAG}.tar.gz" -o powa.tar.gz; \
    echo "${POWA_SHA256}  powa.tar.gz" | sha256sum -c -; \
    mkdir powa-src; \
    tar -xzf powa.tar.gz --strip-components=1 -C powa-src; \
    make -C powa-src USE_PGXS=1 install; \
    test -f "/usr/share/postgresql/18/extension/powa--${POWA_VERSION}.sql"; \
    curl --insecure -fsSL "https://github.com/powa-team/pg_qualstats/archive/refs/tags/${PG_QUALSTATS_TAG}.tar.gz" -o pg_qualstats.tar.gz; \
    echo "${PG_QUALSTATS_SHA256}  pg_qualstats.tar.gz" | sha256sum -c -; \
    mkdir pg_qualstats-src; \
    tar -xzf pg_qualstats.tar.gz --strip-components=1 -C pg_qualstats-src; \
    patch --directory=pg_qualstats-src --strip=1 < /tmp/pg_qualstats-2.1.4-shmem.patch; \
    make -C pg_qualstats-src install; \
    test -f "/usr/lib/postgresql/18/lib/pg_qualstats.so"; \
    test -f "/usr/share/postgresql/18/extension/pg_qualstats--${PG_QUALSTATS_VERSION}.sql"; \
    curl --insecure -fsSL "https://github.com/HypoPG/hypopg/archive/${HYPOPG_COMMIT}.tar.gz" -o hypopg.tar.gz; \
    echo "${HYPOPG_SHA256}  hypopg.tar.gz" | sha256sum -c -; \
    mkdir hypopg-src; \
    tar -xzf hypopg.tar.gz --strip-components=1 -C hypopg-src; \
    test "$(sed -n "s/^default_version = '\\(.*\\)'/\\1/p" hypopg-src/hypopg.control)" = "${HYPOPG_VERSION}"; \
    make -C hypopg-src install; \
    test -f "/usr/lib/postgresql/18/lib/hypopg.so"; \
    test -f "/usr/share/postgresql/18/extension/hypopg--${HYPOPG_VERSION}.sql"; \
    apt-get purge -y --auto-remove gcc make patch postgresql-server-dev-18 curl; \
    rm -rf /var/lib/apt/lists/* /usr/local/src/powa-src /usr/local/src/powa.tar.gz \
      /usr/local/src/pg_qualstats-src /usr/local/src/pg_qualstats.tar.gz \
      /usr/local/src/hypopg-src /usr/local/src/hypopg.tar.gz \
      /tmp/pg_qualstats-2.1.4-shmem.patch \
      /etc/apt/apt.conf.d/99-advisor-build-tls

