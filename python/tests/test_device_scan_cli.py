"""CLI-level tests for `traning device scan` — Nagelfar issue-003.

A corrupt/truncated HealthKit export must surface as a clean
ClickException (message naming the file, exit code 1), not a raw
traceback — the scan-level tests in test_healthkit_scan.py cover that
``scan_export`` raises ``ValueError``; these confirm the CLI actually
catches it.
"""

import zipfile

from click.testing import CliRunner
from traning_cli.main import cli


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
