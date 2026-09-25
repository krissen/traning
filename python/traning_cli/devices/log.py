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


def _merge_day_group(winner: DeviceRow, losers: list[DeviceRow]) -> DeviceRow:
    """Fold `losers` into `winner`'s note as "samma dag: <what it was>".

    Deduplicated against the winner's existing note, split on "; " into
    its individual fragments: re-collapsing a day whose losers were
    already absorbed in an earlier write must not grow the note every
    time the same candidate gets re-applied (Nagelfar issue-001) — the
    same "samma dag: X" phrase is only ever added once, regardless of
    how many times this runs. A loser's own manual `note`, if it has
    one, is preserved too — appended in parens after the phrase
    describing what it was — rather than silently dropped when its
    (platform, model, os_version) key gets absorbed.
    """
    existing = [p for p in winner["note"].split("; ") if p] if winner["note"] else []
    note_bits = list(existing)
    for loser in losers:
        what = (
            loser["os_version"]
            if loser["model"] == winner["model"]
            else f"{loser['model']} {loser['os_version']}".strip()
        )
        if not what:
            continue
        phrase = f"samma dag: {what}"
        if loser["note"]:
            phrase = f"{phrase} ({loser['note']})"
        if phrase not in note_bits:
            note_bits.append(phrase)
    return {**winner, "note": "; ".join(note_bits)}


def _resolve_day_group_winner(candidates: list[DeviceRow], previous_model: str | None) -> DeviceRow:
    """Pick the winning row within a same-(platform, day) group that has no
    time information to order by (see collapse_same_day_rows()).

    Rule 2: if the group spans more than one distinct model, the winner
    is whichever model differs from `previous_model` (the platform's
    resolved model on the immediately preceding day) — a device swap
    IS that day's real change, even when the new device happens to
    report a lower os_version than the one it replaced (Nagelfar: a
    Series 4 on 9.1 swapped for an Ultra (gen 1) on 9.0.1 the same day
    must resolve to the Ultra, not "the higher version"). Falls through
    to rule 3 when there's no previous_model to compare against, or
    when more than one model in the group is "new" (ambiguous — no
    single swap target to prefer).

    Rule 3: highest parsed os_version wins (see _version_sort_key()),
    over whichever candidate pool rule 2 left in play — the full group
    when rule 2 didn't narrow it, or just the "new" models when it did.
    """
    models = {c["model"] for c in candidates}
    pool = candidates
    if len(models) > 1 and previous_model is not None:
        new_model_rows = [c for c in candidates if c["model"] != previous_model]
        if len({c["model"] for c in new_model_rows}) == 1:
            pool = new_model_rows
    return max(pool, key=lambda c: _version_sort_key(c["os_version"]))


def collapse_same_day_rows(rows: list[DeviceRow]) -> list[DeviceRow]:
    """Enforce the devices.csv invariant: at most one row per (platform, valid_from).

    See this module's docstring for why. Rows carry no time
    information (the file only ever stores a date) — that's the case
    this function is for; the scan-time collapse in common.py's
    collapse_device_changes() handles the chronological case instead,
    when a source (HealthKit) actually has one. Groups are resolved
    per platform, in ascending date order, threading each platform's
    resolved model on day N forward as `previous_model` for day N+1's
    decision (see _resolve_day_group_winner()) — a group of one passes
    through unchanged; every other row in a larger group is folded into
    the winner's note as "samma dag: <what it was>" (see
    _merge_day_group()) instead of surviving as its own row.

    Idempotent: a devices.csv that's already collapsed round-trips
    through this unchanged (every group already has size 1).
    """
    if not rows:
        return rows

    by_platform: dict[str, list[DeviceRow]] = {}
    for row in rows:
        by_platform.setdefault(row["platform"], []).append(row)

    result: list[DeviceRow] = []
    for platform_rows in by_platform.values():
        groups: dict[str, list[DeviceRow]] = {}
        for row in platform_rows:
            groups.setdefault(row["valid_from"], []).append(row)

        previous_model: str | None = None
        for valid_from in sorted(groups):  # ascending: oldest day first
            group = groups[valid_from]
            if len(group) == 1:
                winner = group[0]
            else:
                winner_row = _resolve_day_group_winner(group, previous_model)
                losers = [r for r in group if r is not winner_row]
                winner = _merge_day_group(winner_row, losers)
            result.append(winner)
            previous_model = winner["model"]

    # Ascending (oldest first) — same convention collapse_device_changes()'s
    # scan-time candidates already use; callers that need newest-first
    # (e.g. r_bridge.py, matching R's device_changes() sort order) sort
    # the result themselves rather than this function imposing an order
    # its other callers (write_devices(), the scan/merge path) don't want.
    return result


def collapse_same_day_by_order(candidates: list[DeviceRow]) -> list[DeviceRow]:
    """Collapse same-(platform, day) groups by trusting `candidates`'s own order.

    For the scan-time path (common.py's collapse_device_changes(),
    ``chronological=True``) where a source really does preserve true
    chronological order for same-day entries — currently only
    HealthKit, whose scan sorts by full datetime before truncating to a
    date (see healthkit_scan.py) — the winner for a day is simply the
    LAST candidate encountered for it, no version/model heuristics
    needed: real time beats any inference from the data itself. Every
    earlier same-day candidate still folds into the winner's note (see
    _merge_day_group()), same as collapse_same_day_rows().

    Only valid when the input truly is chronologically ordered — this
    performs no check and will silently produce a wrong answer on
    out-of-order input, which is why it isn't the default (see
    collapse_same_day_rows() for the file/no-time case).
    """
    groups: dict[tuple[str, str], list[DeviceRow]] = {}
    order: list[tuple[str, str]] = []
    for row in candidates:
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
        winner_row = group[-1]
        losers = group[:-1]
        result.append(_merge_day_group(winner_row, losers))
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


def _collapsed_day_row(rows: list[DeviceRow], key: tuple[str, str]) -> DeviceRow | None:
    """The collapsed row for (platform, valid_from) ``key`` in ``rows``, if any."""
    return next(
        (r for r in collapse_same_day_rows(rows) if (r["platform"], r["valid_from"]) == key),
        None,
    )


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
    lost to an existing row with the same or an earlier date, OR (see
    ``_collapsed_day_row``, Nagelfar issue-001) if the candidate's
    (platform, model, os_version) key had already been absorbed into an
    existing day's winner — same-day collapse means that key no longer
    exists as its own row for ``_merge_into``'s exact match to find, so
    it would otherwise look like a brand new row every time, growing the
    winner's note on every re-application of a candidate that changes
    nothing. Checked by comparing the candidate's own (platform, day)
    group's collapsed state immediately before and after the merge.
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

    key = (candidate["platform"], candidate["valid_from"])
    before_day = _collapsed_day_row(rows, key)

    new_rows, outcome, _result_row = _merge_into(rows, candidate)
    if outcome == "skipped":
        return None

    after_day = _collapsed_day_row(new_rows, key)
    if after_day == before_day:
        return None  # absorbed into an already-identical day row — nothing changed

    write_devices(data_dir, new_rows)
    return after_day


def add_devices_bulk(
    data_dir: Path, candidates: list[DeviceRow]
) -> tuple[list[DeviceRow], list[DeviceRow]]:
    """Merge multiple candidate rows in one write. Returns (added, updated).

    Used by ``device scan --apply``, where writing one row at a time
    would re-read/re-write the file once per candidate. Each candidate is
    merged against the file (and against earlier candidates in this same
    batch) via the same earliest-wins rule as ``add_device`` — see
    ``_merge_into``.

    A candidate that ``_merge_into`` calls "added" (no exact
    (platform, model, os_version) match) is only actually reported as
    added if the candidate's (platform, day) group's collapsed state
    changed — see ``add_device``'s docstring and Nagelfar issue-001 for
    why an exact-key miss doesn't mean the candidate is new: its key may
    already be absorbed into an existing day's winner.
    """
    rows = read_devices(data_dir)
    added: list[DeviceRow] = []
    updated: list[DeviceRow] = []
    for candidate in candidates:
        validate_row(candidate)
        key = (candidate["platform"], candidate["valid_from"])
        before_day = _collapsed_day_row(rows, key)

        rows, outcome, result_row = _merge_into(rows, candidate)

        if outcome == "added" and result_row is not None:
            after_day = _collapsed_day_row(rows, key)
            if after_day != before_day:
                added.append(after_day)
        elif outcome == "updated" and result_row is not None:
            updated.append(result_row)
    if added or updated:
        write_devices(data_dir, rows)
    return added, updated
