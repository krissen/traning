"""Shared pytest fixtures for the traning_cli test suite."""

import pytest


@pytest.fixture
def traning_data_dir(tmp_path, monkeypatch):
    """Point TRANING_DATA at an isolated temp directory for this test."""
    monkeypatch.setenv("TRANING_DATA", str(tmp_path))
    return tmp_path
