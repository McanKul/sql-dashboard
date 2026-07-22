#!/bin/sh
set -eu

: "${POWA_COLLECTOR_PASSWORD:?POWA_COLLECTOR_PASSWORD tanimli olmali}"
: "${POWA_REPOSITORY_DSN:?POWA_REPOSITORY_DSN tanimli olmali}"

escape_pgpass() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/:/\\:/g'
}

append_pgpass() {
  host="$(escape_pgpass "$1")"
  port="$(escape_pgpass "$2")"
  database="$(escape_pgpass "$3")"
  username="$(escape_pgpass "$4")"
  password="$(escape_pgpass "$5")"
  printf '%s:%s:%s:%s:%s\n' "$host" "$port" "$database" "$username" "$password" \
    >> /tmp/powa-collector.pgpass
}

umask 077
: > /tmp/powa-collector.pgpass
append_pgpass \
  "${POWA_SOURCE_HOST:-source-db}" \
  "${POWA_SOURCE_PORT:-5432}" \
  "*" \
  "powa_collector" \
  "$POWA_COLLECTOR_PASSWORD"
append_pgpass \
  "${POWA_REPOSITORY_HOST:-repository-db}" \
  "${POWA_REPOSITORY_PORT:-5433}" \
  "${POWA_REPOSITORY_DB:-powa_repository}" \
  "powa_collector" \
  "$POWA_COLLECTOR_PASSWORD"

# Her dis kaynak ayri bir 0600 dosyada tutulur. Dizin Git tarafindan ignore
# edilir ve container'a read-only baglanir; parola repository'ye yazilmaz.
if [ -d /run/advisor-source-secrets ]; then
  for source_file in /run/advisor-source-secrets/*.pgpass; do
    [ -f "$source_file" ] || continue
    cat "$source_file" >> /tmp/powa-collector.pgpass
  done
fi

cat > /tmp/.powa-collector.conf <<EOF
{
  "repository": {
    "dsn": "${POWA_REPOSITORY_DSN}"
  },
  "debug": false
}
EOF

export HOME=/tmp
export PGPASSFILE=/tmp/powa-collector.pgpass

chown nobody:nogroup /tmp/powa-collector.pgpass /tmp/.powa-collector.conf
chmod 0600 /tmp/powa-collector.pgpass /tmp/.powa-collector.conf

exec setpriv --reuid=nobody --regid=nogroup --init-groups "$@"
