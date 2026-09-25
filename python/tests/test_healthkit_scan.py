"""Tests for devices/healthkit_scan.py — streaming Apple Health export parsing."""

import io
import zipfile
from pathlib import Path

import pytest
from traning_cli.devices import healthkit_scan


def _record(start_date: str, hardware: str | None, software: str = "", tag: str = "Record") -> str:
    """Build one <Record>/<Workout> element with (or without) a device attribute."""
    if hardware is None:
        device_attr = ""
    else:
        # "<" and ">" must be entity-escaped in an XML attribute value —
        # the real export.xml does the same; ElementTree hands back the
        # unescaped "<<HKDevice: ...>" form via elem.get("device").
        device = (
            f"&lt;&lt;HKDevice: 0x1&gt;, name:Apple Watch, manufacturer:Apple Inc., "
            f"model:Watch, hardware:{hardware}, software:{software}, "
            f"creation date:{start_date}&gt;"
        )
        device_attr = f'device="{device}" '
    extra = (
        'type="HKQuantityTypeIdentifierHeartRate" unit="count/min" value="60" '
        if tag == "Record"
        else ""
    )
    return (
        f'<{tag} {extra}sourceName="Apple Watch" sourceVersion="{software}" {device_attr}'
        f'creationDate="{start_date}" startDate="{start_date}" endDate="{start_date}"/>'
    )


def _record_with_dates(
    *,
    start_date: str,
    creation_date: str | None,
    hardware: str,
    software: str = "",
    tag: str = "Record",
) -> str:
    """Like ``_record``, but with independently settable startDate/creationDate.

    ``creation_date=None`` omits the attribute entirely (to exercise the
    startDate fallback).
    """
    device = (
        f"&lt;&lt;HKDevice: 0x1&gt;, name:Apple Watch, manufacturer:Apple Inc., "
        f"model:Watch, hardware:{hardware}, software:{software}, "
        f"creation date:{creation_date or start_date}&gt;"
    )
    extra = (
        'type="HKQuantityTypeIdentifierHeartRate" unit="count/min" value="60" '
        if tag == "Record"
        else ""
    )
    creation_attr = f'creationDate="{creation_date}" ' if creation_date is not None else ""
    return (
        f'<{tag} {extra}sourceName="Apple Watch" sourceVersion="{software}" '
        f'device="{device}" {creation_attr}startDate="{start_date}" endDate="{start_date}"/>'
    )


def _write_export(
    zip_path, record_elements: list[str], *, xml_member="apple_health_export/export.xml"
):
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<HealthData locale="en_US">\n'
        + "\n".join(record_elements)
        + "\n</HealthData>\n"
    )
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr(xml_member, xml)
    return zip_path


# --- scan_export: device-field parsing ---------------------------------------


def test_scan_export_extracts_watch_hardware_and_software(tmp_path):
    export = _write_export(
        tmp_path / "export-2026-01-01.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert stats.elements_scanned == 1
    assert stats.ok == 1
    assert stats.groups == 1
    assert len(records) == 1
    assert records[0].model == "Apple Watch Ultra (gen 1)"
    assert records[0].os_version == "10.1"
    assert records[0].activity_date.isoformat() == "2023-06-15"


def test_scan_export_reads_workout_elements_too(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1", tag="Workout")],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert stats.ok == 1
    assert records[0].model == "Apple Watch Ultra (gen 1)"


def test_scan_export_skips_records_without_device(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", None)],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert records == []
    assert stats.skipped_no_device == 1
    assert stats.ok == 0


def test_scan_export_skips_non_watch_devices(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", "iPhone14,2", "17.0")],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert records == []
    assert stats.skipped_non_watch == 1


def test_scan_export_skips_unparseable_and_implausible_dates(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record("not-a-date", "Watch6,18", "10.1"),
            _record("2061-01-01 08:00:00 +0000", "Watch6,18", "10.1"),
        ],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert records == []
    assert stats.skipped_bad_date == 2
    assert len(stats.bad_date_examples) == 2


# --- hardware comma pitfall ---------------------------------------------------
#
# The device attribute is a ", "-joined key:value list, but the hardware
# value itself contains a bare comma ("Watch6,18") with no following
# space — a naive split/regex on "," alone would truncate it to "Watch6".


def test_scan_export_hardware_comma_is_not_a_field_separator(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")],
    )

    records, _stats = healthkit_scan.scan_export(export)

    assert records[0].model == "Apple Watch Ultra (gen 1)"  # not "Watch6"


# --- timezone handling: local date, not UTC -----------------------------------


def test_scan_export_uses_local_date_not_utc():
    # startDate carries an explicit offset; the date must be taken as
    # written (local), not converted to UTC first. 23:30 +0100 is
    # already the next UTC day — if this used UTC the activity_date
    # would be one day later than the local calendar day.
    local = "2023-06-15 23:30:00 +0100"
    record_dt = healthkit_scan._parse_local_datetime(local)
    assert record_dt.date().isoformat() == "2023-06-15"


def test_scan_export_activity_date_matches_local_wall_clock_day(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 23:30:00 +0100", "Watch6,18", "10.1")],
    )

    records, _stats = healthkit_scan.scan_export(export)

    assert records[0].activity_date.isoformat() == "2023-06-15"


# --- creationDate over startDate (Nagelfar issue-002) --------------------------


def test_scan_export_uses_creation_date_not_start_date_for_interval_sample(tmp_path):
    # A BasalEnergyBurned-style interval sample: startDate is still the
    # previous day (23:50), but the firmware only wrote the sample once
    # the update had installed, just after midnight — creationDate is
    # the true "software active since" signal, not startDate.
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record_with_dates(
                start_date="2023-06-14 23:50:00 +0000",
                creation_date="2023-06-15 00:10:00 +0000",
                hardware="Watch6,18",
                software="9.2",
            )
        ],
    )

    records, _stats = healthkit_scan.scan_export(export)

    assert records[0].activity_date.isoformat() == "2023-06-15"  # not 2023-06-14


def test_scan_export_falls_back_to_start_date_when_creation_date_missing(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record_with_dates(
                start_date="2023-06-15 08:00:00 +0000",
                creation_date=None,
                hardware="Watch6,18",
                software="9.2",
            )
        ],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert stats.ok == 1
    assert records[0].activity_date.isoformat() == "2023-06-15"


# --- same-day ordering by full datetime (Nagelfar issue-002, point 2) ----------


def test_scan_and_collapse_orders_same_day_versions_by_full_datetime(tmp_path):
    # Both rows land on the Ultra's first day (2022-10-06): setup on
    # 9.0.1, then an update to 9.1 later the same day. The date-only key
    # must not scramble that — the earlier time must come out first.
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record("2022-10-06 18:00:00 +0000", "Watch6,18", "9.1"),
            _record("2022-10-06 08:00:00 +0000", "Watch6,18", "9.0.1"),
        ],
    )

    candidates, _stats = healthkit_scan.scan_and_collapse(export_path=export)

    assert [c["os_version"] for c in candidates] == ["9.0.1", "9.1"]
    assert all(c["valid_from"] == "2022-10-06" for c in candidates)


# --- earliest-date-wins collapse per (hardware, software) ---------------------


def test_scan_export_keeps_earliest_date_per_hardware_software_pair(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record("2023-08-01 08:00:00 +0000", "Watch6,18", "10.1"),
            _record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1"),  # earlier — wins
            _record("2023-07-01 08:00:00 +0000", "Watch6,18", "10.1"),
        ],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert stats.groups == 1
    assert stats.ok == 3
    assert len(records) == 1
    assert records[0].activity_date.isoformat() == "2023-06-15"


def test_scan_export_separates_different_software_versions(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record("2023-06-01 08:00:00 +0000", "Watch6,18", "9.6"),
            _record("2023-09-01 08:00:00 +0000", "Watch6,18", "10.1"),
        ],
    )

    records, stats = healthkit_scan.scan_export(export)

    assert stats.groups == 2
    versions = {r.os_version for r in records}
    assert versions == {"9.6", "10.1"}


# --- unknown hardware identifier: left as raw string ---------------------------


def test_scan_export_unknown_watch_hardware_kept_as_raw_string(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch99,99", "20.0")],
    )

    records, _stats = healthkit_scan.scan_export(export)

    assert records[0].model == "Watch99,99"  # not in WATCH_HARDWARE_NAMES, kept raw


# --- root.clear() bound (Nagelfar issue-001) -----------------------------------
#
# elem.clear() only empties the matched element itself; without also
# clearing the root <HealthData>, root's child list grows by one entry
# per element regardless of tag, so len(root) right before each clear
# would climb with the element count if the bug were present. It must
# stay flat (small, constant) instead, for any number of elements.


def _xml_stream(record_elements: list[str]):
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<HealthData locale="en_US">\n'
        + "\n".join(record_elements)
        + "\n</HealthData>\n"
    )
    return io.BytesIO(xml.encode("utf-8"))


def test_root_child_count_stays_bounded_regardless_of_element_count():
    # iterparse's underlying parser feeds input in fixed-size read
    # chunks, and can append every element from a whole chunk to root
    # before yielding the first event back to us — so len(root), probed
    # right before each clear, isn't pinned at exactly 1. What matters is
    # that its *peak* is a function of the (constant) read-chunk size,
    # not of the element count: without root.clear(), it would instead
    # climb to n and stay there. 100x more elements must not move the
    # peak by anything close to 100x.
    def _run(n: int) -> int:
        records = [
            _record(f"2023-01-{(i % 28) + 1:02d} 08:00:00 +0000", "Watch6,18", "10.1")
            for i in range(n)
        ]
        stats = healthkit_scan.HealthKitScanStats()
        earliest: dict = {}
        seen_lengths: list[int] = []
        healthkit_scan._scan_xml_stream(
            _xml_stream(records),
            Path("synthetic.xml"),
            stats,
            earliest,
            _root_len_probe=seen_lengths.append,
        )
        assert stats.ok == n
        return max(seen_lengths)

    max_len_small = _run(50)
    max_len_large = _run(5000)

    assert max_len_large < max_len_small * 3
    assert max_len_large < 5000 / 10  # nowhere near proportional to n


# --- collapse_changes / scan_and_collapse: origin/platform -------------------


def test_scan_and_collapse_marks_platform_apple_watch_and_origin_healthkit(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")],
    )

    candidates, stats = healthkit_scan.scan_and_collapse(export_path=export)

    assert stats.ok == 1
    assert len(candidates) == 1
    assert candidates[0]["platform"] == "apple_watch"
    assert candidates[0]["origin"] == "healthkit"
    assert candidates[0]["certainty"] == "exact"


def test_scan_and_collapse_multiple_device_changes_sorted_by_date(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [
            _record("2024-01-01 08:00:00 +0000", "Watch7,5", "11.0"),
            _record("2022-01-01 08:00:00 +0000", "Watch6,18", "9.0"),
        ],
    )

    candidates, _stats = healthkit_scan.scan_and_collapse(export_path=export)

    assert [c["valid_from"] for c in candidates] == ["2022-01-01", "2024-01-01"]
    assert [c["model"] for c in candidates] == [
        "Apple Watch Ultra (gen 1)",
        "Apple Watch Ultra (gen 2)",
    ]


# --- input formats: zip, bare export.xml, directory ---------------------------


def test_scan_export_accepts_plain_export_xml_file(tmp_path):
    xml_path = tmp_path / "export.xml"
    xml_path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<HealthData locale="en_US">\n'
        + _record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")
        + "\n</HealthData>\n"
    )

    records, stats = healthkit_scan.scan_export(xml_path)

    assert stats.ok == 1
    assert records[0].model == "Apple Watch Ultra (gen 1)"


def test_resolve_export_input_file_returned_as_is(tmp_path):
    xml_path = tmp_path / "export.xml"
    xml_path.write_text("<HealthData/>")

    assert healthkit_scan.resolve_export_input(xml_path) == xml_path


def test_resolve_export_input_directory_finds_nested_apple_health_export(tmp_path):
    nested_dir = tmp_path / "apple_health_export"
    nested_dir.mkdir()
    xml_path = nested_dir / "export.xml"
    xml_path.write_text("<HealthData/>")

    assert healthkit_scan.resolve_export_input(tmp_path) == xml_path


def test_resolve_export_input_directory_finds_direct_export_xml(tmp_path):
    xml_path = tmp_path / "export.xml"
    xml_path.write_text("<HealthData/>")

    assert healthkit_scan.resolve_export_input(tmp_path) == xml_path


def test_resolve_export_input_directory_falls_back_to_newest_zip(tmp_path):
    (tmp_path / "export-2025-01-01.zip").write_bytes(b"")
    newest = tmp_path / "export-2026-01-01.zip"
    newest.write_bytes(b"")

    assert healthkit_scan.resolve_export_input(tmp_path) == newest


def test_resolve_export_input_prefers_nested_over_zip(tmp_path):
    nested_dir = tmp_path / "apple_health_export"
    nested_dir.mkdir()
    xml_path = nested_dir / "export.xml"
    xml_path.write_text("<HealthData/>")
    (tmp_path / "export.zip").write_bytes(b"")

    assert healthkit_scan.resolve_export_input(tmp_path) == xml_path


def test_resolve_export_input_empty_directory_returns_none(tmp_path):
    assert healthkit_scan.resolve_export_input(tmp_path) is None


def test_resolve_export_input_nonexistent_path_returns_none(tmp_path):
    assert healthkit_scan.resolve_export_input(tmp_path / "nope") is None


def test_scan_and_collapse_accepts_directory_input(tmp_path):
    nested_dir = tmp_path / "apple_health_export"
    nested_dir.mkdir()
    (nested_dir / "export.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<HealthData locale="en_US">\n'
        + _record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")
        + "\n</HealthData>\n"
    )

    candidates, stats = healthkit_scan.scan_and_collapse(export_path=tmp_path)

    assert stats is not None
    assert stats.ok == 1
    assert len(candidates) == 1


# --- default lookup: $TRANING_HEALTHKIT_EXPORTS, newest dated subdirectory ----


def test_default_export_root_none_without_env_var(monkeypatch):
    monkeypatch.delenv(healthkit_scan.HEALTHKIT_EXPORTS_ENV, raising=False)
    assert healthkit_scan.default_export_root() is None


def test_default_export_root_reads_env_var(monkeypatch, tmp_path):
    monkeypatch.setenv(healthkit_scan.HEALTHKIT_EXPORTS_ENV, str(tmp_path))
    assert healthkit_scan.default_export_root() == tmp_path


def test_find_latest_export_missing_dir_returns_none(tmp_path):
    assert healthkit_scan.find_latest_export(tmp_path / "nope") is None


def test_find_latest_export_ignores_non_date_named_subdirectories(tmp_path):
    (tmp_path / "not-a-date").mkdir()
    (tmp_path / "not-a-date" / "export.xml").write_text("<HealthData/>")

    assert healthkit_scan.find_latest_export(tmp_path) is None


def test_find_latest_export_picks_newest_dated_subdirectory(tmp_path):
    for day in ("2025-01-01", "2026-03-15", "2024-12-31"):
        date_dir = tmp_path / day / "apple_health_export"
        date_dir.mkdir(parents=True)
        (date_dir / "export.xml").write_text("<HealthData/>")

    latest = healthkit_scan.find_latest_export(tmp_path)

    assert latest == tmp_path / "2026-03-15" / "apple_health_export" / "export.xml"


def test_find_latest_export_dated_subdirectory_with_zip(tmp_path):
    date_dir = tmp_path / "2026-01-01"
    date_dir.mkdir(parents=True)
    (date_dir / "export.zip").write_bytes(b"")

    latest = healthkit_scan.find_latest_export(tmp_path)

    assert latest == date_dir / "export.zip"


def test_scan_and_collapse_uses_env_var_default(monkeypatch, tmp_path):
    export_root = tmp_path / "healthkit-exports"
    date_dir = export_root / "2026-01-01" / "apple_health_export"
    date_dir.mkdir(parents=True)
    (date_dir / "export.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<HealthData locale="en_US">\n'
        + _record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")
        + "\n</HealthData>\n"
    )
    monkeypatch.setenv(healthkit_scan.HEALTHKIT_EXPORTS_ENV, str(export_root))

    candidates, stats = healthkit_scan.scan_and_collapse()

    assert stats is not None
    assert stats.export_path == date_dir / "export.xml"
    assert len(candidates) == 1


# --- missing export: source works without one ---------------------------------


def test_scan_and_collapse_returns_none_stats_when_no_export_present(monkeypatch, tmp_path):
    monkeypatch.delenv(healthkit_scan.HEALTHKIT_EXPORTS_ENV, raising=False)

    candidates, stats = healthkit_scan.scan_and_collapse()

    assert candidates == []
    assert stats is None


def test_scan_and_collapse_env_var_set_but_no_dated_subdirs_is_skipped(monkeypatch, tmp_path):
    export_root = tmp_path / "healthkit-exports"
    export_root.mkdir()
    monkeypatch.setenv(healthkit_scan.HEALTHKIT_EXPORTS_ENV, str(export_root))

    candidates, stats = healthkit_scan.scan_and_collapse()

    assert candidates == []
    assert stats is None


# --- malformed export: raises, doesn't silently skip ---------------------------


def test_scan_export_raises_if_export_xml_member_missing(tmp_path):
    zip_path = tmp_path / "export.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("apple_health_export/export_cda.xml", "<HealthData/>")

    with pytest.raises(ValueError, match=r"export\.xml"):
        healthkit_scan.scan_export(zip_path)


def test_scan_export_raises_on_malformed_xml(tmp_path):
    import xml.etree.ElementTree as ET

    zip_path = tmp_path / "export.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("apple_health_export/export.xml", "<HealthData><Record")

    with pytest.raises(ET.ParseError):
        healthkit_scan.scan_export(zip_path)
