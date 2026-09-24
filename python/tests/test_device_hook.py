"""Tests for the post-download device-log hook in garmin/download.py.

The live Garmin fetch downloads TCX (not FIT — see devices/tcx_scan.py's
module docstring), so a successful TCX download best-effort logs a
device-change row if the TCX's <Creator> differs from what's already on
file. This must never fail the download it's attached to.
"""

from traning_cli.devices.log import read_devices
from traning_cli.garmin import download as dl

ACTIVITY = {
    "activityId": 555,
    "activityName": "Morning Run",
    "startTimeGMT": "2023-12-29 05:48:33",
}

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


class FakeGarminClient:
    def __init__(self, tcx=TCX_WITH_CREATOR):
        self._tcx = tcx

    def get_activity(self, activity_id):
        return {"activityId": activity_id, "detail": True}

    def download_activity(self, activity_id):
        return self._tcx


def test_successful_tcx_download_logs_new_device(data_dir):
    gc_dir = dl.gconnect_dir(data_dir)
    tc_dir = dl.tcx_dir(data_dir)
    client = FakeGarminClient()

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is True
    rows = read_devices(data_dir)
    assert len(rows) == 1
    assert rows[0] == {
        "valid_from": "2023-12-29",
        "platform": "garmin",
        "model": "Forerunner 945",
        "os_version": "13.0",
        "certainty": "exact",
        "origin": "fit",
        "note": "fetch: 2023-12-29T05:48:33+00:00_555.tcx",
    }


def test_second_activity_same_device_does_not_duplicate(data_dir):
    gc_dir = dl.gconnect_dir(data_dir)
    tc_dir = dl.tcx_dir(data_dir)
    client = FakeGarminClient()

    dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)
    second = dict(ACTIVITY, activityId=556, startTimeGMT="2023-12-30 06:00:00")
    dl._download_activity(client, second, gc_dir, tc_dir)

    assert len(read_devices(data_dir)) == 1


def test_tcx_without_creator_does_not_touch_device_log(data_dir):
    gc_dir = dl.gconnect_dir(data_dir)
    tc_dir = dl.tcx_dir(data_dir)
    client = FakeGarminClient(tcx=b"<TrainingCenterDatabase/>")

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is True
    assert read_devices(data_dir) == []


def test_malformed_tcx_does_not_fail_download(data_dir):
    """A device-log failure (malformed XML) must not affect the download result."""
    gc_dir = dl.gconnect_dir(data_dir)
    tc_dir = dl.tcx_dir(data_dir)
    client = FakeGarminClient(tcx=b"<broken")

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is True
    assert read_devices(data_dir) == []


def test_device_log_write_failure_does_not_fail_download(data_dir, monkeypatch):
    """Even a broken devices.csv on disk must not fail the TCX download."""
    from traning_cli.devices import log as devices_log

    def raising_add_device(*a, **k):
        raise OSError("disk full")

    monkeypatch.setattr(devices_log, "add_device", raising_add_device)

    gc_dir = dl.gconnect_dir(data_dir)
    tc_dir = dl.tcx_dir(data_dir)
    client = FakeGarminClient()

    ok = dl._download_activity(client, ACTIVITY, gc_dir, tc_dir)

    assert ok is True
