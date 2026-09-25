"""Tests for devices/log.py: read/write, validation, dedup."""

import pytest
from traning_cli.devices.log import (
    FIELDS,
    add_device,
    add_devices_bulk,
    devices_csv_path,
    read_devices,
    validate_row,
    write_devices,
)


def _row(**overrides):
    row = {
        "valid_from": "2020-01-01",
        "platform": "garmin",
        "model": "fr620",
        "os_version": "3.3",
        "certainty": "exact",
        "origin": "fit",
        "note": "",
    }
    row.update(overrides)
    return row


# --- validate_row ------------------------------------------------------


def test_validate_row_accepts_well_formed_row():
    validate_row(_row())  # must not raise


def test_validate_row_rejects_missing_field():
    row = _row()
    del row["origin"]
    with pytest.raises(ValueError, match="missing fields"):
        validate_row(row)


def test_validate_row_rejects_bad_date():
    with pytest.raises(ValueError, match="valid_from"):
        validate_row(_row(valid_from="01/01/2020"))


def test_validate_row_rejects_bad_platform():
    with pytest.raises(ValueError, match="platform"):
        validate_row(_row(platform="fitbit"))


def test_validate_row_rejects_bad_certainty():
    with pytest.raises(ValueError, match="certainty"):
        validate_row(_row(certainty="probably"))


def test_validate_row_rejects_bad_origin():
    with pytest.raises(ValueError, match="origin"):
        validate_row(_row(origin="ai"))


# --- read/write roundtrip -----------------------------------------------


def test_read_devices_missing_file_returns_empty_list(tmp_path):
    assert read_devices(tmp_path) == []


def test_write_then_read_roundtrip(tmp_path):
    rows = [_row(valid_from="2020-01-01"), _row(valid_from="2021-06-15", model="fr945")]
    write_devices(tmp_path, rows)

    read_back = read_devices(tmp_path)

    assert len(read_back) == 2
    assert {r["model"] for r in read_back} == {"fr620", "fr945"}
    assert devices_csv_path(tmp_path).is_file()


def test_write_devices_uses_atomic_replace(tmp_path):
    write_devices(tmp_path, [_row()])
    path = devices_csv_path(tmp_path)
    assert path.is_file()
    # No leftover tmp file
    assert list(path.parent.glob("*.tmp.*")) == []


def test_write_devices_rejects_invalid_row(tmp_path):
    with pytest.raises(ValueError):
        write_devices(tmp_path, [_row(platform="bogus")])
    # Nothing written on validation failure
    assert not devices_csv_path(tmp_path).exists()


def test_read_devices_validates_and_raises_on_corrupt_csv(tmp_path):
    path = devices_csv_path(tmp_path)
    path.parent.mkdir(parents=True)
    path.write_text(",".join(FIELDS) + "\n" + "2020-01-01,not_a_platform,x,y,exact,fit,\n")

    with pytest.raises(ValueError, match="platform"):
        read_devices(tmp_path)


# --- sort order: valid_from desc, then platform asc ----------------------


def test_write_devices_sorts_newest_first_then_platform(tmp_path):
    rows = [
        _row(valid_from="2019-01-01", platform="garmin", model="a"),
        _row(valid_from="2022-01-01", platform="garmin", model="b"),
        _row(valid_from="2022-01-01", platform="apple_watch", model="c"),
    ]
    write_devices(tmp_path, rows)

    ordered = read_devices(tmp_path)
    assert [(r["valid_from"], r["platform"]) for r in ordered] == [
        ("2022-01-01", "apple_watch"),
        ("2022-01-01", "garmin"),
        ("2019-01-01", "garmin"),
    ]


# --- add_device: dedup ----------------------------------------------------


def test_add_device_appends_new_row(tmp_path):
    row = add_device(tmp_path, platform="garmin", model="fr945", os_version="13.0")

    assert row is not None
    assert row["origin"] == "manual"
    assert read_devices(tmp_path) == [row]


def test_add_device_defaults_valid_from_to_today(tmp_path):
    import datetime

    row = add_device(tmp_path, platform="garmin", model="fr945", os_version="13.0")

    assert row["valid_from"] == datetime.date.today().isoformat()


def test_add_device_skips_exact_duplicate(tmp_path):
    add_device(
        tmp_path, platform="garmin", model="fr945", os_version="13.0", valid_from="2020-01-01"
    )

    second = add_device(
        tmp_path, platform="garmin", model="fr945", os_version="13.0", valid_from="2025-01-01"
    )

    assert second is None
    assert len(read_devices(tmp_path)) == 1


def test_add_device_does_not_dedup_different_os_version(tmp_path):
    add_device(tmp_path, platform="garmin", model="fr945", os_version="13.0")
    second = add_device(tmp_path, platform="garmin", model="fr945", os_version="14.0")

    assert second is not None
    assert len(read_devices(tmp_path)) == 2


def test_add_device_rejects_invalid_platform(tmp_path):
    with pytest.raises(ValueError):
        add_device(tmp_path, platform="fitbit", model="x")


# --- add_devices_bulk ------------------------------------------------------


def test_add_devices_bulk_skips_existing_and_within_batch_duplicates(tmp_path):
    add_device(
        tmp_path, platform="garmin", model="fr620", os_version="2.7", valid_from="2012-01-01"
    )

    candidates = [
        _row(valid_from="2012-01-01", model="fr620", os_version="2.7"),  # already on disk
        _row(valid_from="2015-01-01", model="fr620", os_version="3.3"),  # new
        _row(valid_from="2015-06-01", model="fr620", os_version="3.3"),  # dup within batch
    ]

    added, updated = add_devices_bulk(tmp_path, candidates)

    assert len(added) == 1
    assert added[0]["os_version"] == "3.3"
    assert updated == []
    assert len(read_devices(tmp_path)) == 2


def test_add_devices_bulk_no_candidates_is_noop(tmp_path):
    added, updated = add_devices_bulk(tmp_path, [])
    assert added == []
    assert updated == []
    assert read_devices(tmp_path) == []


# --- earliest-wins merge (Nagelfar issue-002) -------------------------------
#
# The same (platform, model, os_version) is only recorded once, but which
# valid_from and which certainty/origin/note it keeps must not depend on
# which caller happened to write the row first — the earliest evidence
# wins, matching merge_candidates()'s rule within a single scan.


def test_add_device_earlier_candidate_updates_existing_date(tmp_path):
    """Scenario from issue-002: the hook logs the newest activity's date
    first (exact/tcx); a later scan finds the same device/version from
    an earlier activity. The earlier date must win, not the one written
    first."""
    first = add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2024-12-24",
        certainty="exact",
        origin="tcx",
        note="fetch: newest.tcx",
    )
    assert first is not None

    second = add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2023-10-15",
        certainty="exact",
        origin="tcx",
        note="tcx-scan: oldest.tcx",
    )

    assert second is not None
    assert second["valid_from"] == "2023-10-15"
    rows = read_devices(tmp_path)
    assert len(rows) == 1
    assert rows[0]["valid_from"] == "2023-10-15"
    assert rows[0]["note"] == "tcx-scan: oldest.tcx"  # data-derived candidate wins the row


def test_add_device_later_candidate_does_not_move_date_forward(tmp_path):
    add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2023-10-15",
    )

    later = add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2024-12-24",
    )

    assert later is None
    rows = read_devices(tmp_path)
    assert len(rows) == 1
    assert rows[0]["valid_from"] == "2023-10-15"


def test_add_device_manual_earlier_guess_moves_date_but_keeps_exact_certainty(tmp_path):
    """A manual, merely-approximate candidate can still correct the date
    earlier, but must not downgrade a data-derived row's certainty/origin
    — a guess isn't better evidence than what's already on file."""
    add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2024-01-01",
        certainty="exact",
        origin="tcx",
        note="tcx-scan: x.tcx",
    )

    row = add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2023-06-01",
        certainty="known_since",
        origin="manual",
        note="jag minns att det var tidigare",
    )

    assert row is not None
    assert row["valid_from"] == "2023-06-01"
    assert row["certainty"] == "exact"  # kept — the manual guess isn't stronger evidence
    assert row["origin"] == "tcx"
    assert row["note"] == "tcx-scan: x.tcx"


def test_add_devices_bulk_earlier_candidate_in_batch_updates_existing_row(tmp_path):
    """Backlog scenario: a fetch batch (newest-first) yields several
    candidates for the same device/version; the earliest in the batch
    must win regardless of processing order."""
    add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2024-12-24",
        certainty="exact",
        origin="tcx",
        note="fetch: newest.tcx",
    )

    candidates = [
        _row(
            platform="garmin",
            model="Forerunner 945",
            os_version="13.7",
            valid_from="2024-11-01",
            certainty="exact",
            origin="tcx",
            note="fetch: middle.tcx",
        ),
        _row(
            platform="garmin",
            model="Forerunner 945",
            os_version="13.7",
            valid_from="2024-10-01",
            certainty="exact",
            origin="tcx",
            note="fetch: oldest.tcx",
        ),
    ]

    added, updated = add_devices_bulk(tmp_path, candidates)

    # Each candidate in turn is earlier than what's on file at that point,
    # so both register as an update — the row's date ratchets backwards
    # twice (12-24 -> 11-01 -> 10-01) rather than needing the batch
    # pre-sorted.
    assert added == []
    assert len(updated) == 2
    assert updated[-1]["valid_from"] == "2024-10-01"
    rows = read_devices(tmp_path)
    assert len(rows) == 1
    assert rows[0]["valid_from"] == "2024-10-01"
