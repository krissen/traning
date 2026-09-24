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
``common.normalize_os_version``) in ``_parse_creator()``, the function
they share — so the live hook's rows and the historical scan's rows use
the same canonical strings and dedup against each other correctly.
"""

from __future__ import annotations

import logging
import os
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

from .common import collapse_device_changes, normalize_model, normalize_os_version, plausible_date
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
    skipped_bad_date: int = 0
    bad_date_examples: list[str] = field(default_factory=list)


def _local(tag: str) -> str:
    """Strip an XML namespace, if any: '{ns}Creator' -> 'Creator'."""
    return tag.rsplit("}", 1)[-1]


def _parse_creator(root: ET.Element) -> TcxDeviceRecord | None:
    creator = None
    for elem in root.iter():
        if _local(elem.tag) == "Creator":
            creator = elem
            break
    if creator is None:
        return None

    name = ""
    version_parts: list[str] = []
    for child in creator.iter():
        tag = _local(child.tag)
        if tag == "Name" and child.text:
            name = child.text.strip()
        elif tag == "Version":
            for vchild in child:
                vtag = _local(vchild.tag)
                if vtag in ("VersionMajor", "VersionMinor") and vchild.text is not None:
                    version_parts.append(vchild.text.strip())

    # VersionMajor + VersionMinor -> "13.0" (BuildMajor/Minor are the
    # internal build counter, not a version number a human would log).
    os_version = ".".join(version_parts[:2]) if version_parts else ""
    return TcxDeviceRecord(
        model=normalize_model(name),
        os_version=normalize_os_version(os_version),
    )


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


def parse_tcx_scan_record(path: Path) -> TcxScanRecord | None:
    """Extract (model, os_version, activity_date) from one TCX file.

    Returns None if the file has no <Creator> or no parseable activity
    date — common for older/foreign exports. Raises on malformed XML;
    callers count those as corrupt.
    """
    tree = ET.parse(path)
    root = tree.getroot()

    device = _parse_creator(root)
    if device is None:
        return None

    activity_date = _parse_activity_date(root)
    if activity_date is None:
        return None

    return TcxScanRecord(
        path=path, activity_date=activity_date, model=device.model, os_version=device.os_version
    )


def scan_tcx_directory(tcx_dir: Path) -> tuple[list[TcxScanRecord], TcxScanStats]:
    """Scan every TCX file under tcx_dir. Never raises — errors are counted."""
    stats = TcxScanStats()
    records: list[TcxScanRecord] = []

    if not tcx_dir.is_dir():
        return records, stats

    for path in _iter_tcx_files(tcx_dir):
        stats.scanned += 1
        try:
            record = parse_tcx_scan_record(path)
        except ET.ParseError:
            log.debug("Corrupt or unreadable TCX file, skipping: %s", path, exc_info=True)
            stats.corrupt += 1
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
