from __future__ import annotations

import pytest
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from pydantic import ValidationError

from app.clone_evaluator import CloneEvaluatorSettings
from app.config import Settings
from app.evaluator import EvaluatorSettings


SPECIAL_PASSWORD = "strong@source-db:/appdb?%5432"


def test_api_builds_safe_conninfo_from_separate_fields() -> None:
    settings = Settings(
        database_url=None,
        database_host="repository-db",
        database_port=5433,
        database_name="powa_repository",
        database_user="advisor_api",
        database_password=SPECIAL_PASSWORD,
        database_sslmode="disable",
    )

    connection = conninfo_to_dict(settings.database_conninfo)
    assert connection == {
        "user": "advisor_api",
        "password": SPECIAL_PASSWORD,
        "dbname": "powa_repository",
        "host": "repository-db",
        "port": "5433",
        "sslmode": "disable",
    }


def test_blank_legacy_url_environment_falls_back_to_separate_fields(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    environment = {
        "DATABASE_URL": "",
        "DATABASE_HOST": "repository-db",
        "DATABASE_PORT": "5433",
        "DATABASE_NAME": "powa_repository",
        "DATABASE_USER": "advisor_api",
        "DATABASE_PASSWORD": SPECIAL_PASSWORD,
        "DATABASE_SSLMODE": "disable",
        "EVALUATOR_DATABASE_URL": "",
        "EVALUATOR_DATABASE_HOST": "source-db",
        "EVALUATOR_DATABASE_PORT": "5432",
        "EVALUATOR_DATABASE_NAME": "appdb",
        "EVALUATOR_DATABASE_USER": "advisor_evaluator",
        "EVALUATOR_DATABASE_PASSWORD": SPECIAL_PASSWORD,
        "EVALUATOR_DATABASE_SSLMODE": "disable",
        "CLONE_DATABASE_URL": "",
        "CLONE_DATABASE_HOST": "clone-db",
        "CLONE_DATABASE_PORT": "5432",
        "CLONE_DATABASE_NAME": "postgres",
        "CLONE_DATABASE_USER": "clone_admin",
        "CLONE_DATABASE_PASSWORD": SPECIAL_PASSWORD,
        "CLONE_DATABASE_SSLMODE": "disable",
    }
    for name, value in environment.items():
        monkeypatch.setenv(name, value)

    api = conninfo_to_dict(Settings().database_conninfo)
    evaluator = conninfo_to_dict(EvaluatorSettings().evaluator_database_conninfo)
    clone = conninfo_to_dict(CloneEvaluatorSettings().clone_database_conninfo)
    assert api["host"] == "repository-db" and api["password"] == SPECIAL_PASSWORD
    assert evaluator["host"] == "source-db" and evaluator["password"] == SPECIAL_PASSWORD
    assert clone["host"] == "clone-db" and clone["password"] == SPECIAL_PASSWORD


def test_api_database_url_override_takes_precedence() -> None:
    override = make_conninfo(
        host="repository-override",
        port=6432,
        dbname="advisor_history",
        user="legacy_api",
        password=SPECIAL_PASSWORD,
    )
    settings = Settings(
        database_url=override,
        database_host="ignored-host",
        database_port=6543,
        database_name="ignored_database",
        database_user="ignored_user",
        database_password="ignored_password",
    )

    connection = conninfo_to_dict(settings.database_conninfo)
    assert connection["host"] == "repository-override"
    assert connection["port"] == "6432"
    assert connection["dbname"] == "advisor_history"
    assert connection["password"] == SPECIAL_PASSWORD


def test_invalid_legacy_url_does_not_leak_password() -> None:
    unsafe_url = (
        f"postgresql://advisor_api:{SPECIAL_PASSWORD}@repository-db:5433/powa_repository"
    )
    with pytest.raises(ValidationError) as captured:
        Settings(database_url=unsafe_url)
    assert SPECIAL_PASSWORD not in str(captured.value)


@pytest.mark.parametrize(
    "overrides",
    [
        {"database_host": "source-db"},
    ],
)
def test_api_repository_guard_checks_parsed_target(
    overrides: dict[str, object],
) -> None:
    values: dict[str, object] = {
        "database_url": None,
        "database_host": "repository-db",
        "database_port": 5433,
        "database_name": "powa_repository",
        "database_user": "advisor_api",
        "database_password": SPECIAL_PASSWORD,
    }
    values.update(overrides)

    with pytest.raises(ValidationError) as captured:
        Settings.model_validate(values)
    assert SPECIAL_PASSWORD not in str(captured.value)


def test_api_repository_may_use_standard_postgres_port() -> None:
    settings = Settings(
        database_url=None,
        database_host="repository.example.internal",
        database_port=5432,
        database_name="appdb",
        database_user="advisor_api",
        database_password=SPECIAL_PASSWORD,
    )

    connection = conninfo_to_dict(settings.database_conninfo)
    assert connection["host"] == "repository.example.internal"
    assert connection["port"] == "5432"
    assert connection["dbname"] == "appdb"


def test_evaluator_builds_safe_conninfo_from_separate_fields() -> None:
    settings = EvaluatorSettings(
        evaluator_database_url=None,
        evaluator_database_host="source-db",
        evaluator_database_port=5432,
        evaluator_database_name="appdb",
        evaluator_database_user="advisor_evaluator",
        evaluator_database_password=SPECIAL_PASSWORD,
        evaluator_database_sslmode="disable",
    )

    connection = conninfo_to_dict(settings.evaluator_database_conninfo)
    assert connection["password"] == SPECIAL_PASSWORD
    assert connection["host"] == "source-db"
    assert connection["dbname"] == "appdb"


def test_evaluator_database_url_override_remains_supported() -> None:
    override = make_conninfo(
        host="legacy-source",
        port=6432,
        dbname="legacy_app",
        user="legacy_evaluator",
        password=SPECIAL_PASSWORD,
    )
    settings = EvaluatorSettings(
        evaluator_database_url=override,
        evaluator_database_host="ignored",
        evaluator_database_password="ignored",
    )

    connection = conninfo_to_dict(settings.evaluator_database_conninfo)
    assert connection["host"] == "legacy-source"
    assert connection["password"] == SPECIAL_PASSWORD


def test_clone_evaluator_builds_safe_conninfo_from_separate_fields() -> None:
    settings = CloneEvaluatorSettings(
        clone_database_url=None,
        clone_database_host="clone-db",
        clone_database_port=5432,
        clone_database_name="postgres",
        clone_database_user="clone_admin",
        clone_database_password=SPECIAL_PASSWORD,
        clone_database_sslmode="disable",
        clone_template_database="appdb",
    )

    connection = conninfo_to_dict(settings.clone_database_conninfo)
    assert connection["password"] == SPECIAL_PASSWORD
    assert connection["host"] == "clone-db"
    assert connection["dbname"] == "postgres"


def test_clone_database_url_override_remains_supported() -> None:
    override = make_conninfo(
        host="legacy-clone",
        port=55432,
        dbname="postgres",
        user="clone_admin",
        password=SPECIAL_PASSWORD,
    )
    settings = CloneEvaluatorSettings(
        clone_database_url=override,
        clone_database_host="ignored",
        clone_database_password="ignored",
        clone_template_database="appdb",
    )

    connection = conninfo_to_dict(settings.clone_database_conninfo)
    assert connection["host"] == "legacy-clone"
    assert connection["password"] == SPECIAL_PASSWORD
