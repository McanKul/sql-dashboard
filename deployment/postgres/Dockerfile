FROM postgres:17-trixie

ARG POWA_VERSION=5.2.0
ARG POWA_TAG=REL_5_2_0
ARG POWA_SHA256=098121a1307dc914535713e42555683c506de249ee588d5e66fa81c1c1c20908

LABEL org.opencontainers.image.title="PostgreSQL 17 + PoWA Archivist"
LABEL org.opencontainers.image.version="17-${POWA_VERSION}"
LABEL org.opencontainers.image.source="https://github.com/powa-team/powa-archivist"

WORKDIR /usr/local/src

RUN set -eux; \
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
      postgresql-contrib-17 \
      postgresql-server-dev-17; \
    curl --insecure -fsSL "https://github.com/powa-team/powa-archivist/archive/refs/tags/${POWA_TAG}.tar.gz" -o powa.tar.gz; \
    echo "${POWA_SHA256}  powa.tar.gz" | sha256sum -c -; \
    mkdir powa-src; \
    tar -xzf powa.tar.gz --strip-components=1 -C powa-src; \
    make -C powa-src USE_PGXS=1 install; \
    test -f "/usr/share/postgresql/17/extension/powa--${POWA_VERSION}.sql"; \
    apt-get purge -y --auto-remove gcc make postgresql-server-dev-17 curl; \
    rm -rf /var/lib/apt/lists/* /usr/local/src/powa-src /usr/local/src/powa.tar.gz \
      /etc/apt/apt.conf.d/99-advisor-build-tls

