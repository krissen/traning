"""Tests for devices/tcx_scan.py — Creator element extraction from TCX."""

from traning_cli.devices import tcx_scan
from traning_cli.devices.tcx_scan import extract_device_from_tcx

TCX_WITH_CREATOR = """<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Activities>
    <Activity Sport="Running">
      <Id>2023-12-29T05:48:33.000Z</Id>
      <Lap StartTime="2023-12-29T05:48:33.000Z">
        <TotalTimeSeconds>429.863</TotalTimeSeconds>
      </Lap>
      <Creator xsi:type="Device_t">
        <Name>Forerunner 945</Name>
        <UnitId>3336735483</UnitId>
        <ProductID>3113</ProductID>
        <Version>
          <VersionMajor>13</VersionMajor>
          <VersionMinor>0</VersionMinor>
          <BuildMajor>0</BuildMajor>
          <BuildMinor>0</BuildMinor>
        </Version>
      </Creator>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
"""

TCX_WITHOUT_CREATOR = """<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Running">
      <Id>2023-12-29T05:48:33.000Z</Id>
    </Activity>
  </Activities>
</TrainingCenterDatabase>
"""


def test_extract_device_from_tcx_parses_name_and_version(tmp_path):
    path = tmp_path / "activity.tcx"
    path.write_text(TCX_WITH_CREATOR)

    record = extract_device_from_tcx(path)

    assert record.model == "Forerunner 945"
    assert record.os_version == "13.0"


def test_extract_device_from_tcx_returns_none_without_creator(tmp_path):
    path = tmp_path / "activity.tcx"
    path.write_text(TCX_WITHOUT_CREATOR)

    assert extract_device_from_tcx(path) is None


def test_extract_device_from_tcx_raises_on_malformed_xml(tmp_path):
    import xml.etree.ElementTree as ET

    import pytest

    path = tmp_path / "activity.tcx"
    path.write_text("<TrainingCenterDatabase>")

    with pytest.raises(ET.ParseError):
        extract_device_from_tcx(path)


def _tcx(activity_id: str, name: str, major: str, minor: str = "0") -> str:
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


# --- parse_tcx_scan_record --------------------------------------------------


def test_parse_tcx_scan_record_extracts_date_model_version(tmp_path):
    path = tmp_path / "a.tcx"
    path.write_text(_tcx("2020-07-03T09:51:02.000Z", "Forerunner 945", "13", "0"))

    record = tcx_scan.parse_tcx_scan_record(path)

    assert record.model == "Forerunner 945"
    assert record.os_version == "13.0"
    assert record.activity_date.isoformat() == "2020-07-03"


def test_parse_tcx_scan_record_none_without_creator(tmp_path):
    path = tmp_path / "a.tcx"
    path.write_text(TCX_WITHOUT_CREATOR)

    assert tcx_scan.parse_tcx_scan_record(path) is None


def test_parse_tcx_scan_record_none_without_parseable_id(tmp_path):
    path = tmp_path / "a.tcx"
    path.write_text(_tcx("not-a-date", "Forerunner 945", "13"))

    assert tcx_scan.parse_tcx_scan_record(path) is None


# --- scan_tcx_directory ------------------------------------------------------


def test_scan_tcx_directory_counts_no_creator_and_corrupt(tmp_path):
    (tmp_path / "a.tcx").write_text(_tcx("2020-01-01T00:00:00.000Z", "fr945", "13"))
    (tmp_path / "b.TCX").write_text(TCX_WITHOUT_CREATOR)
    (tmp_path / "c.tcx").write_text("<broken")
    (tmp_path / "notes.txt").write_text("not a tcx file")

    records, stats = tcx_scan.scan_tcx_directory(tmp_path)

    assert stats.scanned == 3
    assert stats.ok == 1
    assert stats.skipped_no_creator == 1
    assert stats.corrupt == 1
    assert len(records) == 1


def test_scan_tcx_directory_skips_implausible_date(tmp_path):
    (tmp_path / "a.tcx").write_text(_tcx("2061-03-03T00:00:00.000Z", "fr945", "13"))

    records, stats = tcx_scan.scan_tcx_directory(tmp_path)

    assert records == []
    assert stats.skipped_bad_date == 1
    assert stats.bad_date_examples == ["2061-03-03  a.tcx"]


def test_scan_tcx_directory_missing_dir_returns_empty(tmp_path):
    records, stats = tcx_scan.scan_tcx_directory(tmp_path / "nope")
    assert records == []
    assert stats.scanned == 0


# --- collapse_changes / scan_and_collapse -----------------------------------


def test_tcx_collapse_changes_marks_origin_tcx(tmp_path):
    (tmp_path / "a.tcx").write_text(_tcx("2020-01-01T00:00:00.000Z", "fr945", "13", "0"))
    (tmp_path / "b.tcx").write_text(_tcx("2021-01-01T00:00:00.000Z", "fr945", "14", "0"))

    candidates, stats = tcx_scan.scan_and_collapse(tmp_path)

    assert [c["valid_from"] for c in candidates] == ["2020-01-01", "2021-01-01"]
    assert all(c["origin"] == "tcx" for c in candidates)
    assert stats.ok == 2
