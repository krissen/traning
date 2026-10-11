"""Which watch is off when they disagree? Arbitrate by pace.

Fits average HR against average pace (s/km) on the runs where the two
watches agree (MAE <= 3 bpm, dense Apple Watch series), then, for every
run with MAE > 5 bpm, asks whose average lies nearer the pace-predicted
HR. Pace is Garmin's moving pace; Watch distance matches it to ~1 %
(pairs.csv). The fit uses the same watches it arbitrates, so this ranks
plausibility; it does not measure error.

Usage:
    python arbiter.py GARMIN_DIR SRV_DIR   # reads SRV_DIR/pairs.csv
"""

import csv
import datetime as dt
import glob
import json
import os
import sys

import numpy as np

TZ = dt.timezone(dt.timedelta(hours=2))
DENSE_MIN = 6


def main(garmin_dir: str, srv_dir: str) -> None:
    pace = {}
    for summary in glob.glob(os.path.join(garmin_dir, "*_summary.json")):
        with open(summary) as fh:
            g = json.load(fh)
        start = dt.datetime.fromisoformat(g["startTimeGMT"].replace(" ", "T") + "+00:00")
        if g.get("distance"):
            key = start.astimezone(TZ).strftime("%Y-%m-%d %H:%M")
            pace[key] = g["movingDuration"] / (g["distance"] / 1000)

    with open(os.path.join(srv_dir, "pairs.csv")) as fh:
        rows = [r for r in csv.DictReader(fh) if r.get("mae")]
    for r in rows:
        for k in ("mae", "hr_g", "hr_aw", "aw_pts_per_min"):
            r[k] = float(r[k])
        r["pace"] = pace[r["date"]]

    agree = [r for r in rows if r["mae"] <= 3 and r["aw_pts_per_min"] >= DENSE_MIN]
    x = np.array([r["pace"] for r in agree])
    y = np.array([(r["hr_g"] + r["hr_aw"]) / 2 for r in agree])
    slope, intercept = np.polyfit(x, y, 1)
    resid = y - (intercept + slope * x)
    print(
        f"fit on {len(agree)} agreeing runs: HR = {intercept:.1f} + {slope:.3f} * pace_s; "
        f"residual SD {resid.std():.1f} bpm"
    )

    tally = {"Garmin nearer": 0, "Watch nearer": 0}
    for r in sorted((r for r in rows if r["mae"] > 5), key=lambda r: r["date"]):
        pred = intercept + slope * r["pace"]
        garmin_nearer = abs(r["hr_g"] - pred) < abs(r["hr_aw"] - pred)
        who = "Garmin nearer" if garmin_nearer else "Watch nearer"
        tally[who] += 1
        density = "dense" if r["aw_pts_per_min"] >= DENSE_MIN else "sparse"
        mm, ss = divmod(int(r["pace"]), 60)
        print(
            f"{r['date']} {r['era']} {density:6} pace {mm}:{ss:02d} pred {pred:5.0f} "
            f"G {r['hr_g']:5.0f} AW {r['hr_aw']:5.0f} -> {who}"
        )
    print(tally)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
