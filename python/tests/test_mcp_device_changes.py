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
