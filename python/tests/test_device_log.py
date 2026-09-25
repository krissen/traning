"""Tests for devices/log.py: read/write, validation, dedup."""

import pytest
from traning_cli.devices.log import (
    FIELDS,
    add_device,
    add_devices_bulk,
    collapse_same_day_rows,
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
    # Different valid_from dates: two rows on the SAME day now collapse
    # by design (collapse_same_day_rows(), the one-row-per-day
    # invariant) — see test_add_device_collapses_same_day_rows below.
    # This test is about the (model, os_version) dedup key itself.
    add_device(
        tmp_path, platform="garmin", model="fr945", os_version="13.0", valid_from="2025-01-01"
    )
    second = add_device(
        tmp_path, platform="garmin", model="fr945", os_version="14.0", valid_from="2025-06-01"
    )

    assert second is not None
    assert len(read_devices(tmp_path)) == 2


def test_add_device_collapses_same_day_rows(tmp_path):
    add_device(
        tmp_path, platform="garmin", model="fr945", os_version="13.0", valid_from="2025-01-01"
    )
    add_device(
        tmp_path, platform="garmin", model="fr945", os_version="13.1", valid_from="2025-01-01"
    )

    rows = read_devices(tmp_path)
    assert len(rows) == 1
    assert rows[0]["os_version"] == "13.1"
    assert "samma dag: 13.0" in rows[0]["note"]


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


def test_add_device_manual_earlier_candidate_takes_the_whole_row(tmp_path):
    """Nagelfar issue-005: a winning candidate replaces the row entirely,
    including certainty/origin/note, whatever its own certainty is — a
    label must always describe where the date it's attached to came
    from. A scan's exact/tcx row must not survive with a date that
    actually came from a manual guess."""
    add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2024-12-24",
        certainty="exact",
        origin="tcx",
        note="tcx-scan: 20241224-....tcx",
    )

    row = add_device(
        tmp_path,
        platform="garmin",
        model="Forerunner 945",
        os_version="13.7",
        valid_from="2024-12-01",
        certainty="known_since",
        origin="manual",
        note="jag minns att det var tidigare",
    )

    assert row is not None
    assert row == {
        "valid_from": "2024-12-01",
        "platform": "garmin",
        "model": "Forerunner 945",
        "os_version": "13.7",
        "certainty": "known_since",
        "origin": "manual",
        "note": "jag minns att det var tidigare",
    }
    rows = read_devices(tmp_path)
    assert len(rows) == 1
    assert rows[0] == row


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


# --- collapse_same_day_rows: one row per (platform, valid_from) ------------
#
# Nagelfar regression: two Apple Watch Ultra (gen 1) rows both dated
# 2022-10-06 (setup on 9.0.1, updated to 9.1 later the same day) — with
# no time component in the file, the naive "one row per transition"
# behaviour left these as two same-day rows in whatever order they were
# written, which get_resting_hr's device-change note then read as a
# fictitious downgrade to 9.0.1.


def test_collapse_same_day_rows_keeps_single_rows_untouched():
    rows = [_row(valid_from="2020-01-01"), _row(valid_from="2021-01-01", model="fr945")]
    assert collapse_same_day_rows(rows) == rows


def test_collapse_same_day_rows_exact_kailash_case():
    rows = [
        _row(
            platform="apple_watch",
            valid_from="2022-10-06",
            model="Apple Watch Ultra (gen 1)",
            os_version="9.0.1",
            origin="healthkit",
            note="healthkit-scan: export.xml",
        ),
        _row(
            platform="apple_watch",
            valid_from="2022-10-06",
            model="Apple Watch Ultra (gen 1)",
            os_version="9.1",
            origin="healthkit",
            note="healthkit-scan: export.xml",
        ),
        _row(
            platform="apple_watch",
            valid_from="2022-09-14",
            model="Apple Watch Series 4",
            os_version="9.1",
            origin="healthkit",
            note="healthkit-scan: export.xml",
        ),
    ]

    out = collapse_same_day_rows(rows)

    assert len(out) == 2
    ultra_row = next(r for r in out if r["valid_from"] == "2022-10-06")
    assert ultra_row["os_version"] == "9.1"
    assert ultra_row["model"] == "Apple Watch Ultra (gen 1)"
    assert "samma dag: 9.0.1" in ultra_row["note"]
    # certainty/origin follow the surviving (winning) row, unchanged here
    # since both same-day candidates shared the same values.
    assert ultra_row["certainty"] == "exact"
    assert ultra_row["origin"] == "healthkit"


def test_collapse_same_day_rows_is_order_independent():
    # The winner is decided by version magnitude, not input order — the
    # regression case must resolve the same way regardless of which
    # same-day candidate happened to be scanned/written first.
    a = _row(valid_from="2022-10-06", os_version="9.0.1")
    b = _row(valid_from="2022-10-06", os_version="9.1")
    assert collapse_same_day_rows([a, b])[0]["os_version"] == "9.1"
    assert collapse_same_day_rows([b, a])[0]["os_version"] == "9.1"


def test_collapse_same_day_rows_three_way_collision_names_both_losers():
    rows = [
        _row(valid_from="2022-10-06", os_version="9.0.1"),
        _row(valid_from="2022-10-06", os_version="9.0.2"),
        _row(valid_from="2022-10-06", os_version="9.1"),
    ]
    out = collapse_same_day_rows(rows)
    assert len(out) == 1
    assert out[0]["os_version"] == "9.1"
    assert "samma dag: 9.0.1" in out[0]["note"]
    assert "samma dag: 9.0.2" in out[0]["note"]


def test_collapse_same_day_rows_different_models_same_day_names_model_too():
    # Rare/degenerate (a device swap and a firmware bump landing on the
    # same calendar day), but must still resolve to one row without
    # losing which model the collapsed candidate was.
    rows = [
        _row(valid_from="2022-10-06", model="Series 4", os_version="9.0"),
        _row(valid_from="2022-10-06", model="Ultra (gen 1)", os_version="9.1"),
    ]
    out = collapse_same_day_rows(rows)
    assert len(out) == 1
    assert out[0]["model"] == "Ultra (gen 1)"  # higher parsed version wins regardless of model
    assert "samma dag: Series 4 9.0" in out[0]["note"]


def test_collapse_same_day_rows_handles_three_part_versions_correctly():
    # 9.1 must outrank 9.0.1 — plain string/float comparison can't do
    # this ("9.0.1" isn't a float at all; "9.1" > "9.0.1" as strings only
    # by accident of character-by-character comparison, not by version
    # magnitude, and breaks for e.g. "9.10" vs "9.9").
    rows = [
        _row(valid_from="2022-10-06", os_version="9.10"),
        _row(valid_from="2022-10-06", os_version="9.9"),
    ]
    assert collapse_same_day_rows(rows)[0]["os_version"] == "9.10"


def test_collapse_same_day_rows_preserves_platform_isolation():
    # Same day, different platforms: each keeps its own row.
    rows = [
        _row(valid_from="2022-10-06", platform="apple_watch"),
        _row(valid_from="2022-10-06", platform="garmin"),
    ]
    out = collapse_same_day_rows(rows)
    assert len(out) == 2
    assert {r["platform"] for r in out} == {"apple_watch", "garmin"}


def test_collapse_same_day_rows_is_idempotent():
    rows = [
        _row(valid_from="2022-10-06", os_version="9.0.1"),
        _row(valid_from="2022-10-06", os_version="9.1"),
        _row(valid_from="2020-01-01"),
    ]
    once = collapse_same_day_rows(rows)
    twice = collapse_same_day_rows(once)
    assert once == twice


def test_write_devices_collapses_existing_file_duplicates(tmp_path):
    # Simulates a devices.csv left dirty by a version of this code that
    # predates the invariant: write_devices() must clean it up on the
    # very next write, not just avoid adding to the problem.
    dirty_rows = [
        _row(valid_from="2022-10-06", os_version="9.0.1", note="pre-existing"),
        _row(valid_from="2022-10-06", os_version="9.1", note="pre-existing"),
    ]
    write_devices(tmp_path, dirty_rows)
    rows = read_devices(tmp_path)
    assert len(rows) == 1
    assert rows[0]["os_version"] == "9.1"
    assert "samma dag: 9.0.1" in rows[0]["note"]
