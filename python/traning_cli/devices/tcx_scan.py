"""Extract creator-device info from a single TCX file.

The Garmin fetch pipeline (``garmin/download.py``) downloads TCX, not FIT
— the historical ``kristian/filer/fit/`` archive predates it and isn't
fed by the live fetch. The post-fetch device-log hook therefore reads the
``<Creator>`` element TCX already carries (same watch, same field: product
name + firmware version) instead of scanning for FIT files that are never
downloaded. See ``fit_scan.py`` for the historical-archive FIT scanner.
"""

from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)


@dataclass
class TcxDeviceRecord:
    model: str
    os_version: str


def _local(tag: str) -> str:
    """Strip an XML namespace, if any: '{ns}Creator' -> 'Creator'."""
    return tag.rsplit("}", 1)[-1]


def extract_device_from_tcx(path: Path) -> TcxDeviceRecord | None:
    """Parse <Creator><Name>/<Version> out of a TCX file.

    Returns None if there's no Creator element (older/foreign exports).
    Raises on malformed XML — the caller decides how to handle that.
    """
    tree = ET.parse(path)
    root = tree.getroot()

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

    return TcxDeviceRecord(model=name, os_version=os_version)
