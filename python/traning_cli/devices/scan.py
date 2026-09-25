"""Unified device-change scan: FIT archive + TCX archive, merged.

One CLI command (``traning device scan``) instead of two near-identical
ones (``scan-fit`` / ``scan-tcx``) because the two archives describe the
*same* history from different angles — the FIT archive only covers the
fr610/fr620 era, the TCX archive covers the whole history — and a real
device change picked up by both must collapse to one row, not two. A
single command that scans both by default and merges keeps that
invariant enforced in one place instead of asking the caller to run two
commands and reconcile the output by hand.

``--source`` narrows to one archive when only one is relevant (e.g.
after adding only FIT files, or auditing the TCX-only tail of the
history).
"""

from __future__ import annotations

from pathlib import Path

from . import fit_scan, tcx_scan
from .common import merge_candidates
from .fit_scan import FitScanStats
from .log import DeviceRow
from .tcx_scan import TcxScanStats

SOURCES = ("fit", "tcx", "all")


def scan(
    data_dir: Path, source: str = "all"
) -> tuple[list[DeviceRow], FitScanStats | None, TcxScanStats | None]:
    """Scan the requested archive(s) and return (merged candidates, fit_stats, tcx_stats).

    ``fit_stats``/``tcx_stats`` is None for the archive that wasn't scanned
    (``--source`` narrowed to the other one), so the caller can tell
    "not scanned" apart from "scanned, found nothing".
    """
    if source not in SOURCES:
        raise ValueError(f"invalid source {source!r}, expected one of {SOURCES}")

    fit_candidates: list[DeviceRow] = []
    fit_stats: FitScanStats | None = None
    if source in ("fit", "all"):
        fit_dir = data_dir / "kristian" / "filer" / "fit"
        fit_candidates, fit_stats = fit_scan.scan_and_collapse(fit_dir)

    tcx_candidates: list[DeviceRow] = []
    tcx_stats: TcxScanStats | None = None
    if source in ("tcx", "all"):
        tcx_dir = data_dir / "kristian" / "filer" / "tcx"
        tcx_candidates, tcx_stats = tcx_scan.scan_and_collapse(tcx_dir)

    merged = merge_candidates(fit_candidates, tcx_candidates)
    merged.sort(key=lambda r: r["valid_from"])
    return merged, fit_stats, tcx_stats
