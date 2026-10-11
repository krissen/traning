# Apple Watch vs Garmin on dual-recorded runs (May–Oct 2026)

**Question.** tRäning is built Garmin-first. Do Apple Watch workout
metrics now match Garmin closely enough to drop the second watch on runs?
And where they differ, is that the watches, or how the pipeline stores
Apple Watch data?

**Answer in short.** Distance agrees closely (median difference 1 %).
Heart rate agrees within 1–2 bpm on most runs, but on about one run in
six the two series part by more than 5 bpm, and in 9 of those 10 the
Apple Watch reads lower. Which watch is right then cannot usually be
settled: pace arbitration decides only 3 of the 10, all for Garmin. The
disagreement is in the raw HealthKit series, so it comes from the watch,
not the storage. The storage loses sub-minute shape and, since HAE
10.0.4, the `source` label. The Ultra 4 looks no worse than the Ultra 1
at its best, but eight runs cannot carry a conclusion.

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
  overlaps the Garmin run most, provided the overlap covers at least
  80 % of the Garmin run and half of the Watch workout, so a recording
  stopped early is not compared with the whole run. Garmin Connect also
  writes its runs into Apple Health; those copies are excluded by
  source. 89 of 97 runs paired; 8 had no qualifying Apple Watch workout.
- Both HR series are interpolated to a 1 s grid over the overlap.
- A run is **dense** when the Watch series has at least 6 points a
  minute (normal workout sampling is ~12), otherwise **sparse**.

Scripts: `scripts/analysis/aw_garmin_parity/` (`fetch_srv.py`,
`compare.py`, `arbiter.py`). Re-run with
`HAE_TOKEN=… python fetch_srv.py <gconnect-dir> <out>`, then
`python compare.py <gconnect-dir> <out>` and
`python arbiter.py <gconnect-dir> <out>` (repo venv; numpy). Every
figure below comes from those two outputs.

## Results

| | U1 dense (n=50) | U1 sparse (n=31) | U4 dense (n=8) |
|---|---|---|---|
| HR MAE, median | 1.6 bpm | 10.5 bpm | 1.9 bpm |
| HR bias (Watch − Garmin), median | −0.9 | −7.2 | −1.2 |
| Runs with MAE > 5 bpm | 9 (18 %) | 29 (94 %) | 1 (12 %) |
| Watch HR points per minute | ~12 | 1–3 | ~12 |

- **Sparse period.** Every run until 2026-05-31 and half of June (last
  2026-06-15) has an Apple Watch HR series of 1–3 points a minute
  instead of ~12, in HealthKit itself. Agreement in that period is poor
  throughout. Something on the watch side changed in mid-June; the
  device log shows no watchOS update then, so a setting (for example low
  power mode during workouts) is the likelier cause. Not verified.
- **Dense runs overall.** 10 of 58 (17 %, about one in six) have
  MAE > 5 bpm; in 9 of them the Watch reads lower.
- **First minutes.** On dense runs, MAE in the first five minutes is
  3–4 bpm against 1.0–1.3 bpm after (U1, U4). Optical warm-up, not a
  trend.
- **Lag.** The Watch series leads Garmin by a median 5–6 s (dense runs).
- **Max HR.** Watch − Garmin median −0.5 to −1 bpm.
- **Distance.** Watch − Garmin median +1.2 %; 22 of 89 runs differ by
  more than 3 %.
- **Elevation gain.** The Watch reports 13–23 % more (median ratio
  1.23 U1, 1.13 U4).

### Who is right when they disagree

A linear fit of average HR on pace over the 40 runs where the watches
agree (MAE ≤ 3 bpm, dense series) gives HR = 209.6 − 0.225 × pace (s/km),
residual SD 4.7 bpm. Each run with MAE > 5 bpm is then classified:
**decisive** when one watch lies within 2 SD of the pace prediction and
the other outside it, otherwise **undecided**.

| | n | Decisive: Garmin | Decisive: Watch | Undecided |
|---|---|---|---|---|
| Dense | 10 | 3 | 0 | 7 |
| Sparse | 29 | 15 | 1 | 13 |

- On dense runs the evidence that Garmin is the right one rests on three
  runs. In most undecided cases both watches fall below the prediction,
  and "nearer" would only say which reading is higher. Four dense runs
  (06-13, 06-30, 07-11, 08-15) are more than 2 SD below the prediction
  on both watches, so the pace model does not describe them at all;
  2026-08-15 (4:18/km, Watch 112 bpm, Garmin 138) is one of them. The
  Watch figure there is implausible on its own, but the model does not
  show it.
- The sparse runs mostly confirm what the density already says.

Caveat: the fit uses the same two watches it arbitrates, and pace is
Garmin's. It ranks plausibility; it does not measure error.

## Watches or storage?

**The disagreement is the watch.** It is present in the raw HealthKit
series fetched from the phone, before anything in this pipeline touches
it.

**The storage loses shape and labels, not agreement.**

- The workouts automation now stores heart rate per minute
  (`workoutsMetadaInterval: minutes`): 42 points for a 40-minute run on
  2026-10-07, against 483 in HealthKit. Stored workouts up to
  2026-09-05 still carry ~12 points a minute, so the switch happened
  between those dates. Each minute entry keeps Min, Avg and Max, and the
  pipeline reads Max, so peak heart rate survives; what is lost is
  everything below a minute (warm-up, intervals, lag). The metrics
  automation also aggregates heart rate per minute.
- Since HAE 10.0.4 (around 2026-09-26 here) merged series arrive with an
  empty `source` (Lybron/health-auto-export#78), so the pipeline can no
  longer tell Apple Watch from iPhone or Connect samples on those metrics.
- For runs this matters little, because run analysis is Garmin-first and
  reads the TCX. It matters for Apple Watch-only sessions (walks,
  cycling, strength), which are now stored at minute resolution only.

Switching the workouts automation to seconds is not advisable in 10.0.4:
the per-workout cumulative queries then stall and block the export
(#78). Heart rate at full resolution is available through
`get_health_metrics` with `aggregate=false` when needed.

## What the data supports

- **Garmin-first remains the safer default for heart rate on runs, on
  thin evidence.** The Watch parts from Garmin on about one dense run in
  six and nearly always low, but pace settles only three of those cases.
  The data says the two watches disagree in a consistent direction more
  than it says which one is right.
- **Dropping the Garmin on runs is not supported yet.** The Ultra 4 has
  1 of 8 runs above 5 bpm against 9 of 50 for the Ultra 1 on dense
  series; eight runs cannot separate those rates. Re-run this analysis
  after about 30 Ultra 4 runs for a first comparison.
- For distance the Watch alone would do.

## Open

- What changed on the Watch around 2026-06-15 (sparse → dense HR).
- The exact date the workouts automation switched to minute heart rate.
- Elevation: which device is closer to the map. Needs a DEM comparison.
- Cadence and route: a three-run pilot (not scripted, not used above)
  showed cadence within 1 spm and GPS tracks a median 6–8 m apart. A
  scripted comparison needs routes, which `get_workouts` delivers only
  with metadata, the path that stalls in HAE 10.0.4.
