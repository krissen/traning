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
    """The Apple Watch workout overlapping [g0, g1] by more than half, most."""
    best = None
    for w in workouts:
        if "Watch" not in (w.get("source") or {}).get("name", ""):
            continue
        a0, a1 = hae_ts(w["start"]), hae_ts(w["end"])
        overlap = min(a1, g1) - max(a0, g0)
        if overlap > 0.5 * min(a1 - a0, g1 - g0) and (best is None or overlap > best[0]):
            best = (overlap, w, a0, a1)
    return best


def compare_run(g: dict, tcx: str, w: dict, a0: float, a1: float, hr_body: dict) -> dict | None:
    g0 = dt.datetime.fromisoformat(g["startTimeGMT"].replace(" ", "T") + "+00:00").timestamp()
    g1 = g0 + g["elapsedDuration"]
    metrics = hr_body["data"]["metrics"]
    samples = metrics[0]["data"] if metrics else []
    hr = np.array(
        sorted((hae_ts(x["date"]), x["Avg"]) for x in samples if "Watch" in x.get("source", ""))
    )
    garmin = tcx_hr(tcx)
    if len(hr) < 20 or len(garmin) < 20:
        return None
    t0 = max(a0, g0, hr[0, 0], garmin[0, 0])
    t1 = min(a1, g1, hr[-1, 0], garmin[-1, 0])
    grid = np.arange(math.ceil(t0), math.floor(t1))
    ha = np.interp(grid, hr[:, 0], hr[:, 1])
    hg = np.interp(grid, garmin[:, 0], garmin[:, 1])
    diff = ha - hg
    # Shift the Watch series against Garmin's and keep the best-correlated lag.
    lag = max(
        range(-30, 31),
        key=lambda s: np.corrcoef(np.interp(grid + s, hr[:, 0], hr[:, 1]), hg)[0, 1],
    )
    first5 = grid < grid[0] + 300
    in_workout = hr[(hr[:, 0] >= a0) & (hr[:, 0] <= a1)]
    minute = ((in_workout[:, 0] - a0) // 60).astype(int)
    minute_max = max(in_workout[minute == k, 1].mean() for k in np.unique(minute))
    km_aw = w["distance"]["qty"]
    return {
        "km_aw": round(km_aw, 2),
        "km_pct": round(100 * (km_aw * 1000 - g["distance"]) / g["distance"], 1),
        "start_off_s": round(a0 - g0),
        "hr_g": round(float(hg.mean()), 1),
        "hr_aw": round(float(ha.mean()), 1),
        "bias": round(float(diff.mean()), 1),
        "mae": round(float(np.abs(diff).mean()), 1),
        "r": round(float(np.corrcoef(ha, hg)[0, 1]), 2),
        "pct_gt10": round(100 * float((np.abs(diff) > 10).mean()), 1),
        "mae_f5": round(float(np.abs(diff[first5]).mean()), 1),
        "mae_rest": round(float(np.abs(diff[~first5]).mean()), 1) if (~first5).any() else None,
        "lag": lag,
        "max_g": g.get("maxHR"),
        "max_aw": float(in_workout[:, 1].max()),
        "max_aw_min": round(float(minute_max)),
        "aw_pts_per_min": round(len(in_workout) / ((a1 - a0) / 60), 1),
        "elev_g": round(g.get("elevationGain") or 0),
        "elev_aw": round((w.get("elevationUp") or {}).get("qty", 0)),
    }


def summarise(rows: list) -> None:
    paired = [r for r in rows if "mae" in r]
    print(
        f"Garmin runs: {len(rows)}, paired with HR: {len(paired)}, "
        f"no Watch workout: {sum(1 for r in rows if not r['paired'])}"
    )
    for era in ("U1", "U4"):
        for label, dense in (("dense", True), ("sparse", False)):
            sel = [
                r for r in paired if r["era"] == era and (r["aw_pts_per_min"] >= DENSE_MIN) == dense
            ]
            if not sel:
                continue

            def med(key, sel=sel):
                return round(statistics.median(r[key] for r in sel if r[key] is not None), 1)

            print(
                f"{era} {label} n={len(sel)}: mae {med('mae')}, bias {med('bias')}, "
                f"share mae>5 {sum(r['mae'] > 5 for r in sel) / len(sel):.2f}, "
                f"mae first 5 min {med('mae_f5')}, after {med('mae_rest')}, lag {med('lag')} s, "
                f"km {med('km_pct')} %, HR points/min {med('aw_pts_per_min')}"
            )
        sel = [r for r in paired if r["era"] == era]
        print(
            f"{era} all n={len(sel)}: max HR Watch-Garmin "
            f"{statistics.median(r['max_aw'] - r['max_g'] for r in sel)}, "
            f"minute-stored max minus raw max "
            f"{statistics.median(r['max_aw_min'] - r['max_aw'] for r in sel)}, "
            f"elevation Watch/Garmin "
            f"{statistics.median(r['elev_aw'] / r['elev_g'] for r in sel if r['elev_g']):.2f}"
        )
    print(
        f"distance |Watch-Garmin| > 3 %: {sum(abs(r['km_pct']) > 3 for r in paired)} of {len(paired)}"
    )


def main(garmin_dir: str, srv_dir: str) -> None:
    rows = []
    for summary in sorted(glob.glob(os.path.join(garmin_dir, "*_summary.json"))):
        g = load_json(summary)
        if "running" not in g["activityType"]["typeKey"]:
            continue
        g0 = dt.datetime.fromisoformat(g["startTimeGMT"].replace(" ", "T") + "+00:00")
        local = g0.astimezone(TZ)
        wk = os.path.join(srv_dir, f"wk_{local:%Y%m%d}.json")
        hrf = os.path.join(srv_dir, f"hr_{local:%Y%m%d_%H%M}.json")
        if not (os.path.exists(wk) and os.path.exists(hrf)):
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
        rows.append({**base, "paired": True, **(result or {})})

    keys = list(dict.fromkeys(k for r in rows for k in r))
    with open(os.path.join(srv_dir, "pairs.csv"), "w") as fh:
        writer = csv.DictWriter(fh, keys)
        writer.writeheader()
        writer.writerows(rows)
    summarise(rows)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
