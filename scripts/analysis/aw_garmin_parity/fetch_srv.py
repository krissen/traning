"""Fetch Apple Watch data for every Garmin run, straight from HAE's MCP server.

For each Garmin Connect running activity in GARMIN_DIR:
  * heart_rate via get_health_metrics (aggregate=false), the run +-10 min.
    This is the raw HealthKit series (~5 s in a workout), with source names.
  * the day's workouts via get_workouts with includeMetadata=false.

Why not get_workouts with metadata: in HAE 10.0.4 the per-workout
cumulative queries (energy, distance, steps) stall or are cancelled
(Lybron/health-auto-export#78), and a stalled call blocks the server for
every later call. Heart rate is a discrete series and comes back in
well under a second through get_health_metrics.

Usage:
    HAE_TOKEN=... python fetch_srv.py GARMIN_DIR OUT_DIR

GARMIN_DIR holds $TRANING_DATA/kristian/filer/gconnect files
(*_summary.json + .tcx). Already fetched files are skipped, and the run
stops at the first failed call.
"""

import datetime as dt
import glob
import json
import os
import sys
import time

import hae_mcp

# Every date in the analysed window (May-Oct 2026) is CEST.
TZ = dt.timezone(dt.timedelta(hours=2))


def fmt(t: dt.datetime) -> str:
    return t.astimezone(TZ).strftime("%Y-%m-%d %H:%M:%S +0200")


def main(garmin_dir: str, out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    runs = []
    for s in glob.glob(os.path.join(garmin_dir, "*_summary.json")):
        with open(s) as fh:
            d = json.load(fh)
        if "running" not in d["activityType"]["typeKey"]:
            continue
        st = dt.datetime.fromisoformat(d["startTimeGMT"].replace(" ", "T") + "+00:00")
        runs.append((st, d["elapsedDuration"]))
    runs.sort(reverse=True)
    days = sorted({st.astimezone(TZ).date() for st, _ in runs}, reverse=True)

    hae_mcp.init()

    def fetch(name: str, args: dict, out: str) -> None:
        if os.path.exists(out):
            return
        t = time.time()
        try:
            body = hae_mcp.call(name, args, timeout=60)
        except Exception as e:  # noqa: BLE001 -- stop rather than queue behind a stall
            sys.exit(f"FAIL {name} {out}: {type(e).__name__} after {time.time() - t:.1f}s")
        with open(out, "w") as fh:
            json.dump(body, fh, ensure_ascii=False)
        print(f"ok {out} {time.time() - t:.1f}s", flush=True)

    for st, dur in runs:
        a = st - dt.timedelta(minutes=10)
        b = st + dt.timedelta(seconds=dur + 600)
        fetch(
            "get_health_metrics",
            {
                "start": fmt(a),
                "end": fmt(b),
                "metrics": "heart_rate",
                "interval": "seconds",
                "aggregate": False,
            },
            os.path.join(out_dir, f"hr_{st.astimezone(TZ):%Y%m%d_%H%M}.json"),
        )
    for d in days:
        fetch(
            "get_workouts",
            {
                "start": f"{d} 00:00:00 +0200",
                "end": f"{d} 23:59:59 +0200",
                "includeMetadata": False,
                "includeRoutes": False,
            },
            os.path.join(out_dir, f"wk_{d:%Y%m%d}.json"),
        )
        time.sleep(1)
    print("DONE")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
