from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("reconcile-roles.sh")
CLONE_INIT_SCRIPT = SCRIPT.parents[1] / "clone" / "init-clone.sh"


class RoleReconcilerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.pgdata = self.root / "pgdata"
        self.pgdata.mkdir()
        self.state = self.root / "role-state"
        self.state.write_text(
            '[{"rolname":"advisor_api","rolpassword":"old-api",'
            '"rolsuper":false,"rolinherit":true,"rolconfig":null}]\n'
        )
        self.capture = self.root / "psql-capture"
        self.fake_psql = self.root / "psql"
        self.fake_psql.write_text(
            """#!/usr/bin/env bash
set -Eeuo pipefail
printf 'session-options=%s|app=%s\\n' "${PGOPTIONS:-}" "${PGAPPNAME:-}" >> "$MOCK_CAPTURE"
for argument in "$@"; do
  if [[ "$argument" == --command=* ]]; then
    printf '%s\\n%s\\n' 'state-query' "$argument" >> "$MOCK_CAPTURE"
    cat "$MOCK_STATE"
    exit "${MOCK_STATE_EXIT_CODE:-0}"
  fi
done
payload="$(cat)"
printf '%s\\n%s\\n%s\\n' 'transaction-begin' "$payload" 'transaction-end' >> "$MOCK_CAPTURE"
if [[ "${MOCK_FAIL_TRANSACTION:-0}" == 1 ]]; then
  printf '%s\\n' 'mock transaction failure' >&2
  exit 9
fi
printf '%s\\n' "$MOCK_ROTATED_STATE" > "$MOCK_STATE"
"""
        )
        self.fake_psql.chmod(0o755)

        self.secrets = {
            "POSTGRES_PASSWORD": "admin@:/?%5432'fresh",
            "POWA_COLLECTOR_PASSWORD": "collector@:/?%5432'fresh",
            "ADVISOR_API_PASSWORD": "api@:/?%5432'fresh",
            "ADVISOR_EVALUATOR_PASSWORD": "evaluator@:/?%5432'fresh",
            "ADVISOR_JOIN_SOURCE_PASSWORD": "source-join@:/?%5432'fresh",
            "ADVISOR_JOIN_REPOSITORY_PASSWORD": "join@:/?%5432'fresh",
            "WORKLOAD_DB_PASSWORD": "workload@:/?%5432'fresh",
            "CLONE_RUNNER_PASSWORD": "runner@:/?%5432'fresh",
        }
        self.env = {
            **os.environ,
            **self.secrets,
            "PGDATA": str(self.pgdata),
            "PGPORT": "5433",
            "POSTGRES_DB": "powa_repository",
            "POSTGRES_USER": "postgres",
            "ADVISOR_RECONCILE_PSQL_BIN": str(self.fake_psql),
            "ADVISOR_RECONCILE_MARKER_DIR": str(self.pgdata),
            "MOCK_CAPTURE": str(self.capture),
            "MOCK_STATE": str(self.state),
            "MOCK_ROTATED_STATE": (
                '[{"rolname":"advisor_api","rolpassword":"new-api",'
                '"rolsuper":false,"rolinherit":true,"rolcreatedb":false,'
                '"rolcreaterole":false,"rolcanlogin":true,'
                '"rolreplication":false,"rolbypassrls":false,'
                '"rolconnlimit":-1,"rolconfig":null}]'
            ),
        }

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_reconciler(
        self,
        profile: str = "repository",
        *,
        env_overrides: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {**self.env, **(env_overrides or {})}
        return subprocess.run(
            ["bash", str(SCRIPT), profile],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_secrets_absent(self, *values: str) -> None:
        combined = "\n".join(values)
        for secret in self.secrets.values():
            self.assertNotIn(secret, combined)

    def test_fresh_marker_rotation_and_repeated_probe_are_idempotent(self) -> None:
        first = self.run_reconciler()
        self.assertEqual(first.returncode, 0, first.stderr)

        marker = self.pgdata / ".advisor-role-passwords-repository.v1"
        self.assertTrue(marker.is_file())
        self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)

        capture_after_first = self.capture.read_text()
        self.assertEqual(capture_after_first.count("transaction-begin"), 1)
        self.assertIn("ALTER ROLE advisor_api LOGIN INHERIT NOSUPERUSER", capture_after_first)
        self.assertIn("CONNECTION LIMIT -1 PASSWORD", capture_after_first)
        self.assertIn("VALID UNTIL 'infinity'", capture_after_first)
        self.assertIn("'rolvaliduntil', auth.rolvaliduntil", capture_after_first)
        self.assertIn("\\getenv api_password ADVISOR_API_PASSWORD", capture_after_first)
        self.assertIn("-c pg_stat_statements.track=none", capture_after_first)
        self.assertIn('policy_revision="4"', SCRIPT.read_text())
        self.assertIn("advisor-role-reconciler-policy-v${policy_revision}", SCRIPT.read_text())
        self.assertIn("app=advisor-role-reconciler", capture_after_first)
        self.assertIn("SET LOCAL log_statement = 'none'", capture_after_first)
        self.assertIn("SET LOCAL log_min_error_statement = 'panic'", capture_after_first)
        self.assertIn(
            "SET LOCAL log_parameter_max_length_on_error = 0",
            capture_after_first,
        )
        self.assert_secrets_absent(
            first.stdout,
            first.stderr,
            marker.read_text(),
            capture_after_first,
        )

        second = self.run_reconciler()
        self.assertEqual(second.returncode, 0, second.stderr)
        capture_after_second = self.capture.read_text()
        self.assertEqual(capture_after_second.count("transaction-begin"), 1)
        self.assertEqual(
            capture_after_second.count("state-query"),
            capture_after_first.count("state-query") + 1,
        )

    def test_unchanged_existing_volume_checks_state_without_alter_role(self) -> None:
        first = self.run_reconciler()
        self.assertEqual(first.returncode, 0, first.stderr)
        capture_after_first = self.capture.read_text()

        restarted = self.run_reconciler()
        self.assertEqual(restarted.returncode, 0, restarted.stderr)
        new_capture = self.capture.read_text()
        self.assertEqual(new_capture.count("transaction-begin"), 1)
        self.assertEqual(
            new_capture.count("state-query"),
            capture_after_first.count("state-query") + 1,
        )

    def test_changed_password_rotates_existing_volume_without_leaking_secret(self) -> None:
        first = self.run_reconciler()
        self.assertEqual(first.returncode, 0, first.stderr)
        old_marker = (
            self.pgdata / ".advisor-role-passwords-repository.v1"
        ).read_text()

        rotated_secret = "rotated@:/?%5432'still-safe"
        rotated = self.run_reconciler(
            env_overrides={
                "ADVISOR_API_PASSWORD": rotated_secret,
            }
        )
        self.assertEqual(rotated.returncode, 0, rotated.stderr)
        capture = self.capture.read_text()
        new_marker = (
            self.pgdata / ".advisor-role-passwords-repository.v1"
        ).read_text()
        self.assertEqual(capture.count("transaction-begin"), 2)
        self.assertNotEqual(new_marker, old_marker)
        self.assertNotIn(rotated_secret, rotated.stdout + rotated.stderr + capture + new_marker)

    def test_failed_transaction_does_not_publish_new_marker(self) -> None:
        first = self.run_reconciler()
        self.assertEqual(first.returncode, 0, first.stderr)
        marker = self.pgdata / ".advisor-role-passwords-repository.v1"
        marker_before = marker.read_bytes()

        rejected_secret = "rejected@:/?%5432'not-logged"
        failed = self.run_reconciler(
            env_overrides={
                "ADVISOR_API_PASSWORD": rejected_secret,
                "MOCK_FAIL_TRANSACTION": "1",
            }
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(marker.read_bytes(), marker_before)
        self.assertNotIn(rejected_secret, failed.stdout + failed.stderr + self.capture.read_text())

    def test_database_not_ready_fails_without_marker(self) -> None:
        result = self.run_reconciler(
            env_overrides={"MOCK_STATE_EXIT_CODE": "5"}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(
            (self.pgdata / ".advisor-role-passwords-repository.v1").exists()
        )
        self.assertTrue(self.capture.exists())

    def test_documented_and_legacy_passwords_fail_before_database_contact(self) -> None:
        for rejected in ("change-me-api", "advisor_dev_api"):
            with self.subTest(rejected=rejected):
                result = self.run_reconciler(
                    env_overrides={"ADVISOR_API_PASSWORD": rejected}
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ADVISOR_API_PASSWORD must not use", result.stderr)
                self.assertNotIn(rejected, result.stderr)
                self.assertFalse(self.capture.exists())

    def test_privilege_drift_is_reconciled_with_same_passwords(self) -> None:
        first = self.run_reconciler()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.state.write_text(
            '[{"rolname":"advisor_api","rolpassword":"new-api",'
            '"rolsuper":true,"rolinherit":true,"rolconfig":null}]\n'
        )

        repaired = self.run_reconciler()
        self.assertEqual(repaired.returncode, 0, repaired.stderr)
        capture = self.capture.read_text()
        self.assertEqual(capture.count("transaction-begin"), 2)
        self.assertIn("ALTER ROLE advisor_api LOGIN INHERIT NOSUPERUSER", capture)
        self.assertIn("CONNECTION LIMIT -1 PASSWORD", capture)
        self.assertIn("ALTER ROLE advisor_api RESET ALL", capture)
        self.assertIn("'rolsuper'", capture)
        self.assertIn("'rolinherit'", capture)
        self.assertIn("'rolcreatedb'", capture)
        self.assertIn("'rolcreaterole'", capture)
        self.assertIn("'rolcanlogin'", capture)
        self.assertIn("'rolreplication'", capture)
        self.assertIn("'rolbypassrls'", capture)
        self.assertIn("'rolconnlimit'", capture)
        self.assertIn("'rolvaliduntil'", capture)
        self.assertIn("'rolconfig'", capture)
        self.assertIn("'rolmemberships'", capture)
        self.assertIn("'admin_option', membership.admin_option", capture)
        self.assertIn("'inherit_option', membership.inherit_option", capture)
        self.assertIn("'set_option', membership.set_option", capture)

    def test_source_and_clone_profiles_keep_fixed_roles_least_privileged(self) -> None:
        source = self.run_reconciler("source")
        self.assertEqual(source.returncode, 0, source.stderr)
        clone = self.run_reconciler("clone")
        self.assertEqual(clone.returncode, 0, clone.stderr)

        capture = self.capture.read_text()
        self.assertIn(
            "ALTER ROLE advisor_evaluator LOGIN NOINHERIT NOSUPERUSER "
            "NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2",
            capture,
        )
        self.assertIn(
            "ALTER ROLE advisor_join_reader LOGIN NOINHERIT NOSUPERUSER "
            "NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2",
            capture,
        )
        self.assertIn("\\getenv workload_password WORKLOAD_DB_PASSWORD", capture)
        self.assertIn(
            "ALTER ROLE advisor_workload_login LOGIN NOINHERIT NOSUPERUSER "
            "NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 70",
            capture,
        )
        self.assertIn("ALTER ROLE advisor_workload_login RESET ALL", capture)
        self.assertGreaterEqual(
            capture.count(
                "ALTER ROLE powa_collector SET pg_stat_statements.track = 'none'"
            ),
            2,
        )
        self.assertGreaterEqual(
            capture.count("ALTER ROLE powa_collector SET pg_stat_kcache.track = 'none'"),
            2,
        )
        self.assertGreaterEqual(
            capture.count("ALTER ROLE powa_collector SET pg_qualstats.enabled = off"),
            2,
        )
        for observer_role in ("advisor_evaluator", "advisor_join_reader"):
            self.assertGreaterEqual(
                capture.count(
                    f"ALTER ROLE {observer_role} SET pg_stat_statements.track = 'none'"
                ),
                2,
            )
            self.assertGreaterEqual(
                capture.count(
                    f"ALTER ROLE {observer_role} SET pg_stat_kcache.track = 'none'"
                ),
                2,
            )
            self.assertGreaterEqual(
                capture.count(
                    f"ALTER ROLE {observer_role} SET pg_qualstats.enabled = off"
                ),
                2,
            )
        self.assertIn(
            "ALTER ROLE clone_runner LOGIN INHERIT NOSUPERUSER NOCREATEDB "
            "NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4",
            capture,
        )
        self.assertNotIn("ALTER ROLE clone_runner LOGIN NOINHERIT", capture)
        self.assertIn(
            "REVOKE %I FROM clone_runner GRANTED BY %I CASCADE",
            capture,
        )
        self.assertIn(
            "GRANT pg_read_all_data TO clone_runner\n"
            "  WITH INHERIT TRUE, SET FALSE, ADMIN FALSE;",
            capture,
        )
        self.assertIn("ALTER ROLE advisor_evaluator RESET ALL", capture)
        self.assertIn(
            "ALTER ROLE advisor_evaluator SET default_transaction_read_only = on",
            capture,
        )
        self.assertIn("ALTER ROLE clone_runner RESET ALL", capture)
        self.assertIn("ALTER ROLE clone_runner SET row_security = on", capture)
        self.assertIn(
            "ALTER ROLE clone_runner SET search_path = pg_catalog, public",
            capture,
        )
        self.assert_secrets_absent(source.stdout, source.stderr, clone.stdout, clone.stderr, capture)

    def test_clone_init_hardens_restored_runner_capabilities_and_manifest(self) -> None:
        script = CLONE_INIT_SCRIPT.read_text()

        self.assertIn(
            "CREATE ROLE clone_runner LOGIN INHERIT PASSWORD %L NOSUPERUSER "
            "NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4",
            script,
        )
        self.assertIn(
            "ALTER ROLE clone_runner LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE",
            script,
        )
        self.assertIn("ALTER ROLE clone_runner RESET ALL;", script)
        self.assertIn(
            "ALTER ROLE clone_runner SET search_path = pg_catalog, public;",
            script,
        )
        self.assertIn(
            "GRANT pg_read_all_data TO clone_runner\n"
            "  WITH INHERIT TRUE, SET FALSE, ADMIN FALSE;",
            script,
        )
        self.assertIn(
            'REVOKE CONNECT, TEMPORARY ON DATABASE :"clone_database" FROM PUBLIC;',
            script,
        )
        self.assertIn(
            'REVOKE CONNECT, TEMPORARY ON DATABASE :"clone_database" FROM clone_runner;',
            script,
        )
        self.assertIn(
            "REVOKE CREATE ON SCHEMA %I FROM PUBLIC, clone_runner",
            script,
        )
        self.assertIn("namespace.nspname NOT LIKE 'pg_temp_%'", script)
        self.assertIn("namespace.nspname NOT LIKE 'pg_toast_temp_%'", script)
        self.assertEqual(script.count("routine.provolatile = 'v'"), 2)
        self.assertEqual(script.count("routine.prosecdef"), 2)
        self.assertEqual(script.count("routine.prokind = 'p'"), 2)
        self.assertEqual(
            script.count("namespace.nspname <> 'pg_catalog'"),
            2,
        )
        self.assertEqual(
            script.count("namespace.nspname <> 'information_schema'"),
            2,
        )
        self.assertEqual(
            script.count("language.lanname NOT IN ('sql', 'plpgsql')"),
            2,
        )
        self.assertIn(
            "REVOKE EXECUTE ON ROUTINE %I.%I(%s) FROM PUBLIC, clone_runner",
            script,
        )
        self.assertIn(
            "REVOKE USAGE ON FOREIGN SERVER %I FROM PUBLIC, clone_runner",
            script,
        )
        self.assertIn(
            "pg_catalog.has_function_privilege('clone_runner', routine.oid, 'EXECUTE')",
            script,
        )
        self.assertIn("runner_policy_revision integer NOT NULL DEFAULT 1", script)
        self.assertIn("dangerous_routines_revoked boolean NOT NULL DEFAULT true", script)
        self.assertIn("VALUES (true, :'template_restored'::boolean, 1, true)", script)
        self.assertIn(
            "runner_policy_revision = EXCLUDED.runner_policy_revision",
            script,
        )
        self.assertIn(
            "dangerous_routines_revoked = EXCLUDED.dangerous_routines_revoked",
            script,
        )


if __name__ == "__main__":
    unittest.main()
