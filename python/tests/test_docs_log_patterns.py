"""Pins the troubleshooting checklist to the lines the receiver emits.

The checklist in ``docs/user/pipeline-setup.md`` tells the reader to grep
the journal for specific patterns. Twice now a log line has been added
without its consuming pattern following along, leaving a line the docs
promise but no one can find. This test enumerates the lines the HAE
endpoints actually log and asserts each is matched by at least one grep
pattern in the document.

The patterns are read out of the document rather than restated here — a
copy would drift apart from the original exactly as the original drifted
from the code.

Uses importlib for the same reason as test_app_debounce.py:
``traning_cli/server/__init__.py`` shadows the ``app`` submodule
attribute with a built FastAPI instance.
"""

import importlib
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

app_mod = importlib.import_module("traning_cli.server.app")

API_KEY = "test-api-key"
HEADERS = {"X-API-Key": API_KEY}

DOC = Path(__file__).resolve().parents[2] / "docs" / "user" / "pipeline-setup.md"
SECTION_START = "### When HAE data stops arriving"
SECTION_END = "## Services on kailash"


def _hae_section() -> str:
    text = DOC.read_text(encoding="utf-8")
    start = text.index(SECTION_START)
    return text[start : text.index(SECTION_END, start)]


def _grep_patterns() -> list[str]:
    """Every ``grep -E "..."`` pattern in the HAE troubleshooting section."""
    return re.findall(r'grep -E "([^"]+)"', _hae_section())


@pytest.fixture
def client(traning_data_dir, monkeypatch):
    monkeypatch.setenv("TRANING_API_KEY", API_KEY)
    monkeypatch.setattr(app_mod, "save_health_push", lambda payload: (1, []))
    monkeypatch.setattr(app_mod, "save_workout_push", lambda payload: 1)
    monkeypatch.setattr(app_mod, "commit_health_data", lambda **kw: True)
    monkeypatch.setattr(app_mod, "_schedule_health_import", lambda files: None)
    monkeypatch.setattr(app_mod, "_schedule_workouts_import", lambda n: None)

    application = app_mod.create_app()
    with TestClient(application) as c:
        yield c


@pytest.fixture
def emitted_lines(client, caplog):
    """Every line the HAE endpoints log, captured from real requests.

    Collected by exercising the endpoints rather than by listing strings,
    so a new or reworded log line shows up here on its own.
    """
    pushes = [
        ("/v1/health", {"data": {"metrics": [{"name": "hr", "units": "bpm", "data": [1]}]}}),
        ("/v1/workouts", {"data": {"workouts": [{"name": "Running"}]}}),
        ("/v1/health", {"data": {"metrics": []}}),  # rejected
        ("/v1/workouts", {"data": {"workouts": "nope"}}),  # rejected
    ]
    with caplog.at_level("INFO", logger=app_mod.log.name):
        for path, body in pushes:
            client.post(path, json=body, headers=HEADERS)
    return [record.getMessage() for record in caplog.records]


def test_the_section_still_contains_grep_patterns():
    """Guard the extraction itself — zero patterns would pass vacuously."""
    assert len(_grep_patterns()) >= 2


def test_endpoints_emit_the_expected_kinds_of_line(emitted_lines):
    """Guard the capture — an empty list would pass the coverage test."""
    assert any("push from" in line for line in emitted_lines)
    assert any("rejected by validation" in line for line in emitted_lines)
    assert any("Received" in line for line in emitted_lines)


def test_every_log_line_is_findable_from_the_docs(emitted_lines):
    patterns = [re.compile(p) for p in _grep_patterns()]
    unfindable = [
        line for line in emitted_lines if not any(p.search(line) for p in patterns)
    ]
    assert not unfindable, (
        "These log lines match no grep pattern in the troubleshooting "
        f"checklist, so a reader following it will never see them: {unfindable}. "
        f"Add a matching pattern in {DOC.name}."
    )
