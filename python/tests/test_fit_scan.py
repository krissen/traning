"""Tests for devices/fit_scan.py.

fitparse messages are mocked (no binary FIT fixture needed): a FakeFitFile
stands in for fitparse.FitFile, and FakeMessage/FakeField mimic just
enough of the fitparse API (``msg.name`` and iterating fields with
``.name``/``.value``) for parse_fit_device() to work against it.
"""

from datetime import date, datetime
from pathlib import Path
from typing import ClassVar

import pytest
from traning_cli.devices import fit_scan


class FakeField:
    def __init__(self, name, value):
        self.name = name
        self.value = value


class FakeMessage:
    def __init__(self, name, fields: dict):
        self.name = name
        self._fields = [FakeField(k, v) for k, v in fields.items()]

    def __iter__(self):
        return iter(self._fields)


class FakeFitFile:
    """Stands in for fitparse.FitFile: takes a canned message list."""

    _NEXT_MESSAGES: ClassVar[list[FakeMessage] | Exception] = []

    def __init__(self, path):
        self.path = path
        if isinstance(FakeFitFile._NEXT_MESSAGES, Exception):
            raise FakeFitFile._NEXT_MESSAGES
        self.messages = FakeFitFile._NEXT_MESSAGES


def _activity_messages(product="fr620", software_version=3.3, when=None, manufacturer="garmin"):
    when = when or datetime(2020, 7, 3, 9, 51, 2)
    return [
        FakeMessage(
            "file_id",
            {
                "manufacturer": manufacturer,
                "garmin_product": product,
                "time_created": when,
                "type": "activity",
            },
        ),
        FakeMessage(
            "device_info",
            {
                "device_index": "creator",
                "garmin_product": product,
                "software_version": software_version,
            },
        ),
        FakeMessage(
            "device_info",
            {
                "device_index": 3,
                "garmin_product": "hrm_run",
                "software_version": 66.0,
                "manufacturer": manufacturer,
            },
        ),
    ]


@pytest.fixture(autouse=True)
def _patch_fitfile(monkeypatch):
    monkeypatch.setattr(fit_scan, "fitparse", type("m", (), {"FitFile": FakeFitFile}))
    yield
    FakeFitFile._NEXT_MESSAGES = []


def _set_messages(msgs):
    FakeFitFile._NEXT_MESSAGES = msgs


# --- parse_fit_device -------------------------------------------------------


def test_parse_fit_device_extracts_model_version_date():
    _set_messages(_activity_messages(product="fr620", software_version=3.3))

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.model == "Forerunner 620"  # normalized from the raw "fr620" code
    assert record.os_version == "3.3"
    assert record.activity_date == date(2020, 7, 3)


def test_parse_fit_device_formats_integer_software_version_without_decimal():
    _set_messages(_activity_messages(software_version=3.0))

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.os_version == "3"


def test_parse_fit_device_skips_non_activity_file():
    msgs = _activity_messages()
    # Flip file_id.type to something other than "activity"
    for m in msgs:
        if m.name == "file_id":
            for f in m._fields:
                if f.name == "type":
                    f.value = "monitoring_a"
    _set_messages(msgs)

    assert fit_scan.parse_fit_device(Path("dummy.fit")) is None


def test_parse_fit_device_falls_back_to_numeric_product_id():
    msgs = [
        FakeMessage(
            "file_id",
            {
                "manufacturer": "garmin",
                "garmin_product": None,
                "product": 1689,
                "time_created": datetime(2020, 1, 1),
                "type": "activity",
            },
        )
    ]
    _set_messages(msgs)

    record = fit_scan.parse_fit_device(Path("dummy.fit"))
    assert record.model == "1689"


def test_parse_fit_device_raises_without_file_id():
    _set_messages([FakeMessage("record", {})])

    with pytest.raises(ValueError, match="file_id"):
        fit_scan.parse_fit_device(Path("dummy.fit"))


def test_parse_fit_device_raises_without_time_created():
    msgs = [
        FakeMessage(
            "file_id",
            {"manufacturer": "garmin", "garmin_product": "fr620", "type": "activity"},
        )
    ]
    _set_messages(msgs)

    with pytest.raises(ValueError, match="time_created"):
        fit_scan.parse_fit_device(Path("dummy.fit"))


# --- scan_fit_directory: corrupt / not-activity counters -------------------


def test_scan_fit_directory_counts_corrupt_and_not_activity(tmp_path, monkeypatch):
    (tmp_path / "a.FIT").write_bytes(b"")
    (tmp_path / "b.fit").write_bytes(b"")
    (tmp_path / "c.FIT").write_bytes(b"")
    (tmp_path / "notes.txt").write_bytes(b"")

    responses = {
        str(tmp_path / "a.FIT"): _activity_messages(product="fr620"),
        str(tmp_path / "b.fit"): FakeMessage(
            "file_id",
            {
                "manufacturer": "garmin",
                "garmin_product": "fr620",
                "time_created": datetime(2020, 1, 1),
                "type": "monitoring_a",
            },
        ),
        str(tmp_path / "c.FIT"): ValueError("corrupt"),
    }

    def fake_init(self, path):
        resp = responses[path]
        if isinstance(resp, Exception):
            raise resp
        self.messages = resp if isinstance(resp, list) else [resp]

    monkeypatch.setattr(FakeFitFile, "__init__", fake_init)

    records, stats = fit_scan.scan_fit_directory(tmp_path)

    assert stats.scanned == 3  # notes.txt excluded
    assert stats.ok == 1
    assert stats.skipped_not_activity == 1
    assert stats.corrupt == 1
    assert len(records) == 1


def test_scan_fit_directory_missing_dir_returns_empty(tmp_path):
    records, stats = fit_scan.scan_fit_directory(tmp_path / "does-not-exist")
    assert records == []
    assert stats.scanned == 0


def test_scan_fit_directory_follows_symlinks(tmp_path, monkeypatch):
    real_dir = tmp_path / "real"
    real_dir.mkdir()
    (real_dir / "x.FIT").write_bytes(b"")

    fit_dir = tmp_path / "fit"
    fit_dir.mkdir()
    (fit_dir / "link_to_real").symlink_to(real_dir)

    _set_messages(_activity_messages())

    records, stats = fit_scan.scan_fit_directory(fit_dir)

    assert stats.scanned == 1
    assert records[0].path == real_dir / "x.FIT" or "link_to_real" in str(records[0].path)


# --- collapse_changes -------------------------------------------------------


def test_collapse_changes_emits_one_row_per_change_including_first():
    records = [
        fit_scan.FitDeviceRecord(Path("f1"), date(2020, 1, 1), "fr620", "3.3"),
        fit_scan.FitDeviceRecord(Path("f2"), date(2020, 2, 1), "fr620", "3.3"),  # no change
        fit_scan.FitDeviceRecord(Path("f3"), date(2020, 3, 1), "fr620", "3.5"),  # os change
        fit_scan.FitDeviceRecord(Path("f4"), date(2020, 4, 1), "fr945", "13.0"),  # model change
    ]

    candidates = fit_scan.collapse_changes(records)

    assert [c["valid_from"] for c in candidates] == ["2020-01-01", "2020-03-01", "2020-04-01"]
    assert all(c["platform"] == "garmin" for c in candidates)
    assert all(c["origin"] == "fit" and c["certainty"] == "exact" for c in candidates)


def test_collapse_changes_sorts_out_of_order_input():
    records = [
        fit_scan.FitDeviceRecord(Path("f2"), date(2020, 3, 1), "fr945", "13.0"),
        fit_scan.FitDeviceRecord(Path("f1"), date(2020, 1, 1), "fr620", "3.3"),
    ]

    candidates = fit_scan.collapse_changes(records)

    assert [c["valid_from"] for c in candidates] == ["2020-01-01", "2020-03-01"]


def test_collapse_changes_empty_input():
    assert fit_scan.collapse_changes([]) == []


# --- date sanity ------------------------------------------------------------


def test_scan_fit_directory_skips_implausible_future_date(tmp_path):
    (tmp_path / "a.FIT").write_bytes(b"")
    _set_messages(_activity_messages(when=datetime(2061, 3, 3)))

    records, stats = fit_scan.scan_fit_directory(tmp_path)

    assert records == []
    assert stats.ok == 0
    assert stats.skipped_bad_date == 1
    assert stats.bad_date_examples == ["2061-03-03  a.FIT"]


def test_scan_fit_directory_skips_implausible_pre_2000_date(tmp_path):
    (tmp_path / "a.FIT").write_bytes(b"")
    _set_messages(_activity_messages(when=datetime(1999, 1, 1)))

    records, stats = fit_scan.scan_fit_directory(tmp_path)

    assert records == []
    assert stats.skipped_bad_date == 1


# --- activity-local date ----------------------------------------------------
#
# A device change is dated by the wall-clock day where the activity
# happened (see devices/common.py), not by UTC's day boundary.


def test_parse_fit_device_converts_utc_to_stockholm_without_local_time():
    """23:30 UTC on a summer evening is already the next day locally."""
    _set_messages(_activity_messages(when=datetime(2023, 6, 15, 23, 30)))

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.activity_date == date(2023, 6, 16)


def test_parse_fit_device_prefers_activity_local_timestamp():
    """FIT activity.local_timestamp (wall-clock where the run happened)
    wins over both the UTC calendar date and the Stockholm conversion:
    00:30 UTC is the 30th in both, but the run happened on the 29th."""
    msgs = _activity_messages(when=datetime(2023, 12, 30, 0, 30))
    msgs.append(FakeMessage("activity", {"local_timestamp": datetime(2023, 12, 29, 19, 30)}))
    _set_messages(msgs)

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.activity_date == date(2023, 12, 29)


def test_parse_fit_device_falls_back_to_file_id_local_timestamp():
    """A local_timestamp on file_id itself (no activity message) also wins."""
    msgs = [
        FakeMessage(
            "file_id",
            {
                "manufacturer": "garmin",
                "garmin_product": "fr620",
                "time_created": datetime(2023, 12, 30, 0, 30),
                "local_timestamp": datetime(2023, 12, 29, 19, 30),
                "type": "activity",
            },
        )
    ]
    _set_messages(msgs)

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.activity_date == date(2023, 12, 29)


# --- local_timestamp sanity (Nagelfar F1) -----------------------------------
#
# A local_timestamp farther than any valid UTC offset (-12..+14 h) from
# time_created is a broken watch clock, not a timezone — seen in the
# archive as time_created in 2061 with a local_timestamp in 2017,
# which briefly invented a "connect" device row dated 2017-09-15.


def test_parse_fit_device_distrusts_far_off_local_timestamp():
    """Days apart with both dates plausible: fall back to Stockholm time."""
    msgs = _activity_messages(when=datetime(2023, 6, 15, 23, 30))
    msgs.append(FakeMessage("activity", {"local_timestamp": datetime(2023, 6, 10, 12, 0)}))
    _set_messages(msgs)

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.activity_date == date(2023, 6, 16)


def test_parse_fit_device_trusts_local_timestamp_at_the_boundary():
    """Exactly 14 h off is still a valid offset — trusted."""
    msgs = _activity_messages(when=datetime(2023, 6, 15, 23, 30))
    msgs.append(FakeMessage("activity", {"local_timestamp": datetime(2023, 6, 16, 13, 30)}))
    _set_messages(msgs)

    record = fit_scan.parse_fit_device(Path("dummy.fit"))

    assert record.activity_date == date(2023, 6, 16)


def test_scan_fit_directory_rejects_corrupt_time_created_despite_sane_local(tmp_path):
    """time_created in 2061 with a sane-looking 2017 local_timestamp:
    rejected as a bad date, like before local_timestamp existed."""
    (tmp_path / "a.FIT").write_bytes(b"")
    msgs = _activity_messages(
        product="connect", software_version=None, when=datetime(2061, 3, 3, 21, 46, 40)
    )
    msgs.append(FakeMessage("activity", {"local_timestamp": datetime(2017, 9, 15, 16, 35)}))
    _set_messages(msgs)

    records, stats = fit_scan.scan_fit_directory(tmp_path)

    assert records == []
    assert stats.ok == 0
    assert stats.skipped_bad_date == 1
