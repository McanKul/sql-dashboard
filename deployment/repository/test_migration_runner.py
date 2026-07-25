import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).with_name("run-migrations.sh")
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


class MigrationRunnerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.migrations = self.root / "migrations"
        self.migrations.mkdir()
        self.capture = self.root / "psql-input.sql"
        self.fake_psql = self.root / "psql"
        self.fake_psql.write_text(
            "#!/usr/bin/env bash\nset -eu\ntee \"$MIGRATION_TEST_CAPTURE\" >/dev/null\n",
            encoding="utf-8",
        )
        self.fake_psql.chmod(0o755)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_migration(self, version: str, name: str, sql: str) -> Path:
        script = self.migrations / f"{version}_{name}.sql"
        script.write_text(sql, encoding="utf-8")
        checksum = hashlib.sha256(script.read_bytes()).hexdigest()
        manifest = self.migrations / "repository-migrations.manifest"
        with manifest.open("a", encoding="utf-8") as handle:
            handle.write(f"{version}|{name}|{script.name}|{checksum}\n")
        return script

    def run_runner(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "MIGRATIONS_DIR": str(self.migrations),
                "MIGRATION_PSQL_BIN": str(self.fake_psql),
                "MIGRATION_TEST_CAPTURE": str(self.capture),
                "PGDATABASE": "test_repository",
                "PGUSER": "migration_test",
            }
        )
        return subprocess.run(
            ["bash", str(RUNNER)],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_emits_one_locked_transaction_in_manifest_order(self) -> None:
        first = self.write_migration("0001", "baseline", "SELECT 1;\n")
        second = self.write_migration("0002", "forward_fix", "SELECT 2;\n")

        result = self.run_runner()

        self.assertEqual(result.returncode, 0, result.stderr)
        sql = self.capture.read_text(encoding="utf-8")
        self.assertLess(sql.index("BEGIN;"), sql.index("pg_advisory_xact_lock"))
        self.assertEqual(sql.count("BEGIN;"), 1)
        self.assertEqual(sql.count("COMMIT;"), 1)
        self.assertIn("SET LOCAL lock_timeout = '60s';", sql)
        self.assertIn("SET LOCAL search_path = pg_catalog;", sql)
        self.assertLess(sql.index(str(first)), sql.index(str(second)))
        self.assertLess(sql.index(str(second)), sql.index("COMMIT;"))
        self.assertIn("advisor_migrations.schema_migrations", sql)
        self.assertIn("unknown to this release", sql)
        self.assertIn("DO $manifest_guard$", sql)
        self.assertIn("$manifest_guard$;", sql)
        self.assertIn("DO $verify_0001$", sql)
        self.assertIn(f"\\ir '{first}'", sql)
        self.assertNotIn("\x1b", sql)

    def test_rejects_changed_file_before_contacting_database(self) -> None:
        script = self.write_migration("0001", "baseline", "SELECT 1;\n")
        script.write_text("SELECT 2;\n", encoding="utf-8")

        result = self.run_runner()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_rejects_out_of_order_versions(self) -> None:
        self.write_migration("0002", "second", "SELECT 2;\n")
        self.write_migration("0001", "first", "SELECT 1;\n")

        result = self.run_runner()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not ordered", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_rejects_duplicate_migration_names(self) -> None:
        self.write_migration("0001", "same_name", "SELECT 1;\n")
        self.write_migration("0002", "same_name", "SELECT 2;\n")

        result = self.run_runner()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate migration name", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_rejects_path_traversal(self) -> None:
        outside = self.root / "outside.sql"
        outside.write_text("SELECT 1;\n", encoding="utf-8")
        checksum = hashlib.sha256(outside.read_bytes()).hexdigest()
        (self.migrations / "repository-migrations.manifest").write_text(
            f"0001|escape|../outside.sql|{checksum}\n",
            encoding="utf-8",
        )

        result = self.run_runner()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes the migration directory", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_repository_manifest_freezes_every_migration_checksum(self) -> None:
        migration_dir = REPOSITORY_ROOT / "sql"
        manifest = migration_dir / "repository-migrations.manifest"
        previous_version = ""
        seen_scripts: set[str] = set()

        for line in manifest.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            version, _name, relative_script, expected_checksum = line.split("|")
            self.assertGreater(version, previous_version)
            self.assertNotIn(relative_script, seen_scripts)
            actual_checksum = hashlib.sha256(
                (migration_dir / relative_script).read_bytes()
            ).hexdigest()
            self.assertEqual(actual_checksum, expected_checksum, relative_script)
            previous_version = version
            seen_scripts.add(relative_script)

        self.assertTrue(seen_scripts)


if __name__ == "__main__":
    unittest.main()
