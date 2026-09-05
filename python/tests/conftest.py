"""Shared pytest fixtures for the traning_cli test suite.

Also pins which copy of the package the suite runs against. `traning_cli`
is installed editable from the main checkout, so a bare `pytest` inside a
git worktree collects the tests from here and runs them against the code
over there: everything passes, and it says nothing about the branch under
test. Inserting this directory's parent at the front of `sys.path` makes
the import resolve to the sources beside these tests. This has to happen
before the package is imported, hence at the top of the file.
"""

import sys
from pathlib import Path

_PYTHON_ROOT = Path(__file__).resolve().parent.parent
# `not sys.path` matters: guarding on a truthy sys.path meant an empty
# one skipped the insert entirely, which is the one case where the
# import would certainly have resolved elsewhere or not at all.
if not sys.path or sys.path[0] != str(_PYTHON_ROOT):
    sys.path.insert(0, str(_PYTHON_ROOT))

import pytest  # noqa: E402
from traning_cli.settings import get_settings  # noqa: E402


@pytest.fixture(autouse=True)
def _clear_settings_cache():
    """Force a fresh Settings() read for every test.

    get_settings() is memoized (lru_cache) for production use, but tests
    routinely monkeypatch env vars per-test — without clearing the cache,
    later tests would see the first test's stale, cached Settings.
    """
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def traning_data_dir(tmp_path, monkeypatch):
    """Point TRANING_DATA at an isolated temp directory for this test."""
    monkeypatch.setenv("TRANING_DATA", str(tmp_path))
    get_settings.cache_clear()
    return tmp_path

