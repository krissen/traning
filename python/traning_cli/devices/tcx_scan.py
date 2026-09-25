"""Extract creator-device info from TCX files.

The Garmin fetch pipeline (``garmin/download.py``) downloads TCX, not FIT
— the historical ``kristian/filer/fit/`` archive predates it (FIT only
covers the fr610/fr620 era) and isn't fed by the live fetch. TCX carries
the same creator-device fields (product name + firmware version) for the
whole history in ``kristian/filer/tcx/``, so this module covers two uses:

- ``extract_device_from_tcx()``: single-file extraction, used by the
  post-fetch device-log hook in ``garmin/download.py``.
- ``scan_tcx_directory()`` / ``scan_and_collapse()``: the same historical-
  archive scan ``fit_scan.py`` does, but over the TCX archive.

Both normalize model/OS version (see ``common.normalize_model`` /
``common.normalize_os_version``) and filter out known generic-device
placeholders (see ``common.is_generic_device``) in ``_parse_creator()``,
the function they share — so the live hook's rows and the historical
scan's rows use the same canonical strings and skip the same noise.
"""

from __future__ import annotations

import logging
import os
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

from .common import (
    collapse_device_changes,
    is_generic_device,
    normalize_model,
    normalize_os_version,
    plausible_date,
)
from .log import DeviceRow

log = logging.getLogger(__name__)


@dataclass
class TcxDeviceRecord:
    model: str
    os_version: str


@dataclass
class TcxScanRecord:
    path: Path
    activity_date: date
    model: str
    os_version: str


@dataclass
class TcxScanStats:
    scanned: int = 0
    ok: int = 0
    corrupt: int = 0
    skipped_no_creator: int = 0
    skipped_generic_device: int = 0
    skipped_bad_date: int = 0
    bad_date_examples: list[str] = field(default_factory=list)


def _local(tag: str) -> str:
    """Strip an XML namespace, if any: '{ns}Creator' -> 'Creator'."""
    return tag.rsplit("}", 1)[-1]


def _parse_creator_element(root: ET.Element) -> tuple[TcxDeviceRecord | None, bool]:
    """Parse the raw <Creator> block. Returns (record, is_generic).

    ``record`` is None if there's no <Creator> element at all.
    ``is_generic`` is True if a Creator was found but its raw <Name>
    is a known placeholder (see ``common.is_generic_device`` — checked
    on the raw name, not <ProductID>: the same ProductID can also be a
    real, correctly-resolved device in other files, e.g. 1345 is both
    "Allmän ANT-enhet" and, far more often, "Garmin Forerunner 610").
    ``record`` is still populated when generic, so a caller that needs
    the raw values can use them; the two public functions below both
    treat generic as "no usable device", just counted separately.
    """
    creator = None
    for elem in root.iter():
        if _local(elem.tag) == "Creator":
            creator = elem
            break
    if creator is None:
        return None, False

    name = ""
    version_major = ""
    version_minor = ""
    for child in creator.iter():
        tag = _local(child.tag)
        if tag == "Name" and child.text:
            name = child.text.strip()
        elif tag == "Version":
            for vchild in child:
                vtag = _local(vchild.tag)
                if vtag == "VersionMajor" and vchild.text is not None:
                    version_major = vchild.text.strip()
                elif vtag == "VersionMinor" and vchild.text is not None:
                    version_minor = vchild.text.strip()
                # BuildMajor/BuildMinor are the internal build counter,
                # not a version number a human would log — skipped.

    # Garmin's minor version is hundredths, always 0 or a two-digit
    # multiple of ten in this archive (2/70, 3/30, 5/0 .. 13/70) and
    # agreeing with FIT's software_version (2.7, 3.3, ...). A raw join
    # loses that: minor=5 would give "13.5" (thirteen-point-five) instead
    # of "13.05" — silently merging with a real x.50 and failing to merge
    # with FIT's equivalent "x.05". Zero-pad minor to two digits first,
    # then let normalize_os_version() reduce "13.00" -> "13", "2.70" ->
    # "2.7" as it already does for a well-formed value.
    if version_major and version_minor:
        try:
            os_version = f"{int(version_major)}.{int(version_minor):02d}"
        except ValueError:
            # Non-numeric Version{Major,Minor} text — not seen in this
            # archive, but fall back to the raw join rather than raise.
            os_version = f"{version_major}.{version_minor}"
    else:
        os_version = version_major
    record = TcxDeviceRecord(
        model=normalize_model(name),
        os_version=normalize_os_version(os_version),
    )
    return record, is_generic_device(name)


def _parse_creator(root: ET.Element) -> TcxDeviceRecord | None:
    """Parse <Creator><Name>/<Version>, filtering out generic placeholders."""
    record, is_generic = _parse_creator_element(root)
    if record is None or is_generic:
        return None
    return record


def _parse_activity_date(root: ET.Element) -> date | None:
    """First <Id> under an Activity: its start time, e.g. '2023-12-29T05:48:33.000Z'."""
    for elem in root.iter():
        if _local(elem.tag) == "Id" and elem.text:
            text = elem.text.strip().replace("Z", "+00:00")
            try:
                return datetime.fromisoformat(text).date()
            except ValueError:
                return None
    return None


def extract_device_from_tcx(path: Path) -> TcxDeviceRecord | None:
    """Parse <Creator><Name>/<Version> out of a TCX file.

    Returns None if there's no Creator element (older/foreign exports).
    Raises on malformed XML — the caller decides how to handle that.
    """
    tree = ET.parse(path)
    return _parse_creator(tree.getroot())


def _iter_tcx_files(tcx_dir: Path):
    """Yield every *.tcx/*.TCX file under tcx_dir, following symlinks."""
    for root, _dirs, files in os.walk(tcx_dir, followlinks=True):
        for name in files:
            if name.lower().endswith(".tcx"):
                yield Path(root) / name


def _scan_one_tcx_file(path: Path) -> tuple[TcxScanRecord | None, str | None]:
    """Parse one TCX file for scan purposes.

    Returns (record, skip_reason). skip_reason is None on success, else
    one of "no_creator" / "generic_device" / "no_date" — kept distinct
    from the plausible-date check (a separate concern, checked by the
    caller) so scan_tcx_directory can count each reason separately
    without re-parsing the file. Raises ET.ParseError on malformed XML;
    callers count those as corrupt.
    """
    tree = ET.parse(path)
    root = tree.getroot()

    device, is_generic = _parse_creator_element(root)
    if device is None:
        return None, "no_creator"
    if is_generic:
        return None, "generic_device"

    activity_date = _parse_activity_date(root)
    if activity_date is None:
        return None, "no_date"

    record = TcxScanRecord(
        path=path, activity_date=activity_date, model=device.model, os_version=device.os_version
    )
    return record, None


def parse_tcx_scan_record(path: Path) -> TcxScanRecord | None:
    """Extract (model, os_version, activity_date) from one TCX file.

    Returns None if the file has no usable device — no <Creator>, a
    generic-placeholder device (see ``common.is_generic_device``), or no
    parseable activity date. Raises on malformed XML; callers count
    those as corrupt.
    """
    record, _skip_reason = _scan_one_tcx_file(path)
    return record


def scan_tcx_directory(tcx_dir: Path) -> tuple[list[TcxScanRecord], TcxScanStats]:
    """Scan every TCX file under tcx_dir. Never raises — errors are counted."""
    stats = TcxScanStats()
    records: list[TcxScanRecord] = []

    if not tcx_dir.is_dir():
        return records, stats

    for path in _iter_tcx_files(tcx_dir):
        stats.scanned += 1
        try:
            record, skip_reason = _scan_one_tcx_file(path)
        except ET.ParseError:
            log.debug("Corrupt or unreadable TCX file, skipping: %s", path, exc_info=True)
            stats.corrupt += 1
            continue
        if skip_reason == "generic_device":
            stats.skipped_generic_device += 1
            continue
        if record is None:
            stats.skipped_no_creator += 1
            continue
        if not plausible_date(record.activity_date):
            stats.skipped_bad_date += 1
            stats.bad_date_examples.append(f"{record.activity_date.isoformat()}  {path.name}")
            log.warning("Skipping implausible activity date %s in %s", record.activity_date, path)
            continue
        stats.ok += 1
        records.append(record)

    return records, stats


def collapse_changes(records: list[TcxScanRecord]) -> list[DeviceRow]:
    """Collapse a chronological TCX record list into device-change candidates.

    See ``common.collapse_device_changes`` for the collapse rule.
    """
    return collapse_device_changes(records, platform="garmin", origin="tcx", note_prefix="tcx-scan")


def scan_and_collapse(tcx_dir: Path) -> tuple[list[DeviceRow], TcxScanStats]:
    """Scan tcx_dir and return (candidate device-change rows, scan stats)."""
    records, stats = scan_tcx_directory(tcx_dir)
    return collapse_changes(records), stats
