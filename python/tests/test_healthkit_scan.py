"""Tests for devices/healthkit_scan.py — streaming Apple Health export parsing."""

import zipfile

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
    record_date = healthkit_scan._parse_local_date(local)
    assert record_date.isoformat() == "2023-06-15"


def test_scan_export_activity_date_matches_local_wall_clock_day(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 23:30:00 +0100", "Watch6,18", "10.1")],
    )

    records, _stats = healthkit_scan.scan_export(export)

    assert records[0].activity_date.isoformat() == "2023-06-15"


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


# --- collapse_changes / scan_and_collapse: origin/platform -------------------


def test_scan_and_collapse_marks_platform_apple_watch_and_origin_healthkit(tmp_path):
    export = _write_export(
        tmp_path / "export.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")],
    )

    candidates, stats = healthkit_scan.scan_and_collapse(tmp_path, export_path=export)

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

    candidates, _stats = healthkit_scan.scan_and_collapse(tmp_path, export_path=export)

    assert [c["valid_from"] for c in candidates] == ["2022-01-01", "2024-01-01"]
    assert [c["model"] for c in candidates] == [
        "Apple Watch Ultra (gen 1)",
        "Apple Watch Ultra (gen 2)",
    ]


# --- missing export: source works without one ---------------------------------


def test_scan_and_collapse_returns_none_stats_when_no_export_present(tmp_path):
    candidates, stats = healthkit_scan.scan_and_collapse(tmp_path)

    assert candidates == []
    assert stats is None


def test_find_latest_export_missing_dir_returns_none(tmp_path):
    assert healthkit_scan.find_latest_export(tmp_path / "nope") is None


def test_find_latest_export_picks_newest_by_name(tmp_path):
    export_dir = tmp_path / "kristian" / "apple_health_export"
    export_dir.mkdir(parents=True)
    (export_dir / "export-2025-01-01.zip").write_bytes(b"")
    (export_dir / "export-2026-03-15.zip").write_bytes(b"")
    (export_dir / "export-2024-12-31.zip").write_bytes(b"")

    latest = healthkit_scan.find_latest_export(export_dir)

    assert latest.name == "export-2026-03-15.zip"


def test_scan_and_collapse_finds_default_export_path(tmp_path):
    export_dir = tmp_path / "kristian" / "apple_health_export"
    export_dir.mkdir(parents=True)
    _write_export(
        export_dir / "export-2026-01-01.zip",
        [_record("2023-06-15 08:00:00 +0000", "Watch6,18", "10.1")],
    )

    candidates, stats = healthkit_scan.scan_and_collapse(tmp_path)

    assert stats is not None
    assert stats.export_path.name == "export-2026-01-01.zip"
    assert len(candidates) == 1


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
