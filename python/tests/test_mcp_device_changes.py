"""Tests for the Python-side device-change note (r_bridge.r_report()).

R attaches `device_changes` to the envelope only for functions
registered in inst/mcp_bridge_shared.R's .DEVICE_CHANGE_FUNCS
(report_readiness, report_ef, report_decoupling — see
tests/testthat/test-mcp-device-changes.R for the R-side coverage).
These tests mock `_run_r` to isolate the Python formatting/wiring
logic from the R subprocess.
"""

from traning_cli.mcp import r_bridge


def _raw(rows=None, device_changes=None):
    envelope = {"type": "data", "rows": len(rows or []), "data": rows or []}
    if device_changes is not None:
        envelope["device_changes"] = device_changes
    return envelope


# --- _format_device_changes_note -------------------------------------------


def test_format_note_single_change_with_model_and_os():
    note = r_bridge._format_device_changes_note(
        [
            {
                "platform": "apple_watch",
                "model": "Ultra 2",
                "os_version": "watchOS 26.6",
                "note": "",
                "valid_from": "2026-06-01",
            }
        ]
    )
    assert note.startswith("Obs: klockbyte till Ultra 2 watchOS 26.6 den 2026-06-01")
    assert "mätteknik" in note


def test_format_note_garmin_uses_firmwarebyte_label():
    note = r_bridge._format_device_changes_note(
        [
            {
                "platform": "garmin",
                "model": "Forerunner 965",
                "os_version": "20.34",
                "note": "",
                "valid_from": "2024-03-10",
            }
        ]
    )
    assert "firmwarebyte till Forerunner 965 20.34 den 2024-03-10" in note


def test_format_note_falls_back_to_note_field_when_no_model_or_os():
    note = r_bridge._format_device_changes_note(
        [
            {
                "platform": "garmin",
                "model": "",
                "os_version": "",
                "note": "Firmware",
                "valid_from": "2024-03-10",
            }
        ]
    )
    assert "firmwarebyte (Firmware) den 2024-03-10" in note


def test_format_note_multiple_changes_joined():
    note = r_bridge._format_device_changes_note(
        [
            {
                "platform": "apple_watch",
                "model": "Ultra 2",
                "os_version": "watchOS 26.6",
                "note": "",
                "valid_from": "2026-06-01",
            },
            {
                "platform": "garmin",
                "model": "Forerunner 965",
                "os_version": "20.34",
                "note": "",
                "valid_from": "2024-03-10",
            },
        ]
    )
    assert note.count("Obs:") == 1
    assert "klockbyte" in note and "firmwarebyte" in note


def _aw_change(valid_from, model, os_version="watchOS 1.0"):
    return {
        "platform": "apple_watch",
        "model": model,
        "os_version": os_version,
        "note": "",
        "valid_from": valid_from,
    }


def test_format_note_at_threshold_still_uses_per_row_clauses():
    changes = [_aw_change(f"2026-0{i}-01", "Ultra 2") for i in range(1, 4)]  # 3 rows
    note = r_bridge._format_device_changes_note(changes)
    # 3 clauses joined by "; " (2 separators) + the fixed "inom perioden;" suffix
    assert note.count(";") == 3
    assert "enhetsbyte" not in note


def test_format_note_above_threshold_summarizes_firmware_bumps():
    # 1 device (Ultra) with 9 same-device watchOS bumps, newest first —
    # matches R's device_changes() sort order. The oldest row is still a
    # "swap" (no older neighbour in view), so exactly 1 device is named.
    changes = [_aw_change(f"2024-{i:02d}-01", "Ultra") for i in range(9, 1, -1)]
    changes.append(_aw_change("2022-09-23", "Ultra"))
    note = r_bridge._format_device_changes_note(changes)
    assert note.count("Obs:") == 1
    assert "1 enhetsbyte " in note
    assert "watchOS-uppdatering" in note
    # summarized form has no per-row "; " joins — just the fixed suffix
    assert note.count(";") == 1


def test_format_note_above_threshold_names_multiple_device_swaps():
    changes = (
        [_aw_change("2026-01-01", "Ultra 2")]
        + [_aw_change(f"2024-{i:02d}-01", "Ultra") for i in range(9, 1, -1)]
        + [_aw_change("2018-09-21", "Series 4")]
    )
    note = r_bridge._format_device_changes_note(changes)
    # 3 named devices: Ultra 2 (newest), the oldest Ultra row (the
    # transition boundary against Series 4), and Series 4 (oldest overall).
    assert "3 enhetsbyten" in note
    assert "Ultra 2" in note and "Series 4" in note
    assert "watchOS-uppdateringar" in note  # plural: remaining same-device bumps


def test_format_note_above_threshold_garmin_uses_firmware_label():
    changes = [
        {
            "platform": "garmin",
            "model": "Forerunner 965",
            "os_version": f"20.{i}",
            "note": "",
            "valid_from": f"2022-{i:02d}-01",
        }
        for i in range(9, 1, -1)
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert "firmwareuppdatering" in note
    assert "watchOS" not in note


def test_is_device_model_change_matches_r_semantics():
    # newest-first. A row is a swap when its model differs from the
    # NEXT OLDER row's — so the newest of two consecutive same-model
    # rows is never flagged; the transition is pinned to the older
    # (boundary) row instead. Cross-checked against R's
    # .is_device_model_change() for this exact fixture (see
    # tests/testthat/test-devices.R).
    changes = [
        _aw_change("2026-01-01", "Ultra 2"),
        _aw_change("2025-06-01", "Ultra 2"),
        _aw_change("2020-01-01", "Ultra"),
    ]
    assert r_bridge._is_device_model_change(changes) == [False, True, True]


# --- r_report wiring --------------------------------------------------------


def test_r_report_omits_device_changes_note_when_absent(monkeypatch):
    monkeypatch.setattr(r_bridge, "_run_r", lambda *a, **k: _raw(rows=[{"x": 1}]))
    out = r_bridge.r_report("report_monthtop")
    assert "device_changes_note" not in out


def test_r_report_omits_device_changes_note_when_empty_list(monkeypatch):
    monkeypatch.setattr(
        r_bridge, "_run_r", lambda *a, **k: _raw(rows=[{"x": 1}], device_changes=[])
    )
    out = r_bridge.r_report("report_readiness")
    assert "device_changes_note" not in out


def test_r_report_includes_device_changes_note_when_present(monkeypatch):
    changes = [
        {
            "platform": "apple_watch",
            "model": "Ultra 2",
            "os_version": "watchOS 26.6",
            "note": "",
            "valid_from": "2026-06-01",
        }
    ]
    monkeypatch.setattr(
        r_bridge, "_run_r", lambda *a, **k: _raw(rows=[{"x": 1}], device_changes=changes)
    )
    out = r_bridge.r_report("report_readiness")
    assert "device_changes_note" in out
    assert "klockbyte" in out["device_changes_note"]


def test_r_report_error_response_never_carries_a_note(monkeypatch):
    monkeypatch.setattr(r_bridge, "_run_r", lambda *a, **k: {"type": "error", "message": "boom"})
    out = r_bridge.r_report("report_readiness")
    assert out["summary"]["status"] == "error"
    assert "device_changes_note" not in out
