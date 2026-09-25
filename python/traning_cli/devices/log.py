"""Read/write ``$TRANING_DATA/kristian/devices.csv``.

Schema (fixed, shared with the R side building against the same file):

    valid_from,platform,model,os_version,certainty,origin,note

- ``valid_from``: ``YYYY-MM-DD``, the date the device/OS version took effect.
- ``platform``: ``apple_watch`` | ``garmin``.
- ``model``, ``os_version``: free text, may be empty.
- ``certainty``: ``exact`` (derived from data) | ``known_since`` (manual;
  the change happened at or before an otherwise-unknown date).
- ``origin``: ``manual`` | ``fit`` (derived from the historical FIT
  archive) | ``tcx`` (derived from a TCX ``<Creator>`` element — the
  live Garmin fetch and the TCX archive scan) | ``healthkit`` (derived
  from an Apple Health app export's per-record ``device`` attribute).
- ``note``: free text.

One row = one change (a new model and/or a new OS version for a platform).
On disk the file is sorted newest first (``valid_from`` descending, ties
broken by ``platform`` ascending) so a human skimming the file sees the
current device state at the top.

Invariant: at most one row per ``(platform, valid_from)``. The file only
carries a date, not a time, so two real changes on the same calendar day
(e.g. a watch arriving with 9.0.1 and updating itself to 9.1 hours later)
can never be told apart as two rows — a naive "one row per transition"
write would otherwise put them in whatever order they happened to be
read/written in, and a reader sorting by ``valid_from`` alone has no way
to recover which one was really last (Nagelfar: this produced a fictitious
"downgrade" to 9.0.1 in ``get_resting_hr``'s device-change note). The row
that survives describes the day's actual end-of-day state (the latest
model/version reached that day); any version(s) superseded earlier the
same day are named in ``note`` instead of getting a row of their own.
``certainty``/``origin`` describe the surviving row, not the ones it
absorbed. See ``collapse_same_day_rows()``, enforced by every write
(``write_devices()``) and by the FIT/TCX/HealthKit collapse paths in
``common.py`` before candidates ever reach a write.
"""

from __future__ import annotations

import csv
import os
import re
from datetime import date
from pathlib import Path
from typing import TypedDict

FIELDS = ["valid_from", "platform", "model", "os_version", "certainty", "origin", "note"]

PLATFORMS = {"apple_watch", "garmin"}
CERTAINTIES = {"exact", "known_since"}
ORIGINS = {"manual", "fit", "tcx", "healthkit"}


class DeviceRow(TypedDict):
    valid_from: str
    platform: str
    model: str
    os_version: str
    certainty: str
    origin: str
    note: str


def devices_csv_path(data_dir: Path) -> Path:
    return Path(data_dir) / "kristian" / "devices.csv"


def validate_row(row: DeviceRow | dict) -> None:
    """Raise ValueError if ``row`` doesn't satisfy the schema."""
    missing = [f for f in FIELDS if f not in row]
    if missing:
        raise ValueError(f"device row missing fields: {missing} — {row}")

    try:
        date.fromisoformat(row["valid_from"])
    except (ValueError, TypeError) as e:
        raise ValueError(f"invalid valid_from {row['valid_from']!r}: {e}") from e

    if row["platform"] not in PLATFORMS:
        raise ValueError(f"invalid platform {row['platform']!r}, expected one of {PLATFORMS}")
    if row["certainty"] not in CERTAINTIES:
        raise ValueError(f"invalid certainty {row['certainty']!r}, expected one of {CERTAINTIES}")
    if row["origin"] not in ORIGINS:
        raise ValueError(f"invalid origin {row['origin']!r}, expected one of {ORIGINS}")


def _sort_rows(rows: list[DeviceRow]) -> list[DeviceRow]:
    """Sort newest first (valid_from desc), ties broken by platform asc.

    Two stable sorts, platform first: Python's sort is stable, so rows
    that tie on the later (primary) key keep the relative order the
    earlier sort gave them.
    """
    by_platform = sorted(rows, key=lambda r: r["platform"])
    return sorted(by_platform, key=lambda r: r["valid_from"], reverse=True)


# First contiguous run of digits/dots in an os_version string — bare
# scanner output ("9.1", "20.34") parses directly; a hand-entered value
# with a prefix ("watchOS 26.6") still parses via the first match.
_VERSION_RUN_RE = re.compile(r"\d+(?:\.\d+)*")


def _version_sort_key(os_version: str) -> tuple[int, ...]:
    """Parse an os_version into a tuple that compares by magnitude.

    "9.1" -> (9, 1), "9.0.1" -> (9, 0, 1); tuple comparison then ranks
    9.1 above 9.0.1 the way a human reads those version numbers (first
    differing component wins), which plain string/float comparison
    can't do for a three-part version like "9.0.1". Unparseable or
    empty input sorts lowest (()), so a row with no os_version never
    outranks one that has it.
    """
    if not os_version:
        return ()
    match = _VERSION_RUN_RE.search(os_version)
    if not match:
        return ()
    return tuple(int(part) for part in match.group().split("."))


def collapse_same_day_rows(rows: list[DeviceRow]) -> list[DeviceRow]:
    """Enforce the devices.csv invariant: at most one row per (platform, valid_from).

    See this module's docstring for why. Rows are grouped by
    ``(platform, valid_from)`` in first-seen order; a group of one
    passes through unchanged. Within a larger group, the row with the
    highest ``os_version`` (see ``_version_sort_key()``) wins — it
    describes that day's actual end-of-day state — and keeps its own
    ``certainty``/``origin``; every other row in the group is folded
    into its ``note`` as ``"samma dag: <what it was>"`` instead of
    surviving as its own row. A tie (equal parsed version — shouldn't
    happen in practice) keeps the last row encountered.

    Idempotent: a devices.csv that's already collapsed round-trips
    through this unchanged (every group already has size 1).
    """
    groups: dict[tuple[str, str], list[DeviceRow]] = {}
    order: list[tuple[str, str]] = []
    for row in rows:
        key = (row["platform"], row["valid_from"])
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(row)

    result: list[DeviceRow] = []
    for key in order:
        group = groups[key]
        if len(group) == 1:
            result.append(group[0])
            continue

        winner_idx = max(
            range(len(group)), key=lambda i: (_version_sort_key(group[i]["os_version"]), i)
        )
        winner = group[winner_idx]
        note_bits = [winner["note"]] if winner["note"] else []
        for i, loser in enumerate(group):
            if i == winner_idx:
                continue
            what = (
                loser["os_version"]
                if loser["model"] == winner["model"]
                else f"{loser['model']} {loser['os_version']}".strip()
            )
            if what:
                note_bits.append(f"samma dag: {what}")

        merged: DeviceRow = {**winner, "note": "; ".join(note_bits)}
        result.append(merged)

    return result


def read_devices(data_dir: Path) -> list[DeviceRow]:
    """Read and validate devices.csv. Returns [] if the file doesn't exist yet."""
    path = devices_csv_path(data_dir)
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = [dict(r) for r in reader]
    for row in rows:
        validate_row(row)
    return rows  # type: ignore[return-value]


def write_devices(data_dir: Path, rows: list[DeviceRow]) -> None:
    """Validate and atomically write devices.csv (tmp file + os.replace).

    Always collapses to the one-row-per-(platform, valid_from) invariant
    first (see collapse_same_day_rows()) — every writer goes through
    here (add_device, add_devices_bulk, and any future caller), and the
    input rows may include whatever was already on file, so this is also
    what cleans up a devices.csv left dirty by a version of this code
    that predates the invariant: the next write (e.g. the next
    ``device scan --apply``) collapses it, no separate migration needed.
    """
    rows = collapse_same_day_rows(rows)
    for row in rows:
        validate_row(row)

    path = devices_csv_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    with tmp.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        for row in _sort_rows(rows):
            writer.writerow(row)
    os.replace(tmp, path)


def _find_match(
    rows: list[DeviceRow], platform: str, model: str, os_version: str
) -> DeviceRow | None:
    """Return the row for this exact (platform, model, os_version), if any."""
    return next(
        (
            r
            for r in rows
            if r["platform"] == platform and r["model"] == model and r["os_version"] == os_version
        ),
        None,
    )


def _merge_into(
    rows: list[DeviceRow], candidate: DeviceRow
) -> tuple[list[DeviceRow], str, DeviceRow | None]:
    """Merge one candidate into rows. Returns (new_rows, outcome, result_row).

    ``outcome`` is one of:
    - ``"added"`` — no row for this (platform, model, os_version) existed;
      the candidate was appended. ``result_row`` is the candidate.
    - ``"updated"`` — a row existed with a *later* ``valid_from`` than the
      candidate's; the candidate is earlier evidence for the same real
      device change, so it replaces the row on file *entirely*
      (``valid_from``, ``certainty``, ``origin``, ``note`` all follow
      the winning candidate) — exactly ``merge_candidates()``'s rule.
      A label always describes where the date it's attached to came
      from; keeping the old row's ``certainty``/``origin`` while moving
      its date would make the label describe evidence that isn't the
      reason for that date anymore (Nagelfar issue-005). ``result_row``
      is the row as it now stands.
    - ``"skipped"`` — a row existed with the same or an earlier
      ``valid_from`` already; nothing changes. This is the historical
      dedup behaviour for the common case (the same combination
      re-derived by a later scan, or logged twice by hand).
      ``result_row`` is None.

    This is the earliest-valid_from-wins rule ``merge_candidates()``
    already applies within a single scan (FIT vs TCX), extended to apply
    against the rows already on file — see Nagelfar issue-002: without
    it, whichever row was written *first* fixed the date forever, so a
    hook run before a historical backfill (or a newest-first fetch batch
    spanning a firmware update) could leave a change dated weeks or
    months late and marked ``exact``.
    """
    match = _find_match(rows, candidate["platform"], candidate["model"], candidate["os_version"])
    if match is None:
        return [*rows, candidate], "added", candidate
    if candidate["valid_from"] >= match["valid_from"]:
        return rows, "skipped", None

    new_rows = [candidate if r is match else r for r in rows]
    return new_rows, "updated", candidate


def add_device(
    data_dir: Path,
    *,
    platform: str,
    model: str = "",
    os_version: str = "",
    valid_from: str | None = None,
    certainty: str = "known_since",
    origin: str = "manual",
    note: str = "",
) -> DeviceRow | None:
    """Add or update one device-change row in devices.csv.

    Returns the row that ended up on file for this (platform, model,
    os_version) if anything changed (new row added, or an existing row's
    date moved earlier — see ``_merge_into``), or None if the candidate
    lost to an existing row with the same or an earlier date (no write).
    """
    rows = read_devices(data_dir)
    candidate: DeviceRow = {
        "valid_from": valid_from or date.today().isoformat(),
        "platform": platform,
        "model": model,
        "os_version": os_version,
        "certainty": certainty,
        "origin": origin,
        "note": note,
    }
    validate_row(candidate)

    new_rows, outcome, result_row = _merge_into(rows, candidate)
    if outcome == "skipped":
        return None
    write_devices(data_dir, new_rows)
    return result_row


def add_devices_bulk(
    data_dir: Path, candidates: list[DeviceRow]
) -> tuple[list[DeviceRow], list[DeviceRow]]:
    """Merge multiple candidate rows in one write. Returns (added, updated).

    Used by ``device scan --apply``, where writing one row at a time
    would re-read/re-write the file once per candidate. Each candidate is
    merged against the file (and against earlier candidates in this same
    batch) via the same earliest-wins rule as ``add_device`` — see
    ``_merge_into``.
    """
    rows = read_devices(data_dir)
    added: list[DeviceRow] = []
    updated: list[DeviceRow] = []
    for candidate in candidates:
        validate_row(candidate)
        rows, outcome, result_row = _merge_into(rows, candidate)
        if outcome == "added" and result_row is not None:
            added.append(result_row)
        elif outcome == "updated" and result_row is not None:
            updated.append(result_row)
    if added or updated:
        write_devices(data_dir, rows)
    return added, updated
