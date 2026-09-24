"""Tests for devices/common.py: date sanity, normalization, and cross-source merge."""

from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

from traning_cli.devices.common import (
    MIN_PLAUSIBLE_DATE,
    collapse_device_changes,
    merge_candidates,
    normalize_model,
    normalize_os_version,
    plausible_date,
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
    fit_rows = [_row(model="fr610", os_version="2.7")]
    tcx_rows = [_row(model="Garmin Forerunner 610", os_version="2.60")]

    merged = merge_candidates(fit_rows, tcx_rows)

    # Different literal model strings -> not deduped (exact-match dedup key).
    assert len(merged) == 2


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
