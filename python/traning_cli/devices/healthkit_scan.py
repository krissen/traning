"""Derive Apple Watch device-change candidates from a Health app export.

Health Auto Export's live feed (the one the ``traning fetch health`` /
``import health`` pipeline runs on) only ever sends ``sourceName`` — no
device identifier — so Apple Watch history can't be derived the way
``fit_scan``/``tcx_scan`` derive Garmin's (see ``docs/user/cli-reference.md``,
"Device log"). A full export from the iPhone Health app's own "Share All
Health Data" (a zip containing ``apple_health_export/export.xml``, or
the same ``export.xml`` unpacked) does carry one: every ``<Record>``/
``<Workout>`` element has a ``device="<<HKDevice: ...>>"`` attribute with
``hardware:`` (e.g. ``Watch6,18``) and ``software:`` (e.g. ``10.1``)
fields for whichever device produced that sample.

The export is a manual, occasional one-off, not part of the automated
data-repo pipeline. It's stored *unpacked* (restic dedups the unpacked
tree between exports far better than it would a zip) at
``$TRANING_HEALTHKIT_EXPORTS/<YYYY-MM-DD>/apple_health_export/export.xml``
— see ``docs/user/cli-reference.md``, "Device log", for where that
lives operationally. ``--healthkit-export`` also accepts a zip or a bare
``export.xml`` for ad hoc scans (a fresh export downloaded straight from
the phone, before it's been placed in the dated tree). ``traning device
scan`` skips this source with a message when nothing is found; every
other source still runs.

export.xml itself can be tens of millions of Record elements over a
multi-GB file — reading it whole, or even building one in-memory record
per element the way fit_scan/tcx_scan do per *file*, isn't an option.
Instead this reads it streaming (``ET.iterparse``, straight off disk for
a plain export.xml or via ``zipfile.ZipFile.open()`` for a zip), and
collapses on the fly: only the earliest date seen for each (hardware,
software) pair is kept, so the *result* is bounded by the number of
distinct device/firmware combinations in the whole export (a handful),
not the number of samples (tens of millions).

Bounding memory *while parsing* takes more than clearing each finished
element: ``elem.clear()`` empties an element's own attributes/children,
but the (now-empty) element stays in the root ``<HealthData>``'s child
list forever, so that list — and memory — grows by one entry per Record
regardless. The root itself is cleared too, once per element, dropping
that list back to empty (Nagelfar issue-001; measured 1.12 GB peak RSS
without this against 33 MB with it, on the real ~13M-element export).
The parser keeps its own reference to whatever ``<Correlation>``/etc.
parent is still open, so clearing root's list doesn't disturb parsing
in progress — it only drops root's references to what's already done.
"""

from __future__ import annotations

import logging
import os
import re
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

from .common import (
    collapse_device_changes,
    normalize_os_version,
    normalize_watch_model,
    plausible_date,
)
from .log import DeviceRow

log = logging.getLogger(__name__)

EXPORT_XML_MEMBER_SUFFIX = "apple_health_export/export.xml"
WATCH_RECORD_TAGS = ("Record", "Workout")
HEALTHKIT_EXPORTS_ENV = "TRANING_HEALTHKIT_EXPORTS"

_DATE_DIR_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# HealthKit's startDate/endDate/creationDate attributes are formatted
# "YYYY-MM-DD HH:MM:SS +HHMM" — local time plus an explicit offset, not
# UTC. datetime.strptime with %z parses the offset but leaves the
# hour/minute fields exactly as written; taking .date() of that value
# uses the local date as recorded, with no UTC conversion — which is
# what's wanted here (a device change is dated by the wall-clock day it
# happened on for the person wearing it, not by UTC's day boundary).
_DATE_FORMAT = "%Y-%m-%d %H:%M:%S %z"

# creationDate is when the watch actually wrote the sample; startDate is
# when the *measurement interval* began, which for an interval sample
# (HKQuantityTypeIdentifierBasalEnergyBurned above all) can be well
# before that — a watch cannot have run firmware Y before it wrote its
# first sample under Y, so startDate is the wrong signal for "software
# active since". On the real export this dated 12 of 97 device-change
# rows a day early, always from a BasalEnergyBurned sample whose
# interval crossed a midnight the firmware update also happened near
# (Nagelfar issue-002). Prefer creationDate; fall back to startDate only
# when creationDate is missing or unparseable.
_DATETIME_ATTR_PREFERENCE = ("creationDate", "startDate")


@dataclass
class HealthKitDeviceRecord:
    path: Path
    activity_date: date
    model: str
    os_version: str


@dataclass
class HealthKitScanStats:
    export_path: Path | None = None
    elements_scanned: int = 0
    ok: int = 0
    skipped_no_device: int = 0
    skipped_non_watch: int = 0
    skipped_bad_date: int = 0
    bad_date_examples: list[str] = field(default_factory=list)
    groups: int = 0


# -- locating the export -------------------------------------------------


def default_export_root() -> Path | None:
    """The root of the dated export tree, from $TRANING_HEALTHKIT_EXPORTS.

    None if the env var isn't set — there's no data-repo-relative
    fallback (unlike fit_dir/tcx_dir): the export lives outside the data
    repo entirely (see module docstring), so there's no ``data_dir`` to
    derive a default from.
    """
    value = os.environ.get(HEALTHKIT_EXPORTS_ENV)
    return Path(value) if value else None


def resolve_export_input(path: Path) -> Path | None:
    """Resolve a zip, an export.xml, or a directory to a concrete export file.

    - An existing file (zip or export.xml) is returned as is.
    - A directory is searched, in order: ``apple_health_export/export.xml``
      under it (the shape a zip unpacks to), then ``export.xml`` directly
      under it, then the newest ``*.zip`` directly under it.

    Returns None if none of that is found. ``scan_export`` decides zip
    vs. plain XML by file extension, not by anything resolved here.
    """
    if path.is_file():
        return path
    if not path.is_dir():
        return None

    nested = path / EXPORT_XML_MEMBER_SUFFIX
    if nested.is_file():
        return nested

    direct = path / "export.xml"
    if direct.is_file():
        return direct

    zips = sorted(path.glob("*.zip"))
    return zips[-1] if zips else None


def find_latest_export(root: Path) -> Path | None:
    """Find the export in the newest ``<YYYY-MM-DD>`` subdirectory of root.

    Date-named subdirectories sort correctly by name (ISO format), so a
    plain lexical sort picks the newest without needing to stat mtimes.
    Only the single newest date directory is tried — an export missing
    from it isn't assumed to exist in an older one.
    """
    if not root.is_dir():
        return None
    date_dirs = sorted(p for p in root.iterdir() if p.is_dir() and _DATE_DIR_RE.match(p.name))
    if not date_dirs:
        return None
    return resolve_export_input(date_dirs[-1])


# -- parsing ---------------------------------------------------------------


def _is_zip_path(path: Path) -> bool:
    return path.suffix.lower() == ".zip"


def _find_export_xml_member(zf: zipfile.ZipFile) -> str | None:
    for name in zf.namelist():
        if name.endswith(EXPORT_XML_MEMBER_SUFFIX):
            return name
    return None


def _parse_device_fields(device: str) -> tuple[str | None, str]:
    """Extract (hardware, software) out of a raw ``device="<<HKDevice: ...>>"``.

    The attribute is a free-text ``key:value`` list joined by ``", "``
    (comma-space) — split on that, not on a bare comma, because the
    hardware value itself contains one with no following space
    ("Watch6,18"); a bare-comma split (or a ``[^,>]+`` regex) would cut
    it off after "Watch6".

    ``hardware`` is None if the attribute has no ``hardware:`` field at
    all (e.g. an iPhone-only sample, or a sample with no device info).
    ``software`` defaults to "" — some records carry hardware without a
    software field.
    """
    hardware: str | None = None
    software = ""
    for part in device.strip().rstrip(">").split(", "):
        if part.startswith("hardware:"):
            hardware = part[len("hardware:") :].strip()
        elif part.startswith("software:"):
            software = part[len("software:") :].strip()
    return hardware, software


def _parse_local_datetime(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, _DATE_FORMAT)
    except ValueError:
        return None


def _parse_record_datetime(elem: ET.Element) -> tuple[datetime | None, str | None]:
    """Return (parsed local datetime, raw attribute value used).

    Tries ``creationDate`` first, then ``startDate`` — see
    ``_DATETIME_ATTR_PREFERENCE``. ``raw`` is the string that was
    actually parsed (or the last one that failed to parse, if none did),
    for error reporting; both are None if the element has neither
    attribute at all.
    """
    raw = None
    for attr in _DATETIME_ATTR_PREFERENCE:
        value = elem.get(attr)
        if not value:
            continue
        raw = value
        parsed = _parse_local_datetime(value)
        if parsed is not None:
            return parsed, raw
    return None, raw


def _scan_xml_stream(
    fh,
    export_path: Path,
    stats: HealthKitScanStats,
    earliest: dict[tuple[str, str], datetime],
    *,
    _root_len_probe=None,
) -> None:
    """Iterparse one export.xml stream, updating stats and earliest in place.

    Shared by the zip and plain-file branches of ``scan_export`` so the
    parsing logic exists exactly once regardless of how the bytes got
    here.

    Parses with ``events=("start", "end")`` — not just ``"end"`` — to
    capture the root ``<HealthData>`` element from its own "start" event.
    Every matched element's own ``.clear()`` only empties that element;
    without also clearing the root, root's child list (and memory) grows
    by one entry per element regardless (Nagelfar issue-001). Clearing
    root after each element keeps that list — and therefore memory —
    bounded by one element's worth, not the whole export's.

    ``_root_len_probe``, if given, is called with ``len(root)`` right
    before each clear — test-only, to assert the bound holds without
    measuring RSS.
    """
    root = None
    for event, elem in ET.iterparse(fh, events=("start", "end")):
        if event == "start":
            if root is None:
                root = elem
            continue

        if elem.tag not in WATCH_RECORD_TAGS:
            continue
        if _root_len_probe is not None:
            _root_len_probe(len(root))
        stats.elements_scanned += 1

        device = elem.get("device")
        hardware = software = None
        if device:
            hardware, software = _parse_device_fields(device)

        if not hardware:
            stats.skipped_no_device += 1
            elem.clear()
            root.clear()
            continue
        if not hardware.startswith("Watch"):
            stats.skipped_non_watch += 1
            elem.clear()
            root.clear()
            continue

        record_dt, raw_value = _parse_record_datetime(elem)
        if record_dt is None or not plausible_date(record_dt.date()):
            stats.skipped_bad_date += 1
            example = f"{raw_value!r}  ({elem.tag}, {hardware})"
            stats.bad_date_examples.append(example)
            log.warning(
                "Skipping unparseable/implausible creationDate/startDate %r for %s in %s",
                raw_value,
                hardware,
                export_path,
            )
            elem.clear()
            root.clear()
            continue

        key = (hardware, software)
        if key not in earliest or record_dt < earliest[key]:
            earliest[key] = record_dt
        stats.ok += 1
        elem.clear()
        root.clear()


def scan_export(export_path: Path) -> tuple[list[HealthKitDeviceRecord], HealthKitScanStats]:
    """Stream export.xml out of export_path and collapse to per-device-change records.

    ``export_path`` is either a zip (containing
    ``apple_health_export/export.xml``) or a plain ``export.xml`` file,
    told apart by file extension. Raises if it can't be opened/parsed —
    unlike fit_scan/tcx_scan's per-file scans, there's exactly one export
    file here, so a corrupt one is a real problem for the caller to
    surface, not something to silently count and skip.
    """
    stats = HealthKitScanStats(export_path=export_path)
    # (hardware, software) -> earliest local datetime seen for that pair
    # (full datetime, not just date — see the sort below). Bounded by
    # the number of distinct device/firmware combinations in the whole
    # export, not the number of samples.
    earliest: dict[tuple[str, str], datetime] = {}

    if _is_zip_path(export_path):
        with zipfile.ZipFile(export_path) as zf:
            member = _find_export_xml_member(zf)
            if member is None:
                raise ValueError(
                    f"{export_path}: no {EXPORT_XML_MEMBER_SUFFIX} member in export zip"
                )
            with zf.open(member) as fh:
                _scan_xml_stream(fh, export_path, stats, earliest)
    else:
        with export_path.open("rb") as fh:
            _scan_xml_stream(fh, export_path, stats, earliest)

    stats.groups = len(earliest)
    # Sorted by the full datetime before ``HealthKitDeviceRecord`` drops
    # it to a date: two pairs first seen on the same calendar day (e.g. a
    # same-day firmware update, 9.0.1 then 9.1) still need to come out in
    # the order they actually happened in, since everything downstream
    # (collapse_device_changes, the final candidate sort) sorts on date
    # alone and only a stable sort over already-chronological input
    # preserves that (Nagelfar issue-002, point 2).
    records = [
        HealthKitDeviceRecord(
            path=export_path,
            activity_date=record_dt.date(),
            model=normalize_watch_model(hardware),
            os_version=normalize_os_version(software),
        )
        for (hardware, software), record_dt in sorted(earliest.items(), key=lambda kv: kv[1])
    ]
    return records, stats


def collapse_changes(records: list[HealthKitDeviceRecord]) -> list[DeviceRow]:
    """Collapse per-(hardware, software) records into device-change candidates.

    See ``common.collapse_device_changes`` for the collapse rule. Records
    here already carry one entry per distinct (model, os_version), so
    this mostly just re-sorts by date and formats the row — the "collapse
    consecutive duplicates" part of the shared helper is a no-op unless
    normalization made two raw hardware/software pairs equal.
    """
    return collapse_device_changes(
        records, platform="apple_watch", origin="healthkit", note_prefix="healthkit-scan"
    )


def scan_and_collapse(
    export_path: Path | None = None,
) -> tuple[list[DeviceRow], HealthKitScanStats | None]:
    """Scan a HealthKit export and return (candidate rows, scan stats).

    ``export_path`` may be a zip, an export.xml, or a directory (see
    ``resolve_export_input``); it overrides the default lookup (newest
    dated subdirectory of ``$TRANING_HEALTHKIT_EXPORTS``, see
    ``find_latest_export``). Returns ``([], None)`` — not an
    empty-but-present stats object — when no export is found anywhere,
    so a caller can tell "no export available, source skipped" apart
    from "export scanned, found nothing".
    """
    if export_path is None:
        root = default_export_root()
        export_path = find_latest_export(root) if root is not None else None
    else:
        export_path = resolve_export_input(export_path)

    if export_path is None or not export_path.is_file():
        return [], None

    records, stats = scan_export(export_path)
    return collapse_changes(records), stats
