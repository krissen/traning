"""Tests for devices/log.py: read/write, validation, dedup."""

import pytest
from traning_cli.devices.log import (
    FIELDS,
    add_device,
    add_devices_bulk,
    collapse_same_day_rows,
    devices_csv_path,
    read_devices,
    tidy_devices_log,
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

    added, updated, _tidied = add_devices_bulk(tmp_path, candidates)

    assert len(added) == 1
    assert added[0]["os_version"] == "3.3"
    assert updated == []
    assert len(read_devices(tmp_path)) == 2


def test_add_devices_bulk_no_candidates_is_noop(tmp_path):
    added, updated, tidied = add_devices_bulk(tmp_path, [])
    assert added == []
    assert updated == []
    assert tidied == 0
    assert read_devices(tmp_path) == []


def _write_raw_devices_csv(data_dir, rows):
    """Write rows verbatim, without collapsing — a pre-invariant file with duplicates."""
    import csv

    path = devices_csv_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def _pre_invariant_file(tmp_path):
    """Two garmin rows for 2022-10-06 (from before the one-row-per-day
    invariant) plus one older row."""
    _write_raw_devices_csv(
        tmp_path,
        [
            _row(valid_from="2022-10-06", model="Forerunner 945", os_version="13"),
            _row(valid_from="2022-10-06", model="Forerunner 945", os_version="14"),
            _row(valid_from="2022-09-01", model="Forerunner 945", os_version="12"),
        ],
    )


def test_add_devices_bulk_rewrites_non_canonical_file_without_new_candidates(tmp_path):
    """No candidate is new, but the file predates the invariant: it is
    rewritten to canonical form and the outcome reports the cleanup."""
    _pre_invariant_file(tmp_path)

    added, updated, tidied = add_devices_bulk(tmp_path, [])

    assert added == []
    assert updated == []
    assert tidied == 1
    rows = read_devices(tmp_path)
    assert len(rows) == 2
    winner = next(r for r in rows if r["valid_from"] == "2022-10-06")
    assert winner["os_version"] == "14"
    assert "samma dag: 13" in winner["note"]


def test_add_devices_bulk_leaves_canonical_file_untouched(tmp_path):
    """An already-canonical file is not rewritten (mtime unchanged) and
    the outcome is exactly what it was before: nothing added, nothing
    updated, nothing tidied."""
    write_devices(
        tmp_path,
        [
            _row(valid_from="2022-10-06", model="Forerunner 945", os_version="14"),
            _row(valid_from="2022-09-01", model="Forerunner 945", os_version="12"),
        ],
    )
    before_stat = devices_csv_path(tmp_path).stat()
    before_rows = read_devices(tmp_path)

    added, updated, tidied = add_devices_bulk(tmp_path, [])

    assert added == []
    assert updated == []
    assert tidied == 0
    assert read_devices(tmp_path) == before_rows
    assert devices_csv_path(tmp_path).stat().st_mtime_ns == before_stat.st_mtime_ns


def test_tidy_devices_log_rewrites_and_reports(tmp_path):
    _pre_invariant_file(tmp_path)

    assert tidy_devices_log(tmp_path) == 1
    assert len(read_devices(tmp_path)) == 2


def test_tidy_devices_log_canonical_file_is_noop(tmp_path):
    write_devices(tmp_path, [_row(valid_from="2022-10-06")])
    before_stat = devices_csv_path(tmp_path).stat()

    assert tidy_devices_log(tmp_path) == 0
    assert devices_csv_path(tmp_path).stat().st_mtime_ns == before_stat.st_mtime_ns


def test_tidy_devices_log_missing_file_is_noop(tmp_path):
    assert tidy_devices_log(tmp_path) == 0
    assert not devices_csv_path(tmp_path).exists()


# --- absorbed same-day candidates report "already logged", not "added"
# (Nagelfar issue-001) ------------------------------------------------------
#
# Once write_devices() has collapsed a day, the losing candidate's
# (platform, model, os_version) key no longer exists as its own row.
# _merge_into()'s exact-key match can't see that the key is already
# represented — reapplying that candidate used to look like a brand new
# row every time, and each reapplication appended one more (undeduplicated)
# "samma dag: X" to the winner's note.


def _absorbed_fixture(tmp_path):
    """A collapsed day (Ultra 9.0/9.0.1/9.1 on 2022-10-06) plus an earlier
    Series 4 row — the exact fixture from the nagelfar issue-001 report."""
    add_devices_bulk(
        tmp_path,
        [
            _row(
                platform="apple_watch",
                valid_from="2022-09-14",
                model="Series 4",
                os_version="9.1",
                origin="healthkit",
                note="healthkit-scan: e.xml",
            ),
            _row(
                platform="apple_watch",
                valid_from="2022-10-06",
                model="Ultra",
                os_version="9.0",
                origin="healthkit",
                note="healthkit-scan: e.xml",
            ),
            _row(
                platform="apple_watch",
                valid_from="2022-10-06",
                model="Ultra",
                os_version="9.0.1",
                origin="healthkit",
                note="healthkit-scan: e.xml",
            ),
            _row(
                platform="apple_watch",
                valid_from="2022-10-06",
                model="Ultra",
                os_version="9.1",
                origin="healthkit",
                note="healthkit-scan: e.xml",
            ),
        ],
    )


def test_add_devices_bulk_repeated_absorbed_candidate_is_stable(tmp_path):
    _absorbed_fixture(tmp_path)
    after_setup = read_devices(tmp_path)

    loser_again = [
        _row(
            platform="apple_watch",
            valid_from="2022-10-06",
            model="Ultra",
            os_version="9.0.1",
            origin="healthkit",
            note="healthkit-scan: e.xml",
        )
    ]

    for _ in range(3):
        added, updated, _tidied = add_devices_bulk(tmp_path, loser_again)
        assert added == []
        assert updated == []
        assert read_devices(tmp_path) == after_setup  # byte-for-byte stable


def test_add_device_reapply_of_an_absorbed_version_reports_already_logged(tmp_path):
    _absorbed_fixture(tmp_path)
    after_setup = read_devices(tmp_path)

    row = add_device(
        tmp_path,
        platform="apple_watch",
        model="Ultra",
        os_version="9.0.1",
        valid_from="2022-10-06",
        certainty="exact",
        origin="healthkit",  # non-manual: nothing new to preserve verbatim
        note="healthkit-scan: e.xml",  # identical to what's already absorbed
    )

    assert row is None
    assert read_devices(tmp_path) == after_setup


def test_add_device_repeated_manual_add_of_an_absorbed_version_is_stable(tmp_path):
    # A manual candidate's own note IS preserved (see the test below), so
    # the first application legitimately changes the file — but applying
    # the exact same candidate again must not grow the note further.
    _absorbed_fixture(tmp_path)

    def apply_once():
        return add_device(
            tmp_path,
            platform="apple_watch",
            model="Ultra",
            os_version="9.0.1",
            valid_from="2022-10-06",
            certainty="exact",
            origin="manual",
            note="jag minns att uppdateringen kom på förmiddagen",
        )

    first = apply_once()
    assert first is not None
    after_first = read_devices(tmp_path)

    for _ in range(2):
        again = apply_once()
        assert again is None
        assert read_devices(tmp_path) == after_first


def test_add_device_manual_note_on_an_absorbed_version_is_preserved(tmp_path):
    # The other half of the fix: a genuinely NEW manual note for an
    # already-absorbed key must not be silently lost — even though the
    # (platform, model, os_version) key itself doesn't get its own row.
    _absorbed_fixture(tmp_path)

    row = add_device(
        tmp_path,
        platform="apple_watch",
        model="Ultra",
        os_version="9.0.1",
        valid_from="2022-10-06",
        certainty="exact",
        origin="manual",
        note="viktig anteckning",
    )

    assert row is not None
    assert "viktig anteckning" in row["note"]
    rows = read_devices(tmp_path)
    assert len(rows) == 2  # still collapsed — no new row for the absorbed key
    winner = next(r for r in rows if r["valid_from"] == "2022-10-06")
    assert "viktig anteckning" in winner["note"]
    assert winner["os_version"] == "9.1"  # the winner itself is unchanged


def test_add_devices_bulk_separate_source_scans_do_not_re_add_the_loser(tmp_path):
    # (fit/tcx scanned separately after an --source all run that already
    # absorbed a same-day duplicate) reproduces the same key-miss shape
    # as a manual re-add: each separate --source invocation only ever
    # sees its own candidate list, never the full collapsed file's notes.
    _absorbed_fixture(tmp_path)
    after_setup = read_devices(tmp_path)

    fit_only = [
        _row(
            platform="apple_watch",
            valid_from="2022-10-06",
            model="Ultra",
            os_version="9.0",
            origin="healthkit",
            note="healthkit-scan: e.xml",
        )
    ]
    tcx_only = [
        _row(
            platform="apple_watch",
            valid_from="2022-10-06",
            model="Ultra",
            os_version="9.0.1",
            origin="healthkit",
            note="healthkit-scan: e.xml",
        )
    ]

    added1, updated1, _tidied1 = add_devices_bulk(tmp_path, fit_only)
    assert added1 == []
    assert updated1 == []
    added2, updated2, _tidied2 = add_devices_bulk(tmp_path, tcx_only)
    assert added2 == []
    assert updated2 == []
    assert read_devices(tmp_path) == after_setup


# --- Nagelfar issue-001, round 2: canonical note rebuild --------------------
#
# Round 1's fix deduplicated by exact phrase text, which still grew
# without bound whenever a loser's own note contained "; " — splitting
# a phrase like "samma dag: 9.0.1 (healthkit-scan: export.xml; samma
# dag: 9.1)" on "; " never matches itself again verbatim. The note is
# now always rebuilt from scratch on every merge (see
# _merge_day_group()), which has no such failure mode: there's nothing
# to accumulate.


@pytest.mark.parametrize(
    "loser_note",
    [
        "",
        "healthkit-scan: export.xml",
        "healthkit-scan: export.xml; samma dag: 9.0",
        "jag minns; det var på förmiddagen",
        "jag minns; samma dag: 9.0",
    ],
    ids=[
        "empty",
        "provenance",
        "provenance_plus_samma_dag",
        "manual_semicolon",
        "manual_plus_samma_dag",
    ],
)
@pytest.mark.parametrize("loser_origin", ["manual", "healthkit"])
def test_repeated_absorption_matrix_is_stable_from_round_2(tmp_path, loser_note, loser_origin):
    _absorbed_fixture(tmp_path)

    candidate = _row(
        platform="apple_watch",
        valid_from="2022-10-06",
        model="Ultra",
        os_version="9.0.1",
        origin=loser_origin,
        note=loser_note,
    )

    outcomes = []
    for _ in range(3):
        added, updated, _tidied = add_devices_bulk(tmp_path, [dict(candidate)])
        outcomes.append((len(added), len(updated), read_devices(tmp_path)))

    # Round 1 may legitimately change the file (a manual note being
    # preserved for the first time, say) — rounds 2 and 3 must both
    # report "already logged" and leave the file exactly as round 1 did.
    assert outcomes[1][:2] == (0, 0)
    assert outcomes[2][:2] == (0, 0)
    assert outcomes[1][2] == outcomes[0][2]
    assert outcomes[2][2] == outcomes[0][2]


def test_real_devices_csv_2022_10_06_collapses_exactly(tmp_path):
    # The actual production row shape (both candidates share the
    # scanner's own provenance note): must collapse to exactly
    # "healthkit-scan: export.xml; samma dag: 9.0.1" — no provenance
    # text duplicated in parens (it's from a healthkit-origin loser,
    # never preserved verbatim).
    write_devices(
        tmp_path,
        [
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
        ],
    )
    row = next(r for r in read_devices(tmp_path) if r["valid_from"] == "2022-10-06")
    assert row["note"] == "healthkit-scan: export.xml; samma dag: 9.0.1"


def test_merge_day_group_leaves_winners_own_version_out(tmp_path):
    """A loser's note already lists the winner's version (leftover from
    an earlier collapse where today's winner itself lost): the
    canonical list must not repeat the row's own version."""
    write_devices(
        tmp_path,
        [
            _row(
                platform="apple_watch",
                valid_from="2022-10-06",
                model="Ultra",
                os_version="9.1",
                origin="healthkit",
                note="healthkit-scan: export.xml; samma dag: 9.0, 9.0.1, 9.1",
            ),
            _row(
                platform="apple_watch",
                valid_from="2022-10-06",
                model="Ultra",
                os_version="9.0",
                origin="healthkit",
                note="healthkit-scan: export.xml",
            ),
        ],
    )
    row = next(r for r in read_devices(tmp_path) if r["valid_from"] == "2022-10-06")
    assert row["os_version"] == "9.1"
    assert row["note"] == "healthkit-scan: export.xml; samma dag: 9.0, 9.0.1"


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

    added, updated, _tidied = add_devices_bulk(tmp_path, candidates)

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
    # Canonical form: one combined, sorted "samma dag: ..." list, not one
    # phrase per loser.
    assert out[0]["note"] == "samma dag: 9.0.1, 9.0.2"


def test_collapse_same_day_rows_different_models_same_day_falls_back_to_version():
    # No previous day on record for this platform at all -> rule 2 (swap
    # detection) has nothing to compare against, falls through to rule 3
    # (highest version) — must still resolve to one row without losing
    # which model the collapsed candidate was.
    rows = [
        _row(valid_from="2022-10-06", model="Series 4", os_version="9.0"),
        _row(valid_from="2022-10-06", model="Ultra (gen 1)", os_version="9.1"),
    ]
    out = collapse_same_day_rows(rows)
    assert len(out) == 1
    assert out[0]["model"] == "Ultra (gen 1)"  # higher parsed version wins regardless of model
    assert "samma dag: Series 4 9.0" in out[0]["note"]


# --- Nagelfar rond 2: device swap must beat version, not the other way
# round, once a previous day establishes which model was already current.


def test_collapse_same_day_rows_device_swap_beats_higher_version_on_old_model():
    # (a) The exact regression: Series 4 (9.1) was already current as of
    # the previous day; an Ultra (gen 1) arrives on a LOWER os_version
    # (9.0.1) the same day Series 4 also logs a bump to 9.1 again. The
    # swap into the new device is the day's real change, even though its
    # version number is lower — must NOT resolve to "highest version" here.
    rows = [
        _row(valid_from="2022-09-14", model="Series 4", os_version="9.1"),
        _row(valid_from="2022-10-06", model="Series 4", os_version="9.1"),
        _row(valid_from="2022-10-06", model="Ultra", os_version="9.0.1"),
    ]
    out = collapse_same_day_rows(rows)
    assert len(out) == 2
    same_day = next(r for r in out if r["valid_from"] == "2022-10-06")
    assert same_day["model"] == "Ultra"
    assert same_day["os_version"] == "9.0.1"
    assert "samma dag: Series 4 9.1" in same_day["note"]


def test_collapse_same_day_rows_device_swap_without_time_on_file():
    # (b) Same case, phrased as "already on file, no time info" rather
    # than freshly scanned — collapse_same_day_rows() never has time
    # info regardless of where the rows came from, so this is really
    # the same code path as (a); kept as its own test since it's the
    # literal regression report's framing ("rader på fil utan tid").
    rows = [
        _row(valid_from="2022-09-14", model="Series 4", os_version="9.1", origin="manual"),
        _row(valid_from="2022-10-06", model="Series 4", os_version="9.1", origin="manual"),
        _row(valid_from="2022-10-06", model="Ultra", os_version="9.0.1", origin="manual"),
    ]
    out = collapse_same_day_rows(rows)
    same_day = next(r for r in out if r["valid_from"] == "2022-10-06")
    assert same_day["model"] == "Ultra"
    assert same_day["os_version"] == "9.0.1"


def test_collapse_same_day_rows_unchanged_case_c_single_model_still_uses_version():
    # (c) The pre-nagelfar-rond-2 case must resolve exactly as before:
    # a single model with two same-day os_version candidates still picks
    # the higher version (there's no swap to detect — rule 1/2 don't
    # apply when the whole group shares one model).
    rows = [
        _row(valid_from="2022-10-06", model="Ultra", os_version="9.0.1"),
        _row(valid_from="2022-10-06", model="Ultra", os_version="9.1"),
    ]
    out = collapse_same_day_rows(rows)
    assert len(out) == 1
    assert out[0]["os_version"] == "9.1"
    assert "samma dag: 9.0.1" in out[0]["note"]


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


def test_collapse_same_day_rows_does_not_duplicate_an_already_absorbed_note():
    # Simulates write_devices() re-collapsing a row set where the winner
    # already carries "samma dag: 9.0.1" from an earlier write, and the
    # same loser has been (incorrectly, pre-fix) re-added as its own raw
    # row — the note must not gain a second copy of the same phrase.
    winner = _row(valid_from="2022-10-06", model="Ultra", os_version="9.1", note="samma dag: 9.0.1")
    reappeared_loser = _row(valid_from="2022-10-06", model="Ultra", os_version="9.0.1")
    out = collapse_same_day_rows([winner, reappeared_loser])
    assert len(out) == 1
    assert out[0]["note"].count("samma dag: 9.0.1") == 1


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
