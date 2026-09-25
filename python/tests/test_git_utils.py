"""Tests for git_utils.git_commit_paths — the helper shared by
server/storage.py::commit_health_data and main.py::_commit_data."""

import subprocess

from traning_cli.git_utils import git_commit_paths


def _init_repo(path):
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=path, check=True)
    # Need an initial commit so `git diff --cached --quiet` has a HEAD to
    # diff against on the first real commit too.
    (path / ".gitkeep").write_text("")
    subprocess.run(["git", "add", ".gitkeep"], cwd=path, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=path, check=True)


def _log_messages(path):
    result = subprocess.run(
        ["git", "log", "--format=%s"],
        cwd=path,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip().splitlines()


def test_git_commit_paths_creates_commit_with_message(tmp_path):
    _init_repo(tmp_path)
    (tmp_path / "data.txt").write_text("hello")

    committed = git_commit_paths(tmp_path, ["data.txt"], "(test) Add data")

    assert committed is True
    assert _log_messages(tmp_path)[0] == "(test) Add data"


def test_git_commit_paths_nothing_to_commit_is_noop(tmp_path):
    _init_repo(tmp_path)
    before = _log_messages(tmp_path)

    committed = git_commit_paths(tmp_path, ["nonexistent/"], "(test) Nothing")

    assert committed is False
    assert _log_messages(tmp_path) == before


def test_git_commit_paths_second_call_with_no_new_changes_is_noop(tmp_path):
    _init_repo(tmp_path)
    (tmp_path / "data.txt").write_text("hello")

    first = git_commit_paths(tmp_path, ["data.txt"], "(test) Add data")
    second = git_commit_paths(tmp_path, ["data.txt"], "(test) Add data again")

    assert first is True
    assert second is False
    assert _log_messages(tmp_path)[0] == "(test) Add data"


def test_git_commit_paths_ignores_missing_path_alongside_a_real_change(tmp_path):
    """A path that doesn't exist yet (e.g. devices.csv before its first
    write) must not sink the whole `git add` — the paths that do have
    new content still get committed."""
    _init_repo(tmp_path)
    (tmp_path / "data.txt").write_text("hello")

    committed = git_commit_paths(tmp_path, ["data.txt", "kristian/devices.csv"], "(test) Add data")

    assert committed is True
    assert _log_messages(tmp_path)[0] == "(test) Add data"
