"""Tests for devices/scan.py — the unified FIT+TCX scan/merge orchestrator."""

import pytest
from traning_cli.devices import scan as scan_mod


def _make_data_dir(tmp_path):
    fit_dir = tmp_path / "kristian" / "filer" / "fit"
    tcx_dir = tmp_path / "kristian" / "filer" / "tcx"
    fit_dir.mkdir(parents=True)
    tcx_dir.mkdir(parents=True)
    return tmp_path, fit_dir, tcx_dir


def _tcx(activity_id, name, major, minor="0"):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Activities>
    <Activity Sport="Running">
      <Id>{activity_id}</Id>
      <Creator xsi:type="Device_t">
        <Name>{name}</Name>
        <Version><VersionMajor>{major}</VersionMajor><VersionMinor>{minor}</VersionMinor></Version>
      </Creator>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
"""


def test_scan_source_tcx_only_leaves_fit_stats_none(tmp_path):
    data_dir, _fit_dir, tcx_dir = _make_data_dir(tmp_path)
    (tcx_dir / "a.tcx").write_text(_tcx("2020-01-01T00:00:00.000Z", "fr945", "13"))

    candidates, fit_stats, tcx_stats = scan_mod.scan(data_dir, source="tcx")

    assert fit_stats is None
    assert tcx_stats is not None
    assert tcx_stats.ok == 1
    assert len(candidates) == 1
    assert candidates[0]["origin"] == "tcx"


def test_scan_source_fit_only_leaves_tcx_stats_none(tmp_path):
    data_dir, _fit_dir, _tcx_dir = _make_data_dir(tmp_path)
    # No FIT files: an empty archive scans cleanly (0 files), still not None.
    candidates, fit_stats, tcx_stats = scan_mod.scan(data_dir, source="fit")

    assert fit_stats is not None
    assert tcx_stats is None
    assert candidates == []


def test_scan_all_merges_and_sorts_by_valid_from(tmp_path):
    data_dir, _fit_dir, tcx_dir = _make_data_dir(tmp_path)
    (tcx_dir / "a.tcx").write_text(_tcx("2021-01-01T00:00:00.000Z", "fr945", "13"))
    (tcx_dir / "b.tcx").write_text(_tcx("2020-01-01T00:00:00.000Z", "fr620", "3"))

    candidates, fit_stats, tcx_stats = scan_mod.scan(data_dir, source="all")

    assert fit_stats is not None and tcx_stats is not None
    assert [c["valid_from"] for c in candidates] == ["2020-01-01", "2021-01-01"]


def test_scan_invalid_source_raises(tmp_path):
    data_dir, _fit_dir, _tcx_dir = _make_data_dir(tmp_path)
    with pytest.raises(ValueError, match="invalid source"):
        scan_mod.scan(data_dir, source="withings")


def test_scan_all_merges_same_device_across_sources(tmp_path, monkeypatch):
    """A device change picked up by both archives with the exact same
    (platform, model, os_version) collapses to a single merged row."""
    data_dir, _fit_dir, tcx_dir = _make_data_dir(tmp_path)
    (tcx_dir / "a.tcx").write_text(_tcx("2021-06-01T00:00:00.000Z", "fr945", "13"))

    from traning_cli.devices import fit_scan

    def fake_scan_and_collapse(_fit_dir):
        from traning_cli.devices.fit_scan import FitScanStats

        return (
            [
                {
                    "valid_from": "2021-01-01",
                    "platform": "garmin",
                    "model": "fr945",
                    "os_version": "13.0",
                    "certainty": "exact",
                    "origin": "fit",
                    "note": "fit-scan: x.fit",
                }
            ],
            FitScanStats(scanned=1, ok=1),
        )

    monkeypatch.setattr(fit_scan, "scan_and_collapse", fake_scan_and_collapse)

    candidates, _fit_stats, _tcx_stats = scan_mod.scan(data_dir, source="all")

    matching = [c for c in candidates if c["model"] == "fr945" and c["os_version"] == "13.0"]
    assert len(matching) == 1
    assert matching[0]["valid_from"] == "2021-01-01"  # earliest wins
    assert matching[0]["origin"] == "fit"
