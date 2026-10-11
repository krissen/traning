"""Compare Apple Watch and Garmin heart rate, distance and elevation per run.

Reads the Garmin Connect exports (*_summary.json + .tcx) and the files
fetch_srv.py wrote, pairs each Garmin run with the Apple Watch workout
that overlaps it most (source name contains "Watch"; Garmin's own copy in
Apple Health is excluded), puts both heart-rate series on a 1 s grid and
reports agreement. Both watches measure at the wrist, so there is no
reference: these are agreement figures, not accuracy.

Usage:
    python compare.py GARMIN_DIR SRV_DIR   # writes SRV_DIR/pairs.csv
"""

import csv
import datetime as dt
import glob
import json
import math
import os
import statistics
import sys
import xml.etree.ElementTree as ET

import numpy as np

NS = {"t": "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"}
# Every date in the analysed window (May-Oct 2026) is CEST.
TZ = dt.timezone(dt.timedelta(hours=2))
# The Ultra 4 replaced the Ultra (gen 1) on this date (devices.csv).
U4_FROM = dt.date(2026, 9, 25)
# Below this many Apple Watch HR points per minute a run counts as sparse.
DENSE_MIN = 6
# A Watch workout pairs with a Garmin run only if it covers at least this
# share of the Garmin run. A fragment (a recording stopped early) would
# otherwise be compared with the whole run, and its distance with the
# whole run's distance.
MIN_COVERAGE = 0.8
# Seconds with no sample within this distance in either series are left
# out: interpolating across a pause or a sensor dropout would invent
# readings. Smart recording spaces Garmin points up to ~10 s, the Watch
# ~5 s in a workout.
MAX_GAP_S = 30


def _covered(grid: np.ndarray, t: np.ndarray) -> np.ndarray:
    """True where each grid second is bracketed by samples at most MAX_GAP_S apart.

    Testing only the nearest sample would still accept the first and last
    MAX_GAP_S of a long pause and interpolate across them; the bracketing
    interval is what np.interp actually spans.
    """
    i = np.searchsorted(t, grid, side="right")
    inside = (i > 0) & (i < len(t))
    exact = np.isin(grid, t)
    lo = t[np.clip(i - 1, 0, len(t) - 1)]
    hi = t[np.clip(i, 0, len(t) - 1)]
    return exact | (inside & (hi - lo <= MAX_GAP_S))


def load_json(path: str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def hae_ts(s: str) -> float:
    return dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z").timestamp()


def tcx_hr(path: str) -> np.ndarray:
    out = []
    for tp in ET.parse(path).getroot().iterfind(".//t:Trackpoint", NS):
        hr = tp.find("t:HeartRateBpm/t:Value", NS)
        if hr is None:
            continue
        t = dt.datetime.fromisoformat(tp.find("t:Time", NS).text.replace("Z", "+00:00"))
        out.append((t.timestamp(), float(hr.text)))
    return np.array(out)


def best_watch_workout(workouts: list, g0: float, g1: float):
    """The Apple Watch workout covering [g0, g1] most, if it covers enough.

    The overlap must reach MIN_COVERAGE of the Garmin run and half of the
    Watch workout, so neither a fragment nor a much longer session that
    happens to contain the run is taken as its twin.
    """
    best = None
    for w in workouts:
        if "Watch" not in (w.get("source") or {}).get("name", ""):
            continue
        a0, a1 = hae_ts(w["start"]), hae_ts(w["end"])
        overlap = min(a1, g1) - max(a0, g0)
        enough = overlap >= MIN_COVERAGE * (g1 - g0) and overlap > 0.5 * (a1 - a0)
        if enough and (best is None or overlap > best[0]):
            best = (overlap, w, a0, a1)
    return best


def compare_run(g: dict, tcx: str, w: dict, a0: float, a1: float, hr_body: dict) -> dict:
    """Per-run figures. Distance, elevation, max HR and coverage come for
    every pair; the heart-rate agreement only where at least 60 seconds
    are comparable in both series."""
    g0 = dt.datetime.fromisoformat(g["startTimeGMT"].replace(" ", "T") + "+00:00").timestamp()
    g1 = g0 + g["elapsedDuration"]
    metrics = hr_body["data"]["metrics"]
    samples = metrics[0]["data"] if metrics else []
    hr = np.array(
        sorted((hae_ts(x["date"]), x["Avg"]) for x in samples if "Watch" in x.get("source", ""))
    ).reshape(-1, 2)
    garmin = tcx_hr(tcx).reshape(-1, 2)
    km_aw = w["distance"]["qty"]
    # Coverage is measured over the whole overlap of the two workouts, so
    # a series that starts late or stops early counts as uncovered there.
    full = np.arange(math.ceil(max(a0, g0)), math.floor(min(a1, g1)))
    cov_aw = _covered(full, hr[:, 0]) if len(hr) > 1 else np.zeros(len(full), bool)
    cov_g = _covered(full, garmin[:, 0]) if len(garmin) > 1 else np.zeros(len(full), bool)
    in_workout = hr[(hr[:, 0] >= a0) & (hr[:, 0] <= a1)]
    out = {
        "km_aw": round(km_aw, 2),
        "km_pct": round(100 * (km_aw * 1000 - g["distance"]) / g["distance"], 1),
        "start_off_s": round(a0 - g0),
        "max_g": g.get("maxHR"),
        "max_aw": float(in_workout[:, 1].max()) if len(in_workout) else None,
        "aw_pts_per_min": round(len(in_workout) / ((a1 - a0) / 60), 1),
        # Share of the overlap lying between samples at most MAX_GAP_S apart.
        "cov_aw": round(float(cov_aw.mean()), 3) if len(full) else None,
        "cov_g": round(float(cov_g.mean()), 3) if len(full) else None,
        "elev_g": round(g.get("elevationGain") or 0),
        "elev_aw": round((w.get("elevationUp") or {}).get("qty", 0)),
    }
    if len(in_workout):
        minute = ((in_workout[:, 0] - a0) // 60).astype(int)
        # HAE's minute aggregates carry Min/Avg/Max, so a stored minute keeps
        # the peak. The peak of the per-minute MEAN is what a reader of Avg
        # alone would see; it is reported to show that difference.
        out["max_aw_minavg"] = round(
            float(max(in_workout[minute == k, 1].mean() for k in np.unique(minute)))
        )
    grid = full[cov_aw & cov_g]
    if len(grid) < 60:
        return out
    ha = np.interp(grid, hr[:, 0], hr[:, 1])
    hg = np.interp(grid, garmin[:, 0], garmin[:, 1])
    diff = ha - hg
    # Shift the Watch series against Garmin's and keep the best-correlated lag.
    lag = max(
        range(-30, 31),
        key=lambda s: np.corrcoef(np.interp(grid + s, hr[:, 0], hr[:, 1]), hg)[0, 1],
    )
    first5 = grid < grid[0] + 300
    out.update(
        {
            "hr_g": round(float(hg.mean()), 1),
            "hr_aw": round(float(ha.mean()), 1),
            "bias": round(float(diff.mean()), 1),
            "mae": round(float(np.abs(diff).mean()), 1),
            "r": round(float(np.corrcoef(ha, hg)[0, 1]), 2),
            "pct_gt10": round(100 * float((np.abs(diff) > 10).mean()), 1),
            "mae_f5": round(float(np.abs(diff[first5]).mean()), 1),
            "mae_rest": round(float(np.abs(diff[~first5]).mean()), 1) if (~first5).any() else None,
            "lag": lag,
        }
    )
    return out


def summarise(rows: list) -> None:
    paired = [r for r in rows if r["paired"]]
    with_hr = [r for r in paired if r.get("mae") is not None]
    print(
        f"Garmin runs: {len(rows)}, paired: {len(paired)}, with HR statistics: "
        f"{len(with_hr)}, no Watch workout: {len(rows) - len(paired)}"
    )

    def med(sel, key):
        vals = [r[key] for r in sel if r.get(key) is not None]
        return round(statistics.median(vals), 3) if vals else None

    for era in ("U1", "U4"):
        for label, dense in (("dense", True), ("sparse", False)):
            sel = [
                r for r in paired if r["era"] == era and (r["aw_pts_per_min"] >= DENSE_MIN) == dense
            ]
            if not sel:
                continue
            hr_sel = [r for r in sel if r.get("mae") is not None]
            print(
                f"{era} {label}: paired {len(sel)}, with HR statistics {len(hr_sel)}; "
                f"Watch coverage {med(sel, 'cov_aw')}, Garmin coverage {med(sel, 'cov_g')}, "
                f"HR points/min {med(sel, 'aw_pts_per_min')}"
            )
            if hr_sel:
                print(
                    f"    mae {med(hr_sel, 'mae')}, bias {med(hr_sel, 'bias')}, "
                    f"mae>5 {sum(r['mae'] > 5 for r in hr_sel)}, "
                    f"share >10 bpm {med(hr_sel, 'pct_gt10')} %, "
                    f"first 5 min {med(hr_sel, 'mae_f5')}, after {med(hr_sel, 'mae_rest')}, "
                    f"lag {med(hr_sel, 'lag')} s"
                )
        sel = [r for r in paired if r["era"] == era]
        mx = [r["max_aw"] - r["max_g"] for r in sel if r.get("max_aw") is not None and r["max_g"]]
        el = [r["elev_aw"] / r["elev_g"] for r in sel if r["elev_g"]]
        print(
            f"{era} all paired n={len(sel)}: max HR Watch-Garmin {statistics.median(mx)}, "
            f"elevation Watch/Garmin {statistics.median(el):.2f}, "
            f"distance {statistics.median(r['km_pct'] for r in sel)} %"
        )
    print(
        f"distance |Watch-Garmin| > 3 %: {sum(abs(r['km_pct']) > 3 for r in paired)} "
        f"of {len(paired)}"
    )


def main(garmin_dir: str, srv_dir: str) -> None:
    rows = []
    missing = []
    for summary in sorted(glob.glob(os.path.join(garmin_dir, "*_summary.json"))):
        g = load_json(summary)
        if "running" not in g["activityType"]["typeKey"]:
            continue
        g0 = dt.datetime.fromisoformat(g["startTimeGMT"].replace(" ", "T") + "+00:00")
        local = g0.astimezone(TZ)
        wk = os.path.join(srv_dir, f"wk_{local:%Y%m%d}.json")
        hrf = os.path.join(srv_dir, f"hr_{local:%Y%m%d_%H%M}.json")
        if not (os.path.exists(wk) and os.path.exists(hrf)):
            missing.append(f"{local:%Y-%m-%d %H:%M}")
            continue
        base = {
            "date": f"{local:%Y-%m-%d %H:%M}",
            "era": "U4" if local.date() >= U4_FROM else "U1",
            "km_g": round(g["distance"] / 1000, 2),
            "paired": False,
        }
        g0s = g0.timestamp()
        best = best_watch_workout(
            load_json(wk)["data"]["workouts"], g0s, g0s + g["elapsedDuration"]
        )
        if best is None:
            rows.append(base)
            continue
        _, w, a0, a1 = best
        result = compare_run(g, summary.replace("_summary.json", ".tcx"), w, a0, a1, load_json(hrf))
        rows.append({**base, "paired": True, **result})

    # A fetch that stopped part-way leaves later days without files.
    # Analysing the rest would give date-biased figures that look whole.
    if missing:
        sys.exit(
            f"{len(missing)} Garmin runs have no fetched Watch data "
            f"(first {missing[0]}, last {missing[-1]}); re-run fetch_srv.py"
        )

    keys = list(dict.fromkeys(k for r in rows for k in r))
    with open(os.path.join(srv_dir, "pairs.csv"), "w") as fh:
        writer = csv.DictWriter(fh, keys)
        writer.writeheader()
        writer.writerows(rows)
    summarise(rows)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
