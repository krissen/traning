# Apple Watch vs Garmin on dual-recorded runs (May–Oct 2026)

**Question.** tRäning is built Garmin-first. Do Apple Watch workout
metrics now match Garmin closely enough to drop the second watch on runs?
And where they differ, is that the watches, or how the pipeline stores
Apple Watch data?

**Answer in short.** Distance, cadence and GPS agree closely. Heart rate
agrees within 1–2 bpm on most runs, but the Apple Watch under-reads on
roughly one run in eight, and when the two disagree, Garmin is the one
consistent with pace in 34 of 40 cases. The disagreement is in the raw
HealthKit series, so it is the watch, not the storage. The storage loses
something different: resolution (minute heart rate) and, since HAE
10.0.4, the `source` label. The Ultra 4 looks better than the Ultra 1,
but eight runs cannot carry that conclusion yet.

## Data and method

- **Garmin:** Forerunner 945, wrist HR, all 97 runs 2026-05-01..10-07 in
  `$TRANING_DATA/kristian/filer/gconnect/` (TCX, smart recording ~4 s).
- **Apple Watch:** Ultra (gen 1) until 2026-09-24, Ultra 4 from
  2026-09-25 (`devices.csv`). Fetched 2026-10-11 directly from HAE's
  MCP server, **not** from what the pipeline stored: `heart_rate` via
  `get_health_metrics` with `aggregate=false` (raw HealthKit samples with
  source names), workout totals via `get_workouts` without metadata.
- No chest strap on either watch, so there is no reference. Figures are
  agreement, not accuracy. "Who is right" is arbitrated indirectly by
  pace, below.
- Pairing: the Apple Watch workout (source name contains "Watch") that
  overlaps the Garmin run most. Garmin Connect also writes its runs into
  Apple Health; those copies are excluded by source. 90 of 97 runs
  paired; 7 had no Apple Watch workout.
- Both HR series are interpolated to a 1 s grid over the overlap.

Scripts: `scripts/analysis/aw_garmin_parity/` (`fetch_srv.py`,
`compare.py`, `arbiter.py`). Re-run with
`HAE_TOKEN=… python fetch_srv.py <gconnect-dir> <out>`, then
`python compare.py <gconnect-dir> <out>` and `python arbiter.py …`
(repo venv; numpy).

## Results

| | U1 dense (n=50) | U1 sparse (n=32) | U4 (n=8) |
|---|---|---|---|
| HR MAE, median | 1.6 bpm | 10.4 bpm | 1.9 bpm |
| HR bias (Watch − Garmin), median | −0.9 | −6.8 | −1.2 |
| Runs with MAE > 5 bpm | 18 % | 94 % | 12 % |
| Watch HR points per minute | ~12 | 1–3 | ~12 |

- **Sparse period.** Every run until 2026-05-31 and half of June (last
  2026-06-15) has an Apple Watch HR series of 1–3 points a minute
  instead of ~12, in HealthKit itself. Agreement in that period is poor
  throughout. Something on the watch side changed in mid-June; the
  device log shows no watchOS update then, so a setting (for example low
  power mode during workouts) is the likelier cause. Not verified.
- **First minutes.** On dense runs, MAE in the first five minutes is 3–4 bpm against
  1.0–1.3 bpm after (U1, U4). Optical warm-up, not a trend.
- **Lag.** The Watch series leads Garmin by a median 5–6 s (dense runs).
- **Max HR.** Watch − Garmin median −0.5 to −1 bpm.
- **Distance.** Watch − Garmin median +1.2 %; 23 of 90 runs differ by
  more than 3 %.
- **Elevation gain.** The Watch reports 13–23 % more (median ratio
  1.23 U1, 1.13 U4).
- **Cadence and GPS** (three U4 runs with routes, pilot): cadence within
  1 spm; median distance between the two GPS tracks 6–8 m.

### Who is right when they disagree

A linear fit of average HR on pace over the 40 runs where the watches
agree (MAE ≤ 3 bpm, dense series) gives HR = 209.6 − 0.225 × pace (s/km),
residual SD 4.7 bpm. For each of the 40 runs with MAE > 5 bpm, the watch
whose average lies nearer the pace prediction is counted:

- **Garmin nearer: 34. Apple Watch nearer: 6.**
- The Apple Watch disagreements are under-reads: on 2026-08-15, a tempo
  run at 4:18/km, the Watch averaged 112 bpm against Garmin's 138.

Caveat: the fit uses the same two watches it arbitrates, and pace is
Garmin's. It ranks plausibility; it does not measure error.

## Watches or storage?

**The disagreement is the watch.** It is present in the raw HealthKit
series fetched from the phone, before anything in this pipeline touches
it.

**The storage loses resolution and labels, not agreement.**

- The workouts automation stores heart rate per minute
  (`workoutsMetadaInterval: minutes`): 42 points for a 40-minute run
  against 483 in HealthKit. That cuts max HR by a median 2 bpm and
  removes everything below a minute (warm-up, intervals, lag). The
  metrics automation also aggregates heart rate per minute.
- Since HAE 10.0.4 (around 2026-09-26 here) merged series arrive with an
  empty `source` (Lybron/health-auto-export#78), so the pipeline can no
  longer tell Apple Watch from iPhone or Connect samples on those metrics.
- For runs this matters little, because run analysis is Garmin-first and
  reads the TCX. It matters for Apple Watch-only sessions (walks,
  cycling, strength), which are stored at minute resolution only.

Switching the workouts automation to seconds is not advisable in 10.0.4:
the per-workout cumulative queries then stall and block the export
(#78). Heart rate at full resolution is available through
`get_health_metrics` with `aggregate=false` when needed.

## What the data supports

- **Garmin-first stays justified for heart rate on runs.** The Watch
  under-reads on about one run in eight even with a dense series, and
  disagreements resolve in Garmin's favour.
- **Dropping the Garmin on runs is not supported yet.** The Ultra 4
  looks as good as the best Ultra 1 months (MAE 1.9, 1 of 8 runs
  above 5 bpm), but eight runs is not a sample. Re-run this analysis after
  about 30 Ultra 4 runs; with the U1 dense rate of 18 %, that is enough to
  see whether the Ultra 4's rate is materially lower.
- For distance, cadence and route the Watch alone would do.

## Open

- What changed on the Watch around 2026-06-15 (sparse → dense HR).
- Elevation: which device is closer to the map. Needs a DEM comparison.
