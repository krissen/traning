"""Shared pytest fixtures for the traning_cli test suite."""

import pytest
from traning_cli.settings import get_settings


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
