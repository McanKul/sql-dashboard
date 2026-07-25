FROM postgres:18-trixie

ARG POWA_VERSION=5.2.0
ARG POWA_TAG=REL_5_2_0
ARG POWA_SHA256=098121a1307dc914535713e42555683c506de249ee588d5e66fa81c1c1c20908
ARG PG_QUALSTATS_VERSION=2.1.4
ARG PG_QUALSTATS_TAG=2.1.4
ARG PG_QUALSTATS_SHA256=e5c4d4e32d4b4f4b3b6fdb2c15a8d2e01e07fc922424091539c88283f288020e
ARG PG_STAT_KCACHE_VERSION=2.3.2
ARG PG_STAT_KCACHE_TAG=REL2_3_2
ARG PG_STAT_KCACHE_SHA256=d5da20b5d8808f60dc1427c94d69186ff1d48fa1235ff672f5d0457b370304fb
ARG PG_WAIT_SAMPLING_RELEASE=1.1.11
ARG PG_WAIT_SAMPLING_TAG=v1.1.11
ARG PG_WAIT_SAMPLING_EXTENSION_VERSION=1.1
ARG PG_WAIT_SAMPLING_SHA256=7ecd40b02292cfa1ff43efe27c9742fc107f8b51ff8522f0f021067f8d5e8d95
ARG HYPOPG_VERSION=1.4.3
ARG HYPOPG_COMMIT=21d5461ad1868434cc47d9aa656d7afc2b24c464
ARG HYPOPG_SHA256=a57c34a0e2752176a1ba3d3b990cffe8ed8d65fccda96052a7f5605c274f554f
# Secure certificate verification is the default.  This escape hatch exists
# only for explicitly accepted local interception proxies; release builds must
# leave it at 0.
ARG ADVISOR_INSECURE_BUILD_TLS=0

LABEL org.opencontainers.image.title="PostgreSQL 18 + PoWA Archivist + pg_qualstats + pg_stat_kcache + pg_wait_sampling + HypoPG"
LABEL org.opencontainers.image.version="18-powa-${POWA_VERSION}-pg_qualstats-${PG_QUALSTATS_VERSION}-pg_stat_kcache-${PG_STAT_KCACHE_VERSION}-pg_wait_sampling-${PG_WAIT_SAMPLING_RELEASE}-hypopg-${HYPOPG_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/powa-team/powa-archivist"

WORKDIR /usr/local/src

COPY deployment/postgres/pg_qualstats-2.1.4-shmem.patch /tmp/pg_qualstats-2.1.4-shmem.patch
COPY deployment/postgres/powa-5.2.0-qualstats-purge.patch /tmp/powa-5.2.0-qualstats-purge.patch

# The slim upstream image intentionally has no CA bundle.  Bootstrap that
# bundle from signed Debian/PGDG APT metadata before switching the sources
# from HTTP to certificate-verified HTTPS.
RUN set -eux; \
    test "${PG_QUALSTATS_VERSION}" = '2.1.4'; \
    test "${PG_QUALSTATS_TAG}" = '2.1.4'; \
    case "${ADVISOR_INSECURE_BUILD_TLS}" in \
      0|1) ;; \
      *) echo 'ADVISOR_INSECURE_BUILD_TLS must be 0 or 1' >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) \
      -exec sed -i 's|http://|https://|g' {} +; \
    case "${ADVISOR_INSECURE_BUILD_TLS}" in \
      0) ;; \
      1) printf '%s\n' 'Acquire::https::Verify-Peer "false";' > /etc/apt/apt.conf.d/99-advisor-build-tls ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      curl \
      gcc \
      make \
      patch \
      postgresql-contrib-18 \
      postgresql-server-dev-18; \
    download() { \
      if [ "${ADVISOR_INSECURE_BUILD_TLS}" = 1 ]; then \
        curl --insecure -fsSL "$1" -o "$2"; \
      else \
        curl -fsSL "$1" -o "$2"; \
      fi; \
    }; \
    download "https://github.com/powa-team/powa-archivist/archive/refs/tags/${POWA_TAG}.tar.gz" powa.tar.gz; \
    echo "${POWA_SHA256}  powa.tar.gz" | sha256sum -c -; \
    mkdir powa-src; \
    tar -xzf powa.tar.gz --strip-components=1 -C powa-src; \
    patch --directory=powa-src --strip=1 < /tmp/powa-5.2.0-qualstats-purge.patch; \
    ! grep -Fq "powa_prevent_concurrent_snapshot(_srvid,'pg_qualstats')" powa-src/powa--*.sql; \
    make -C powa-src USE_PGXS=1 install; \
    test -f "/usr/share/postgresql/18/extension/powa--${POWA_VERSION}.sql"; \
    download "https://github.com/powa-team/pg_qualstats/archive/refs/tags/${PG_QUALSTATS_TAG}.tar.gz" pg_qualstats.tar.gz; \
    echo "${PG_QUALSTATS_SHA256}  pg_qualstats.tar.gz" | sha256sum -c -; \
    mkdir pg_qualstats-src; \
    tar -xzf pg_qualstats.tar.gz --strip-components=1 -C pg_qualstats-src; \
    patch --directory=pg_qualstats-src --strip=1 < /tmp/pg_qualstats-2.1.4-shmem.patch; \
    make -C pg_qualstats-src install; \
    test -f "/usr/lib/postgresql/18/lib/pg_qualstats.so"; \
    test -f "/usr/share/postgresql/18/extension/pg_qualstats--${PG_QUALSTATS_VERSION}.sql"; \
    download "https://github.com/powa-team/pg_stat_kcache/archive/refs/tags/${PG_STAT_KCACHE_TAG}.tar.gz" pg_stat_kcache.tar.gz; \
    echo "${PG_STAT_KCACHE_SHA256}  pg_stat_kcache.tar.gz" | sha256sum -c -; \
    mkdir pg_stat_kcache-src; \
    tar -xzf pg_stat_kcache.tar.gz --strip-components=1 -C pg_stat_kcache-src; \
    test "$(sed -n "s/^default_version = '\\(.*\\)'/\\1/p" pg_stat_kcache-src/pg_stat_kcache.control)" = "${PG_STAT_KCACHE_VERSION}"; \
    make -C pg_stat_kcache-src install; \
    test -f "/usr/lib/postgresql/18/lib/pg_stat_kcache.so"; \
    test -f "/usr/share/postgresql/18/extension/pg_stat_kcache--${PG_STAT_KCACHE_VERSION}.sql"; \
    download "https://github.com/postgrespro/pg_wait_sampling/archive/refs/tags/${PG_WAIT_SAMPLING_TAG}.tar.gz" pg_wait_sampling.tar.gz; \
    echo "${PG_WAIT_SAMPLING_SHA256}  pg_wait_sampling.tar.gz" | sha256sum -c -; \
    mkdir pg_wait_sampling-src; \
    tar -xzf pg_wait_sampling.tar.gz --strip-components=1 -C pg_wait_sampling-src; \
    test "$(sed -n "s/^default_version = '\\(.*\\)'/\\1/p" pg_wait_sampling-src/pg_wait_sampling.control)" = "${PG_WAIT_SAMPLING_EXTENSION_VERSION}"; \
    make -C pg_wait_sampling-src USE_PGXS=1 install; \
    test -f "/usr/lib/postgresql/18/lib/pg_wait_sampling.so"; \
    test -f "/usr/share/postgresql/18/extension/pg_wait_sampling--${PG_WAIT_SAMPLING_EXTENSION_VERSION}.sql"; \
    download "https://github.com/HypoPG/hypopg/archive/${HYPOPG_COMMIT}.tar.gz" hypopg.tar.gz; \
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
      /usr/local/src/pg_stat_kcache-src /usr/local/src/pg_stat_kcache.tar.gz \
      /usr/local/src/pg_wait_sampling-src /usr/local/src/pg_wait_sampling.tar.gz \
      /usr/local/src/hypopg-src /usr/local/src/hypopg.tar.gz \
      /tmp/pg_qualstats-2.1.4-shmem.patch /tmp/powa-5.2.0-qualstats-purge.patch \
      /etc/apt/apt.conf.d/99-advisor-build-tls

COPY deployment/postgres/reconcile-roles.sh /usr/local/bin/advisor-reconcile-roles
RUN chmod 0755 /usr/local/bin/advisor-reconcile-roles
