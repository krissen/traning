"""Unified device-change scan: FIT archive + TCX archive + HealthKit export, merged.

One CLI command (``traning device scan``) instead of three near-identical
ones because the archives describe the *same* history from different
angles — the FIT archive only covers the fr610/fr620 era, the TCX
archive covers the whole Garmin history, the HealthKit export covers
Apple Watch — and a real device change picked up by more than one must
collapse to one row, not several. A single command that scans all
sources by default and merges keeps that invariant enforced in one place
instead of asking the caller to run several commands and reconcile the
output by hand.

``--source`` narrows to one source when only one is relevant (e.g.
after adding only FIT files, or auditing the TCX-only tail of the
history). Unlike ``fit``/``tcx``, ``healthkit`` has no per-scan archive
directory that's always populated — the export is a manual, occasional
one-off (see ``healthkit_scan``) — so ``all`` scans it too but treats a
missing export as "source skipped", never an error.
"""

from __future__ import annotations

from pathlib import Path

from . import fit_scan, healthkit_scan, tcx_scan
from .common import merge_candidates
from .fit_scan import FitScanStats
from .healthkit_scan import HealthKitScanStats
from .log import DeviceRow
from .tcx_scan import TcxScanStats

SOURCES = ("fit", "tcx", "healthkit", "all")


def scan(
    data_dir: Path, source: str = "all", healthkit_export: Path | None = None
) -> tuple[list[DeviceRow], FitScanStats | None, TcxScanStats | None, HealthKitScanStats | None]:
    """Scan the requested source(s) and return (merged candidates, fit_stats, tcx_stats, healthkit_stats).

    Each stats value is None for a source that wasn't scanned — either
    ``--source`` narrowed to another one, or (``healthkit`` only) no
    export was found — so the caller can tell "not scanned" apart from
    "scanned, found nothing".
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

    healthkit_candidates: list[DeviceRow] = []
    healthkit_stats: HealthKitScanStats | None = None
    if source in ("healthkit", "all"):
        healthkit_candidates, healthkit_stats = healthkit_scan.scan_and_collapse(
            export_path=healthkit_export
        )

    merged = merge_candidates(fit_candidates, tcx_candidates, healthkit_candidates)
    merged.sort(key=lambda r: r["valid_from"])
    return merged, fit_stats, tcx_stats, healthkit_stats
