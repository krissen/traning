"""Tests for the Python-side device-change note (r_bridge.r_report()).

R attaches `device_changes` to the envelope only for functions
registered in inst/mcp_bridge_shared.R's .DEVICE_CHANGE_FUNCS
(report_readiness, report_ef, report_decoupling — see
tests/testthat/test-mcp-device-changes.R for the R-side coverage).
These tests mock `_run_r` to isolate the Python formatting/wiring
logic from the R subprocess.

Every fixture below includes `is_model_change`, matching what R's
device_changes() actually sends (R/devices.R): it classifies against
each platform's FULL recorded history before windowing, so it is the
authoritative source — Python's _is_device_model_change() only exists
as a defensive fallback for rows that (unusually) lack the field, and
is covered separately near the bottom of this file.
"""

from traning_cli.mcp import r_bridge


def _raw(rows=None, device_changes=None):
    envelope = {"type": "data", "rows": len(rows or []), "data": rows or []}
    if device_changes is not None:
        envelope["device_changes"] = device_changes
    return envelope


def _change(platform, valid_from, model, os_version, is_model_change, note=""):
    return {
        "platform": platform,
        "model": model,
        "os_version": os_version,
        "note": note,
        "valid_from": valid_from,
        "is_model_change": is_model_change,
    }


def _aw_swap(valid_from, model, os_version="1.0"):
    return _change("apple_watch", valid_from, model, os_version, True)


def _aw_bump(valid_from, model, os_version):
    return _change("apple_watch", valid_from, model, os_version, False)


def _garmin_swap(valid_from, model, os_version="1.0"):
    return _change("garmin", valid_from, model, os_version, True)


def _garmin_bump(valid_from, model, os_version):
    return _change("garmin", valid_from, model, os_version, False)


# --- _format_device_changes_note: short form (<= threshold) ----------------


def test_format_note_single_swap_reads_klockbyte():
    note = r_bridge._format_device_changes_note([_aw_swap("2026-06-01", "Ultra 2", "watchOS 26.6")])
    assert note == (
        "Obs, inom perioden: klockbyte till Ultra 2 den 2026-06-01; nivåskifte kan vara mätteknik."
    )


def test_format_note_short_form_only_firmware_bumps_never_says_klockbyte():
    # The exact shape from the kailash regression: get_resting_hr(after="-6m")
    # returned three watchOS updates on the SAME Ultra (gen 1) watch, worded
    # as three "klockbyte" — none of these is a device swap.
    changes = [
        _aw_bump("2026-07-29", "Apple Watch Ultra (gen 1)", "26.6"),
        _aw_bump("2026-05-17", "Apple Watch Ultra (gen 1)", "26.5"),
        _aw_bump("2026-03-30", "Apple Watch Ultra (gen 1)", "26.4"),
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert note == (
        "Obs, inom perioden: watchOS-uppdatering till 26.6 den 2026-07-29; "
        "watchOS-uppdatering till 26.5 den 2026-05-17; "
        "watchOS-uppdatering till 26.4 den 2026-03-30; "
        "nivåskifte kan vara mätteknik."
    )
    assert "klockbyte" not in note


def test_format_note_short_form_garmin_firmware_bump_uses_firmwareuppdatering():
    note = r_bridge._format_device_changes_note(
        [_garmin_bump("2024-03-10", "Forerunner 965", "20.34")]
    )
    assert "firmwareuppdatering till 20.34 den 2024-03-10" in note
    assert "klockbyte" not in note
    assert "firmwarebyte" not in note  # the old (removed) platform label


def test_format_note_short_form_mixed_swap_and_bump():
    changes = [
        _aw_bump("2026-07-29", "Ultra 2", "26.6"),
        _aw_swap("2026-01-01", "Ultra 2"),
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert "watchOS-uppdatering till 26.6 den 2026-07-29" in note
    assert "klockbyte till Ultra 2 den 2026-01-01" in note


def test_format_note_short_form_falls_back_to_note_when_desc_missing():
    swap = _change("garmin", "2024-03-10", "", "", True, note="Ny enhet")
    bump = _change("garmin", "2024-04-10", "", "", False, note="Firmware")
    note_swap = r_bridge._format_device_changes_note([swap])
    note_bump = r_bridge._format_device_changes_note([bump])
    assert "klockbyte till Ny enhet den 2024-03-10" in note_swap
    assert "firmwareuppdatering till Firmware den 2024-04-10" in note_bump


def test_format_note_short_form_grammar_scopes_whole_list():
    # "inom perioden" leads the sentence, not trailing the last clause —
    # must not read as if it only qualifies the final change.
    changes = [
        _aw_swap("2026-06-01", "Ultra 2", "watchOS 26.6"),
        _garmin_swap("2024-03-10", "Forerunner 965", "20.34"),
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert note.startswith("Obs, inom perioden:")
    assert note.count("Obs") == 1
    assert "inom perioden" not in note[len("Obs, inom perioden:") :]


# --- _format_device_changes_note: summary form (> threshold) ---------------


def test_format_note_above_threshold_summarizes_firmware_bumps():
    # 1 device (Ultra) with 9 same-device watchOS bumps, newest first.
    changes = [_aw_bump(f"2024-{i:02d}-01", "Ultra", f"{i}.0") for i in range(9, 1, -1)]
    changes.append(_aw_swap("2022-09-23", "Ultra"))
    note = r_bridge._format_device_changes_note(changes)
    assert note.startswith("Obs, inom perioden:")
    assert "1 enhetsbyte " in note
    assert "watchOS-uppdatering" in note
    # summarized form has no per-row "; " joins — just the fixed suffix
    assert note.count(";") == 1


def test_format_note_above_threshold_names_multiple_device_swaps():
    changes = (
        [_aw_swap("2026-01-01", "Ultra 2")]
        + [_aw_bump(f"2024-{i:02d}-01", "Ultra", f"{i}.0") for i in range(9, 2, -1)]
        + [_aw_swap("2024-02-01", "Ultra")]
        + [_aw_swap("2018-09-21", "Series 4")]
    )
    note = r_bridge._format_device_changes_note(changes)
    assert "3 enhetsbyten" in note
    assert "Ultra 2" in note and "Series 4" in note
    assert "watchOS-uppdateringar" in note  # plural: remaining same-device bumps


def test_format_note_above_threshold_garmin_uses_firmware_label():
    changes = [
        _garmin_bump(f"2022-{i:02d}-01", "Forerunner 965", f"20.{i}") for i in range(9, 1, -1)
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert "firmwareuppdatering" in note
    assert "watchOS" not in note


# --- R-shaped input: _format_device_changes_note() trusts the
# one-row-per-(platform, day) invariant rather than re-enforcing it
# (nagelfar issue-002) --------------------------------------------------
#
# devices.csv only carries a date, never a time. R's device_changes()
# (called on read_device_log()'s output, itself already collapsed) is
# the only real source of `changes` in production, and it always
# satisfies "at most one row per (platform, valid_from)" — a second
# collapse here used to exist as a defensive guard, but re-collapsing
# an already-windowed subset with no cross-day context is not a
# faithful backup of R's full-history decision; it could disagree with
# what R already decided. These tests feed exactly the shape R actually
# sends — a single, already-collapsed row per day, its note already
# carrying any same-day loser — to pin the wording contract. The
# collapse itself (including the exact kailash same-day regression and
# the device-swap-beats-version case) is tested where it happens:
# tests/testthat/test-devices.R.


def test_format_note_wording_for_an_already_collapsed_r_row():
    # What R actually sends for 2022-10-06 after collapsing Ultra
    # 9.0.1 + 9.1 to a single row (see test-devices.R's
    # "read_device_log collapses the exact kailash same-day case").
    changes = [
        _change(
            "apple_watch",
            "2022-10-06",
            "Apple Watch Ultra (gen 1)",
            "9.1",
            False,
            note="healthkit-scan: export.xml; samma dag: 9.0.1",
        ),
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert note.count("2022-10-06") == 1
    assert "9.0.1" not in note  # the note's own "samma dag" text isn't surfaced in the clause
    assert "watchOS-uppdatering till 9.1 den 2022-10-06" in note


def test_format_note_wording_for_r_resolved_device_swap():
    # What R actually sends for the device-swap-beats-version case (see
    # test-devices.R "(a) device swap beats a higher version on the old
    # model"): a single Ultra row for 2022-10-06, is_model_change=True,
    # note already carrying the absorbed Series 4 bump.
    changes = [
        _change(
            "apple_watch",
            "2022-10-06",
            "Ultra",
            "9.0.1",
            True,
            note="samma dag: Series 4 9.1",
        ),
        _change("apple_watch", "2022-09-14", "Series 4", "9.1", True),
    ]
    note = r_bridge._format_device_changes_note(changes)
    assert note.count("2022-10-06") == 1
    assert "klockbyte till Ultra den 2022-10-06" in note
    assert "klockbyte till Series 4 den 2022-09-14" in note
    assert "9.1 den 2022-10-06" not in note


# --- _resolve_swap_flags / _is_device_model_change fallback -----------------


def test_resolve_swap_flags_prefers_rs_field():
    # R's field says these are bumps; the naive windowed recomputation
    # (no older neighbour visible) would say the oldest is a swap. The
    # resolved flags must follow R, not the fallback.
    changes = [
        _aw_bump("2026-07-29", "Ultra (gen 1)", "26.6"),
        _aw_bump("2026-05-17", "Ultra (gen 1)", "26.5"),
        _aw_bump("2026-03-30", "Ultra (gen 1)", "26.4"),
    ]
    assert r_bridge._resolve_swap_flags(changes) == [False, False, False]


def test_resolve_swap_flags_falls_back_when_field_absent():
    # No is_model_change key at all: falls back to the window-limited
    # local computation — same semantics as before this fix, kept only
    # for handcrafted callers that don't go through R.
    changes = [
        {"platform": "apple_watch", "model": "Ultra 2", "valid_from": "2026-01-01"},
        {"platform": "apple_watch", "model": "Ultra 2", "valid_from": "2025-06-01"},
        {"platform": "apple_watch", "model": "Ultra", "valid_from": "2020-01-01"},
    ]
    assert r_bridge._resolve_swap_flags(changes) == [False, True, True]


def test_is_device_model_change_matches_r_semantics():
    # newest-first. A row is a swap when its model differs from the
    # NEXT OLDER row's — so the newest of two consecutive same-model
    # rows is never flagged; the transition is pinned to the older
    # (boundary) row instead. Cross-checked against R's
    # .is_device_model_change() for this exact fixture (see
    # tests/testthat/test-devices.R). This is the raw, window-limited
    # helper — _resolve_swap_flags() is what production code calls.
    changes = [
        {"platform": "apple_watch", "model": "Ultra 2", "valid_from": "2026-01-01"},
        {"platform": "apple_watch", "model": "Ultra 2", "valid_from": "2025-06-01"},
        {"platform": "apple_watch", "model": "Ultra", "valid_from": "2020-01-01"},
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
    changes = [_aw_swap("2026-06-01", "Ultra 2", "watchOS 26.6")]
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


# --- n-only call shape (nagelfar issue-001 regression) ----------------------
#
# tools.py's default calls (get_hrv(), get_resting_hr(), get_sleep(),
# get_vo2max() with no after/before; get_efficiency(metric="ef")/
# get_decoupling() likewise) send only {"n": ...} to R — no from/to keys
# at all (see _build_args(): it only sets "from"/"to" when after/before
# were explicitly given). The R-side fix (inst/mcp_bridge_shared.R:
# .effective_device_change_bounds()) now scopes device_changes to the
# actual result's date range on that path; these tests pin the Python
# side of that contract — an n-only call must reach R with no from/to,
# and a device_changes list that (as R now guarantees) only contains
# in-window rows must never surface an out-of-window change in the note.


def test_get_hrv_default_call_sends_only_n_no_from_or_to(monkeypatch):
    from traning_cli.mcp import tools

    recorded = {}

    def fake_r_report(func, args=None, **kwargs):
        recorded["func"] = func
        recorded["args"] = args
        return {"schema_version": "1.0", "summary": {"status": "ok"}, "details": []}

    monkeypatch.setattr(tools, "r_report", fake_r_report)
    tools.get_hrv()
    assert recorded["func"] == "report_readiness"
    assert "from" not in recorded["args"]
    assert "to" not in recorded["args"]
    assert recorded["args"]["n"] == 30


def test_n_only_response_never_mentions_a_change_outside_the_result_window(monkeypatch):
    # Simulates the FIXED R behaviour: an n-only call (device_changes
    # already scoped by R to the reported window) returns only the
    # in-window change — the long-ago Series 3 swap issue-001 flagged
    # as wrongly included is simply absent from what R sends back.
    in_window_change = [_aw_swap("2025-11-15", "Ultra 2", "watchOS 26.6")]
    monkeypatch.setattr(
        r_bridge,
        "_run_r",
        lambda *a, **k: _raw(rows=[{"Datum": "2025-11-15"}], device_changes=in_window_change),
    )
    out = r_bridge.r_report("report_readiness", {"n": 14})
    assert "device_changes_note" in out
    assert "2025-11-15" in out["device_changes_note"]
    assert "2020-01-01" not in out["device_changes_note"]  # the out-of-window change


def test_n_only_response_omits_note_when_r_sends_no_device_changes(monkeypatch):
    # The other half of the fix: when R finds nothing in the result's
    # own window (or has no date to derive a window from at all), it
    # omits `device_changes` entirely — r_report() must not fabricate
    # a note from an absent field.
    monkeypatch.setattr(r_bridge, "_run_r", lambda *a, **k: _raw(rows=[{"Datum": "2025-11-15"}]))
    out = r_bridge.r_report("report_readiness", {"n": 14})
    assert "device_changes_note" not in out


def test_n_only_response_correctly_words_a_boundary_firmware_bump(monkeypatch):
    # The full kailash-shaped regression through r_report(): an n-only
    # call, three in-window watchOS bumps on the same watch (R already
    # classified the window's oldest row using history before the
    # window — see tests/testthat/test-devices.R), must produce three
    # "watchOS-uppdatering" clauses, never "klockbyte".
    changes = [
        _aw_bump("2026-07-29", "Apple Watch Ultra (gen 1)", "26.6"),
        _aw_bump("2026-05-17", "Apple Watch Ultra (gen 1)", "26.5"),
        _aw_bump("2026-03-30", "Apple Watch Ultra (gen 1)", "26.4"),
    ]
    monkeypatch.setattr(
        r_bridge,
        "_run_r",
        lambda *a, **k: _raw(rows=[{"Datum": "2026-07-29"}], device_changes=changes),
    )
    out = r_bridge.r_report("report_readiness", {"n": 14})
    note = out["device_changes_note"]
    assert "klockbyte" not in note
    assert note.count("watchOS-uppdatering") == 3
