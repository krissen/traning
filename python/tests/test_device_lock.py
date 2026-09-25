"""Tests for the devices.csv cross-process write lock (devices/log.py).

write_devices() is atomic on its own (tmp file + os.replace), but the
read-modify-write in add_device()/add_devices_bulk() needs the
exclusive flock in _locked_devices — otherwise two concurrent writers
(the traning-garmin.timer fetch and a manual `device add`) can both
read the same state and the second write silently drops the first
one's row.
"""

import logging
import multiprocessing
from pathlib import Path

import pytest
from traning_cli.devices import log as devices_log
from traning_cli.devices.log import DeviceLogLockTimeout, add_device, read_devices

TCX_WITH_CREATOR = b"""<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Activities>
    <Activity Sport="Running">
      <Id>2023-12-29T05:48:33.000Z</Id>
      <Creator xsi:type="Device_t">
        <Name>Forerunner 945</Name>
        <Version><VersionMajor>13</VersionMajor><VersionMinor>0</VersionMinor></Version>
      </Creator>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
"""


def _spec(i):
    return {
        "platform": "garmin",
        "model": f"Forerunner {900 + i}",
        "os_version": str(10 + i),
        "valid_from": f"2023-01-{(i % 28) + 1:02d}",
        "certainty": "exact",
        "origin": "tcx",
        "note": f"lock-test {i}",
    }


def _add_rows_worker(data_dir_str, specs):
    """Multiprocessing target: add rows one at a time, like concurrent writers do."""
    data_dir = Path(data_dir_str)
    for spec in specs:
        add_device(data_dir, **spec)


def test_concurrent_writers_keep_all_rows(data_dir):
    """(a) Two processes adding different rows at once: both rows survive."""
    # Fork, not spawn: a spawned child would import traning_cli from the
    # installed editable copy (the main checkout), not the worktree under
    # test — fork inherits this process's already-imported modules.
    ctx = multiprocessing.get_context("fork")
    batches = ([_spec(1), _spec(2), _spec(3)], [_spec(4), _spec(5), _spec(6)])
    procs = [ctx.Process(target=_add_rows_worker, args=(str(data_dir), b)) for b in batches]
    for proc in procs:
        proc.start()
    for proc in procs:
        proc.join(60)
        assert proc.exitcode == 0

    models = {row["model"] for row in read_devices(data_dir)}
    assert {f"Forerunner {900 + i}" for i in (1, 2, 3, 4, 5, 6)} <= models


def test_add_device_times_out_with_clear_error(data_dir):
    """(b) A held lock: add_device raises, naming the file and the wait."""
    with (
        devices_log._locked_devices(data_dir, timeout=60),
        pytest.raises(DeviceLogLockTimeout, match=r"devices\.csv.*0\.2 s"),
    ):
        add_device(
            data_dir,
            platform="garmin",
            model="Forerunner 945",
            os_version="13",
            valid_from="2023-01-01",
            lock_timeout=0.2,
        )
    assert read_devices(data_dir) == []


def test_hook_warns_instead_of_raising_on_lock_timeout(data_dir, monkeypatch, caplog):
    """(b) The fetch hook never fails a fetch: a lock timeout is a warning."""
    from traning_cli.garmin import download as dl

    tcx_path = data_dir / "kristian" / "filer" / "gconnect" / "2023-12-29T05:48:33+00:00_555.tcx"
    tcx_path.write_bytes(TCX_WITH_CREATOR)
    monkeypatch.setattr(devices_log, "LOCK_TIMEOUT_SECONDS", 0.2)

    with devices_log._locked_devices(data_dir, timeout=60), caplog.at_level(logging.WARNING):
        dl._log_device_from_tcx(
            tcx_path,
            activity_date="2023-12-29",
            start_time_local="2023-12-29 06:48:33",
        )

    assert "Could not update device log" in caplog.text
    assert read_devices(data_dir) == []
