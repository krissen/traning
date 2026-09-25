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
    assert record.os_version == "13"  # normalize_os_version: "13.0" -> "13"


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


def _tcx(activity_id: str, name: str, major: str, minor: str = "0", product_id: str = "") -> str:
    product_id_xml = f"<ProductID>{product_id}</ProductID>" if product_id else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <Activities>
    <Activity Sport="Running">
      <Id>{activity_id}</Id>
      <Creator xsi:type="Device_t">
        <Name>{name}</Name>
        {product_id_xml}
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
    assert record.os_version == "13"  # normalize_os_version: "13.0" -> "13"
    assert record.activity_date.isoformat() == "2020-07-03"


# --- VersionMinor zero-padding (Nagelfar issue-004) -------------------------
#
# Garmin's minor version is hundredths: a raw <VersionMinor> of "5" means
# x.05, not x.5. Joining without zero-padding would merge x.05 and x.50
# into the same os_version, and would fail to merge a TCX-derived x.05
# with FIT's equivalent 2-decimal float form.


def test_parse_tcx_scan_record_single_digit_minor_is_hundredths(tmp_path):
    path = tmp_path / "a.tcx"
    path.write_text(_tcx("2020-01-01T00:00:00.000Z", "Forerunner 945", "13", "5"))

    record = tcx_scan.parse_tcx_scan_record(path)

    assert record.os_version == "13.05"


def test_parse_tcx_scan_record_two_digit_minor_zero_padded_matches_fit_form(tmp_path):
    path = tmp_path / "a.tcx"
    path.write_text(_tcx("2020-01-01T00:00:00.000Z", "Forerunner 945", "13", "50"))

    record = tcx_scan.parse_tcx_scan_record(path)

    # normalize_os_version("13.50") -> "13.5", matching FIT's software_version 13.5.
    assert record.os_version == "13.5"


def test_parse_tcx_scan_record_minor_05_and_50_do_not_collide(tmp_path):
    (tmp_path / "a.tcx").write_text(_tcx("2020-01-01T00:00:00.000Z", "Forerunner 945", "13", "5"))
    (tmp_path / "b.tcx").write_text(_tcx("2020-02-01T00:00:00.000Z", "Forerunner 945", "13", "50"))

    record_a = tcx_scan.parse_tcx_scan_record(tmp_path / "a.tcx")
    record_b = tcx_scan.parse_tcx_scan_record(tmp_path / "b.tcx")

    assert record_a.os_version == "13.05"
    assert record_b.os_version == "13.5"
    assert record_a.os_version != record_b.os_version


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


def test_scan_tcx_directory_counts_generic_device_separately(tmp_path):
    (tmp_path / "a.tcx").write_text(
        _tcx("2011-11-09T16:54:16.000Z", "Allmän ANT-enhet", "0", "0", product_id="1345")
    )
    (tmp_path / "b.tcx").write_text(
        _tcx("2006-05-24T17:12:44.000Z", "Garmin Fitness Device", "1", "0", product_id="1")
    )
    (tmp_path / "c.tcx").write_text(
        _tcx("2020-01-01T00:00:00.000Z", "Forerunner 945", "13", "0", product_id="3113")
    )

    records, stats = tcx_scan.scan_tcx_directory(tmp_path)

    assert stats.scanned == 3
    assert stats.ok == 1
    assert stats.skipped_generic_device == 2
    assert stats.skipped_no_creator == 0
    assert len(records) == 1
    assert records[0].model == "Forerunner 945"


def test_generic_filter_keys_on_name_not_product_id(tmp_path):
    """Regression test: ProductID 1345 is ALSO Forerunner 610's real,
    correctly-resolved product id in most files — filtering on ProductID
    would wrongly drop those too. Only the literal generic name is
    filtered."""
    (tmp_path / "a.tcx").write_text(
        _tcx("2011-11-09T16:54:16.000Z", "Allmän ANT-enhet", "0", "0", product_id="1345")
    )
    (tmp_path / "b.tcx").write_text(
        # minor="70" (not "7"): Garmin's minor is hundredths, so this is
        # the archive's real FR610 firmware "2.70", not "2.7".
        _tcx("2012-07-16T00:00:00.000Z", "Garmin Forerunner 610", "2", "70", product_id="1345")
    )

    records, stats = tcx_scan.scan_tcx_directory(tmp_path)

    assert stats.skipped_generic_device == 1
    assert stats.ok == 1
    assert records[0].model == "Forerunner 610"


def test_extract_device_from_tcx_filters_generic_device(tmp_path):
    """The hook (extract_device_from_tcx) must also skip generic devices."""
    path = tmp_path / "a.tcx"
    path.write_text(
        _tcx("2011-11-09T16:54:16.000Z", "Allmän ANT-enhet", "0", "0", product_id="1345")
    )

    assert extract_device_from_tcx(path) is None


def test_parse_tcx_scan_record_none_for_generic_device(tmp_path):
    path = tmp_path / "a.tcx"
    path.write_text(
        _tcx("2006-05-24T17:12:44.000Z", "Garmin Fitness Device", "1", "0", product_id="1")
    )

    assert tcx_scan.parse_tcx_scan_record(path) is None


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
