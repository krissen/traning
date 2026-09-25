"""Tests for devices/common.py: date sanity, normalization, and cross-source merge."""

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from traning_cli.devices.common import (
    MIN_PLAUSIBLE_DATE,
    collapse_device_changes,
    garmin_activity_local_date,
    is_generic_device,
    merge_candidates,
    normalize_model,
    normalize_os_version,
    parse_garmin_start_time_local,
    plausible_date,
    utc_to_stockholm_date,
)


def test_plausible_date_accepts_min_boundary():
    assert plausible_date(MIN_PLAUSIBLE_DATE) is True


def test_plausible_date_accepts_today():
    assert plausible_date(date.today()) is True


def test_plausible_date_rejects_before_2000():
    assert plausible_date(date(1999, 12, 31)) is False


def test_plausible_date_rejects_future():
    assert plausible_date(date.today() + timedelta(days=1)) is False


def test_plausible_date_rejects_far_future_typo():
    assert plausible_date(date(2061, 3, 3)) is False


# --- collapse_device_changes ------------------------------------------------


@dataclass
class _Rec:
    path: Path
    activity_date: date
    model: str
    os_version: str


def test_collapse_device_changes_uses_platform_origin_note_prefix():
    records = [_Rec(Path("a.tcx"), date(2020, 1, 1), "fr945", "13.0")]

    rows = collapse_device_changes(records, platform="garmin", origin="tcx", note_prefix="tcx-scan")

    assert rows == [
        {
            "valid_from": "2020-01-01",
            "platform": "garmin",
            "model": "fr945",
            "os_version": "13.0",
            "certainty": "exact",
            "origin": "tcx",
            "note": "tcx-scan: a.tcx",
        }
    ]


# --- merge_candidates --------------------------------------------------------


def _row(**overrides):
    row = {
        "valid_from": "2020-01-01",
        "platform": "garmin",
        "model": "fr945",
        "os_version": "13.0",
        "certainty": "exact",
        "origin": "fit",
        "note": "",
    }
    row.update(overrides)
    return row


def test_merge_candidates_keeps_earliest_valid_from_across_sources():
    fit_rows = [_row(valid_from="2015-08-15", model="fr620", os_version="3.3", origin="fit")]
    tcx_rows = [_row(valid_from="2020-02-02", model="fr620", os_version="3.3", origin="tcx")]

    merged = merge_candidates(fit_rows, tcx_rows)

    assert len(merged) == 1
    assert merged[0]["valid_from"] == "2015-08-15"
    assert merged[0]["origin"] == "fit"


def test_merge_candidates_keeps_distinct_models_separate():
    # Different valid_from dates: two rows on the SAME day now collapse
    # by design (collapse_same_day_rows(), the one-row-per-day
    # invariant) regardless of model — that's covered separately in
    # test_merge_candidates_collapses_same_day_across_sources below.
    # This test is about the (model, os_version) dedup key itself.
    fit_rows = [_row(valid_from="2020-01-01", model="fr610", os_version="2.7")]
    tcx_rows = [_row(valid_from="2021-01-01", model="Garmin Forerunner 610", os_version="2.60")]

    merged = merge_candidates(fit_rows, tcx_rows)

    # Different literal model strings -> not deduped (exact-match dedup key).
    assert len(merged) == 2


def test_merge_candidates_collapses_same_day_across_sources():
    # Two sources independently derive a change dated the same day, for
    # different (model, os_version) keys -- merge_candidates()'s own
    # dedup (keyed on platform/model/os_version) wouldn't catch this;
    # the final collapse_same_day_rows() pass must.
    fit_rows = [_row(valid_from="2022-10-06", model="fr945", os_version="9.0.1")]
    tcx_rows = [_row(valid_from="2022-10-06", model="fr945", os_version="9.1")]

    merged = merge_candidates(fit_rows, tcx_rows)

    assert len(merged) == 1
    assert merged[0]["os_version"] == "9.1"
    assert "samma dag: 9.0.1" in merged[0]["note"]


def test_merge_candidates_empty_lists():
    assert merge_candidates([], []) == []


def test_merge_candidates_single_list_passthrough():
    rows = [_row(valid_from="2020-01-01"), _row(valid_from="2021-01-01", model="fr945x")]
    assert len(merge_candidates(rows)) == 2


# --- normalize_model ---------------------------------------------------------


def test_normalize_model_fit_code_table_lookup():
    assert normalize_model("fr610") == "Forerunner 610"
    assert normalize_model("fr620") == "Forerunner 620"
    assert normalize_model("fr945") == "Forerunner 945"


def test_normalize_model_tcx_garmin_prefix_stripped():
    assert normalize_model("Garmin Forerunner 610") == "Forerunner 610"
    assert normalize_model("Garmin Forerunner 620") == "Forerunner 620"


def test_normalize_model_tcx_missing_space_inserted():
    assert normalize_model("Forerunner305") == "Forerunner 305"


def test_normalize_model_already_canonical_unchanged():
    assert normalize_model("Forerunner 945") == "Forerunner 945"


def test_normalize_model_unknown_left_untouched():
    assert normalize_model("Allmän ANT-enhet") == "Allmän ANT-enhet"
    assert normalize_model("Garmin Fitness Device") == "Garmin Fitness Device"
    assert normalize_model("connect") == "connect"


def test_normalize_model_empty_string():
    assert normalize_model("") == ""


def test_normalize_model_fit_and_tcx_forms_converge():
    """The point of normalization: FIT's code and TCX's name for the same
    physical device end up as the identical string."""
    assert normalize_model("fr610") == normalize_model("Garmin Forerunner 610")


# --- normalize_os_version ----------------------------------------------------


def test_normalize_os_version_drops_trailing_zero_decimal():
    assert normalize_os_version("2.70") == "2.7"


def test_normalize_os_version_whole_number_loses_decimal_point():
    assert normalize_os_version("13.0") == "13"
    assert normalize_os_version("0.0") == "0"


def test_normalize_os_version_already_minimal_unchanged():
    assert normalize_os_version("3.3") == "3.3"


def test_normalize_os_version_empty_string():
    assert normalize_os_version("") == ""


def test_normalize_os_version_non_numeric_passthrough():
    assert normalize_os_version("n/a") == "n/a"


def test_normalize_os_version_tcx_and_fit_forms_converge():
    """ "2.70" (TCX's major.minor join) and "2.7" (FIT's float repr, or a
    hand-typed --os-version) must compare equal after normalization."""
    assert normalize_os_version("2.70") == normalize_os_version("2.7")


# --- is_generic_device --------------------------------------------------


def test_is_generic_device_known_names():
    assert is_generic_device("Garmin Fitness Device") is True
    assert is_generic_device("Allmän ANT-enhet") is True


def test_is_generic_device_real_device_name():
    assert is_generic_device("Forerunner 945") is False
    assert is_generic_device("Garmin Forerunner 610") is False


def test_is_generic_device_empty_string():
    assert is_generic_device("") is False


def test_is_generic_device_not_fooled_by_shared_product_id():
    """ProductID 1345 is both "Allmän ANT-enhet" (generic) and, in most
    files, the real "Garmin Forerunner 610" — the filter must key on the
    name, so a ProductID alone can't be used to infer genericness."""
    assert is_generic_device("Garmin Forerunner 610") is False


def test_normalize_os_version_tcx_zero_padded_minor_matches_fit_float():
    """A TCX minor of "05" (already zero-padded by tcx_scan, Nagelfar
    issue-004) and FIT's equivalent software_version float must land on
    the same normalized string."""
    assert normalize_os_version("13.05") == normalize_os_version(str(13.05))


# --- garmin_activity_local_date -------------------------------------------
#
# The device log dates a change by the wall-clock day where the activity
# happened, not by UTC's day boundary.


def test_utc_late_evening_summer_resolves_to_next_day():
    """(a) 23:30 UTC in summer (CEST, +2) is already the next day locally."""
    assert garmin_activity_local_date(utc_moment=datetime(2023, 6, 15, 23, 30)) == date(2023, 6, 16)


def test_utc_winter_evening_resolves_to_next_day():
    """Same as above for winter (CET, +1): 23:30 UTC is past local midnight."""
    assert garmin_activity_local_date(utc_moment=datetime(2023, 1, 15, 23, 30)) == date(2023, 1, 16)


def test_utc_midday_stays_on_the_same_day():
    assert garmin_activity_local_date(utc_moment=datetime(2023, 1, 15, 12, 0)) == date(2023, 1, 15)


def test_aware_utc_moment_converts_the_same():
    assert garmin_activity_local_date(
        utc_moment=datetime(2023, 6, 15, 23, 30, tzinfo=UTC)
    ) == utc_to_stockholm_date(datetime(2023, 6, 15, 23, 30))


def test_start_time_local_wins_over_utc():
    """(b) A session in another timezone: UTC says the 30th (even in
    Stockholm), but startTimeLocal says the activity happened on the 29th."""
    assert garmin_activity_local_date(
        start_time_local="2023-12-29 20:00:00",
        utc_moment=datetime(2023, 12, 30, 1, 0),
    ) == date(2023, 12, 29)


def test_unparseable_start_time_local_falls_through_to_utc():
    assert garmin_activity_local_date(
        start_time_local="not-a-date",
        utc_moment=datetime(2023, 1, 15, 12, 0),
    ) == date(2023, 1, 15)


def test_fit_local_timestamp_wins_over_utc():
    """(c) FIT local_timestamp (wall-clock where the run happened) beats
    both the UTC calendar date and the Stockholm conversion."""
    assert garmin_activity_local_date(
        local_timestamp=datetime(2023, 12, 29, 19, 30),
        utc_moment=datetime(2023, 12, 30, 0, 30),
    ) == date(2023, 12, 29)


def test_start_time_local_wins_over_fit_local_timestamp():
    assert garmin_activity_local_date(
        start_time_local="2023-12-29 20:00:00",
        local_timestamp=datetime(2023, 12, 28, 19, 30),
        utc_moment=datetime(2023, 12, 30, 1, 0),
    ) == date(2023, 12, 29)


def test_no_source_returns_none():
    assert garmin_activity_local_date() is None


def test_parse_garmin_start_time_local_formats():
    assert parse_garmin_start_time_local("2023-12-29 06:48:33") == date(2023, 12, 29)
    assert parse_garmin_start_time_local("2023-12-29T06:48:33") == date(2023, 12, 29)
    assert parse_garmin_start_time_local(None) is None
    assert parse_garmin_start_time_local("") is None
    assert parse_garmin_start_time_local("not-a-date") is None
