"""Tests for devices/tcx_scan.py — Creator element extraction from TCX."""

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
