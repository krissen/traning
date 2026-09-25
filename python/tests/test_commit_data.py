"""Tests for main._commit_data — the Garmin-fetch commit path.

Regression coverage for the finding that devices.csv (written by the
post-fetch device-log hook, garmin/download.py::_log_device_from_tcx)
was never staged: _commit_data only listed the gconnect/ and tcx/
paths, so every hook-written row stayed an uncommitted working-tree
change forever on a host that never runs `device add`/`device scan
--apply` by hand.
"""

import subprocess

from traning_cli.main import _commit_data


def _init_repo(path):
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=path, check=True)
    (path / ".gitkeep").write_text("")
    subprocess.run(["git", "add", ".gitkeep"], cwd=path, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=path, check=True)


def _committed_files(path):
    result = subprocess.run(
        ["git", "show", "--name-only", "--format=", "HEAD"],
        cwd=path,
        check=True,
        capture_output=True,
        text=True,
    )
    return set(result.stdout.strip().splitlines())


def test_commit_data_stages_devices_csv_when_present(tmp_path):
    _init_repo(tmp_path)
    (tmp_path / "kristian" / "filer" / "gconnect").mkdir(parents=True)
    (tmp_path / "kristian" / "filer" / "gconnect" / "activity.tcx").write_text("<tcx/>")
    (tmp_path / "kristian" / "devices.csv").write_text(
        "valid_from,platform,model,os_version,certainty,origin,note\n"
        "2020-01-01,garmin,Forerunner 945,13.7,exact,tcx,fetch: x.tcx\n"
    )

    _commit_data(tmp_path, 1)

    assert "kristian/devices.csv" in _committed_files(tmp_path)


def test_commit_data_does_not_fail_when_devices_csv_absent(tmp_path):
    """No device-log row was ever written yet — devices.csv doesn't
    exist. The activity files must still get committed."""
    _init_repo(tmp_path)
    (tmp_path / "kristian" / "filer" / "gconnect").mkdir(parents=True)
    (tmp_path / "kristian" / "filer" / "gconnect" / "activity.tcx").write_text("<tcx/>")

    _commit_data(tmp_path, 1)

    committed = _committed_files(tmp_path)
    assert "kristian/filer/gconnect/activity.tcx" in committed
    assert "kristian/devices.csv" not in committed
