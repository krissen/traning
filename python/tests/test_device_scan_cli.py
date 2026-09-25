"""CLI-level tests for `traning device scan` — Nagelfar issue-003.

A corrupt/truncated HealthKit export must surface as a clean
ClickException (message naming the file, exit code 1), not a raw
traceback — the scan-level tests in test_healthkit_scan.py cover that
``scan_export`` raises ``ValueError``; these confirm the CLI actually
catches it.
"""

import csv
import zipfile

from click.testing import CliRunner
from traning_cli.devices.log import FIELDS, devices_csv_path, read_devices
from traning_cli.main import cli

TCX_ONE_FILE = """<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Activities>
    <Activity Sport="Running">
      <Id>2023-01-15T08:00:00.000Z</Id>
      <Creator xsi:type="Device_t">
        <Name>Forerunner 945</Name>
        <Version><VersionMajor>13</VersionMajor><VersionMinor>0</VersionMinor></Version>
      </Creator>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
"""


def _write_raw_devices_csv(data_dir, rows):
    """Write rows verbatim, without collapsing — a pre-invariant file."""
    path = devices_csv_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def _row(**overrides):
    row = {
        "valid_from": "2023-01-15",
        "platform": "garmin",
        "model": "Forerunner 945",
        "os_version": "13",
        "certainty": "exact",
        "origin": "tcx",
        "note": "tcx-scan: a.tcx",
    }
    row.update(overrides)
    return row


def test_device_scan_healthkit_malformed_xml_is_a_clean_error(traning_data_dir):
    xml_path = traning_data_dir / "trunc.xml"
    xml_path.write_text("<HealthData><Record")

    result = CliRunner().invoke(
        cli, ["device", "scan", "--source", "healthkit", "--healthkit-export", str(xml_path)]
    )

    assert result.exit_code != 0
    assert result.exception is None or isinstance(result.exception, SystemExit)
    assert "Traceback" not in result.output
    assert "malformed export.xml" in result.output
    assert str(xml_path) in result.output


def test_device_scan_healthkit_bad_zip_is_a_clean_error(traning_data_dir):
    zip_path = traning_data_dir / "bad.zip"
    zip_path.write_bytes(b"not actually a zip file")

    result = CliRunner().invoke(
        cli, ["device", "scan", "--source", "healthkit", "--healthkit-export", str(zip_path)]
    )

    assert result.exit_code != 0
    assert result.exception is None or isinstance(result.exception, SystemExit)
    assert "Traceback" not in result.output
    assert "not a valid zip file" in result.output
    assert str(zip_path) in result.output


def test_device_scan_healthkit_missing_export_xml_member_is_a_clean_error(traning_data_dir):
    zip_path = traning_data_dir / "no-export-xml.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("apple_health_export/export_cda.xml", "<HealthData/>")

    result = CliRunner().invoke(
        cli, ["device", "scan", "--source", "healthkit", "--healthkit-export", str(zip_path)]
    )

    assert result.exit_code != 0
    assert "Traceback" not in result.output
    assert "export.xml" in result.output


# --- scan --apply rewrites a non-canonical log and reports it -------------


def _tcx_archive(data_dir):
    tcx_dir = data_dir / "kristian" / "filer" / "tcx"
    tcx_dir.mkdir(parents=True, exist_ok=True)
    (tcx_dir / "a.tcx").write_text(TCX_ONE_FILE)


def test_device_scan_apply_reports_tidy_of_pre_invariant_file(traning_data_dir):
    """The scan's only candidate is already logged, but the file holds a
    pre-invariant duplicate day: --apply rewrites it and says so."""
    _tcx_archive(traning_data_dir)
    _write_raw_devices_csv(
        traning_data_dir,
        [
            _row(),  # matches the scan candidate -> already logged
            _row(valid_from="2022-10-06", os_version="13"),
            _row(valid_from="2022-10-06", os_version="14"),
        ],
    )

    result = CliRunner().invoke(cli, ["device", "scan", "--source", "tcx", "--apply"])

    assert result.exit_code == 0, result.output
    assert "0 nya rader, 0 uppdaterade (tidigare datum), 1 redan loggade" in result.output
    assert "Städade 1 dag med dubbletter" in result.output
    rows = read_devices(traning_data_dir)
    assert len(rows) == 2
    assert sum(1 for r in rows if r["valid_from"] == "2022-10-06") == 1


def test_device_scan_apply_canonical_file_reports_no_tidy(traning_data_dir):
    """An already-canonical file: today's outcome, word for word, no tidy line."""
    _tcx_archive(traning_data_dir)
    _write_raw_devices_csv(traning_data_dir, [_row()])

    result = CliRunner().invoke(cli, ["device", "scan", "--source", "tcx", "--apply"])

    assert result.exit_code == 0, result.output
    assert "0 nya rader, 0 uppdaterade (tidigare datum), 1 redan loggade" in result.output
    assert "Städade" not in result.output


def test_device_scan_empty_archive_tidies_and_reports(traning_data_dir):
    """No candidates at all: the file is still rewritten and reported."""
    _write_raw_devices_csv(
        traning_data_dir,
        [
            _row(valid_from="2022-10-06", os_version="13"),
            _row(valid_from="2022-10-06", os_version="14"),
        ],
    )

    result = CliRunner().invoke(cli, ["device", "scan", "--source", "fit", "--apply"])

    assert result.exit_code == 0, result.output
    assert "Inga enhetsbyten hittade." in result.output
    assert "Städade 1 dag med dubbletter" in result.output
    assert len(read_devices(traning_data_dir)) == 1


def test_device_scan_empty_archive_canonical_file_outcome_unchanged(traning_data_dir):
    """No candidates and a canonical file: today's output, untouched file."""
    _write_raw_devices_csv(traning_data_dir, [_row()])
    mtime_before = devices_csv_path(traning_data_dir).stat().st_mtime_ns

    result = CliRunner().invoke(cli, ["device", "scan", "--source", "fit", "--apply"])

    assert result.exit_code == 0, result.output
    assert "Inga enhetsbyten hittade." in result.output
    assert "Städade" not in result.output
    assert devices_csv_path(traning_data_dir).stat().st_mtime_ns == mtime_before
