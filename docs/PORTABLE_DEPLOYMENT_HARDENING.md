# Portable deployment hardening

## Verified downloads by default

The slim upstream image first bootstraps its CA bundle from signature-verified
Debian/PGDG APT metadata.  `deployment/postgres/Dockerfile` then verifies APT
and GitHub TLS certificates and checks every downloaded source archive against
its pinned SHA-256 checksum.  It no longer disables certificate checks or
passes `--insecure` to curl in a normal build.

If a local interception proxy cannot be installed as a trusted build CA, an
operator can make the exceptional risk decision explicitly:

```bash
docker compose build --build-arg ADVISOR_INSECURE_BUILD_TLS=1 source-db
```

Only `0` and `1` are accepted.  This flag must not be used for release or CI
builds.  Installing the organization's CA certificate in the Docker builder is
the preferred solution because SHA-256 protects the selected archives but does
not replace authenticated TLS for APT metadata.

## Existing-volume password rotation

The official PostgreSQL `POSTGRES_PASSWORD` bootstrap behavior only applies to
an empty data directory.  This stack additionally runs
`advisor-reconcile-roles` inside each database container's healthcheck.  It
uses the local Unix socket and updates the administrator plus the fixed,
least-privileged application roles in one transaction.  Dependents cannot
start until reconciliation succeeds.

Docker Compose interpolates dollar signs in unquoted and double-quoted `.env`
values.  Put secrets containing `$` (and, preferably, all secrets) in single
quotes; inside a single-quoted value write an embedded quote as `\'`:

```dotenv
ADVISOR_API_PASSWORD='strong$literal@:/?%5432'
```

Changing a database password in `.env` therefore requires recreating the
database and its clients so every container receives the new environment, but
does not require deleting its named volume:

```bash
docker compose up -d --build --force-recreate
docker compose --profile real-validation up -d --build --force-recreate \
  clone-db clone-evaluator
```

The persistent source/repository passwords, including the opt-in workload
login, have no Compose fallback.
`docker compose config` fails before creating a container when any of them is
missing or empty.  This is intentional: losing or forgetting to load `.env`
must never rotate an existing volume back to a public development password.
Start from `.env.example`, fill every required blank secret and replace the
remaining `change-me-*` examples before non-local use. Keep the file out of Git
and load the same secret source during every recreate or upgrade.
The reconciler also rejects the documented `change-me-*` placeholders and all
legacy `advisor_dev_*` passwords before contacting PostgreSQL, so copying an
old example file cannot downgrade an existing volume.
This known-password rejection applies to the persistent source and repository
profiles. The isolated validation clone is tmpfs-backed, internal-only and
destroyed with its container, so its documented local defaults remain usable;
production-like validation should still replace every clone secret.

The helper never prints passwords or puts them in command-line arguments;
transaction-local logging guards suppress secret-bearing DDL, and its internal
queries use `pg_stat_statements.track=none` so health probes do not pollute the
advisor telemetry.  A
salted desired-state fingerprint and a verifier/privilege-state fingerprint
are stored under `PGDATA` with mode `0600`, only after the role transaction
commits.  Every health probe compares the password verifier and expiry,
login/privilege flags, connection limit and role settings.  The same state performs no
`ALTER ROLE`; password or tracked role-attribute/config drift is repaired by
the next probe.  Role memberships and object ACLs remain owned by the bootstrap
and versioned migration paths.  If a required role is missing, health remains
failed instead of silently creating a partially privileged role; repair the
database bootstrap or restore first.
