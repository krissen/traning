# Apple Watch vs Garmin on dual-recorded runs (May–Oct 2026)

**Question.** tRäning is built Garmin-first. Do Apple Watch workout
metrics now match Garmin closely enough to drop the second watch on runs?
And where they differ, is that the watches, or how the pipeline stores
Apple Watch data?

**Answer in short.** Whenever the Apple Watch records heart rate at its
normal workout rate, which it has done on every run since mid-June 2026,
the two watches agree to a median 1.3 bpm (Ultra 1) and 1.9 bpm
(Ultra 4) second by second, and 1 run in 58 differs by more than 5 bpm.
Distance agrees to about 1 %. Before mid-June the Watch's heart-rate
series was sparse (1–3 points a minute) and agreement was poor. Nothing
in this data says Garmin measures heart rate better than the Watch. The
storage loses sub-minute shape and, since HAE 10.0.4, the `source`
label, but not agreement.

A first version of this analysis concluded the opposite (the Watch
under-reading on one run in six, Garmin vindicated by pace). That was an
artefact: Garmin pauses its recording, the Watch workout does not, and
interpolating across Garmin's pauses compared the Watch's resting heart
rate with a straight line between Garmin's last reading before and first
after each pause. See "What changed" below.

## Data and method

- **Garmin:** Forerunner 945, wrist HR, all 97 runs 2026-05-01..10-07 in
  `$TRANING_DATA/kristian/filer/gconnect/` (TCX, smart recording ~4 s).
- **Apple Watch:** Ultra (gen 1) until 2026-09-24, Ultra 4 from
  2026-09-25 (`devices.csv`). Fetched 2026-10-11 directly from HAE's
  MCP server, **not** from what the pipeline stored: `heart_rate` via
  `get_health_metrics` with `aggregate=false` (raw HealthKit samples with
  source names), workout totals via `get_workouts` without metadata.
- No chest strap on either watch, so there is no reference. Figures are
  agreement, not accuracy.
- **Pairing:** the Apple Watch workout (source name contains "Watch") that
  overlaps the Garmin run most, provided the overlap covers at least
  80 % of the Garmin run and half of the Watch workout, so a recording
  stopped early is not compared with the whole run. Garmin Connect also
  writes its runs into Apple Health; those copies are excluded by
  source. 89 of 97 runs paired; 8 had no qualifying Apple Watch workout.
- **Comparison grid:** both HR series on a 1 s grid over the overlap,
  keeping only seconds with a sample within 30 s in **both** series.
  This drops Garmin's pauses (no trackpoints at all) and the gaps in a
  sparse Watch series, instead of interpolating across them.
- A run is **dense** when the Watch series has at least 6 points a
  minute (normal workout sampling is ~12), otherwise **sparse**.

Scripts: `scripts/analysis/aw_garmin_parity/` (`fetch_srv.py`,
`compare.py`, `arbiter.py`). Install the analysis extra
(`uv sync --extra analysis`, which adds numpy), then
`HAE_TOKEN=… python fetch_srv.py <gconnect-dir> <out>`,
`python compare.py <gconnect-dir> <out>` and
`python arbiter.py <gconnect-dir> <out>`. `compare.py` refuses to run
when any Garmin run lacks fetched Watch data. Every figure below comes
from those outputs.

## Results

| | U1 dense (n=50) | U1 sparse (n=31) | U4 dense (n=8) |
|---|---|---|---|
| HR MAE, median | 1.3 bpm | 7.3 bpm | 1.9 bpm |
| HR bias (Watch − Garmin), median | −0.6 | 0.0 | −1.1 |
| Runs with MAE > 5 bpm | 1 (2 %) | 28 (90 %) | 0 |
| Seconds differing > 10 bpm, median share | 1.7 % | 24.5 % | 3.3 % |
| Watch HR points per minute | ~12 | 1–3 | ~12 |
| Watch coverage of the run, median | 100 % | 20 % | 100 % |

- **Sparse period.** Every run until 2026-05-31 and half of June (last
  2026-06-15) has an Apple Watch HR series of 1–3 points a minute
  instead of ~12, in HealthKit itself, covering a median 20 % of the
  run. Agreement in that period is poor throughout and has no direction
  (median bias 0). Something on the watch side changed in mid-June; the
  device log shows no watchOS update then, so a setting (for example low
  power mode during workouts) is the likelier cause. Not verified.
- **Dense runs.** The one run above 5 bpm (2026-09-15, 5.7 bpm) is a
  15-lap session.
- **First minutes.** On dense runs, MAE in the first five minutes is
  2.5 bpm (U1) and 4.2 bpm (U4) against about 1 bpm after. Optical
  warm-up, not a trend.
- **Lag.** The Watch series leads Garmin by a median 4–4.5 s (dense
  runs).
- **Max HR.** Watch − Garmin median −0.5 to −1 bpm.
- **Distance.** Watch − Garmin median +1.2 % over all pairs; 22 of 89
  differ by more than 3 %.
- **Elevation gain.** The Watch reports 13–23 % more (median ratio
  1.23 U1, 1.13 U4).

### Who is right when they disagree

`arbiter.py` fits average HR on pace over the runs where the watches
agree (53 runs, MAE ≤ 3 bpm, dense), HR = 209.2 − 0.224 × pace (s/km),
residual SD 4.5 bpm, and classifies each run with MAE > 5 bpm as
decisive (one watch within 2 SD of the prediction, the other outside)
or undecided. On dense runs there is a single such run, undecided. On
sparse runs (n=28) it is Garmin 1, Watch 2, undecided 25. There is no
disagreement left on dense runs for the arbitration to settle.

Caveat: the fit uses the same two watches it arbitrates, and pace is
Garmin's. It ranks plausibility; it does not measure error.

## What changed from the first version

The first version interpolated both series over every second of the
overlap. Ten dense runs then showed MAE > 5 bpm, almost all with the
Watch lower, and pace seemed to side with Garmin. In all ten, the gaps
were in Garmin's series and were pauses: 8 to 133 minutes without any
trackpoint (interval sessions, a 41-lap session, a run with long
stops), and no minute anywhere with trackpoints lacking heart rate. The
Watch workout kept recording through the pauses. Interpolation drew a
line across each Garmin pause at running heart rate and compared it with
the Watch's recovery heart rate. With the pause seconds excluded, the
ten runs fall to MAE 1.3–5.7 bpm. Codex flagged the interpolation in
review of PR #100.

## Watches or storage?

**Neither watch disagrees meaningfully when both are recording.** The
earlier apparent disagreement was the comparison, not the sensors.

**The storage loses shape and labels, not agreement.**

- The workouts automation now stores heart rate per minute
  (`workoutsMetadaInterval: minutes`): 42 points for a 40-minute run on
  2026-10-07, against 483 in HealthKit. Stored workouts up to
  2026-09-05 still carry ~12 points a minute, so the switch happened
  between those dates. Each stored minute entry keeps Min, Avg and Max,
  so the peak survives in the file; what is lost is everything below a
  minute (warm-up, intervals, lag). The R side does not read workout
  heart-rate series today. The metrics
  automation also aggregates heart rate per minute.
- Since HAE 10.0.4 (around 2026-09-26 here) merged series arrive with an
  empty `source` (Lybron/health-auto-export#78), so the pipeline can no
  longer tell Apple Watch from iPhone or Connect samples on those metrics.
- For runs this matters little while run analysis reads Garmin's TCX.
  It matters for Apple Watch-only sessions (walks, cycling, strength),
  which are now stored at minute resolution only.

Switching the workouts automation to seconds is not advisable in 10.0.4:
the per-workout cumulative queries then stall and block the export
(#78). Heart rate at full resolution is available through
`get_health_metrics` with `aggregate=false` when needed.

## What the data supports

- **Heart rate does not justify wearing the Garmin on runs.** Since the
  Watch's series became dense in mid-June, 58 dual-recorded runs agree to
  1–2 bpm, and the two watches are interchangeable for heart rate within
  what wrist sensors can show without a reference.
- **Distance agrees to about 1 %.**
- **What the Garmin still provides is not tested here:** running
  dynamics (it had none without a strap), Garmin's own training metrics
  (training effect, load, VO2max estimate) that tRäning reads, and
  elevation, where the two differ by 13–23 % and neither has been
  checked against a map. A switch to Watch-first is a pipeline decision
  on those grounds, not on heart rate.
- The Ultra 4 sample is eight runs; it matches the Ultra 1 dense runs.

## Open

- What changed on the Watch around 2026-06-15 (sparse → dense HR).
- The exact date the workouts automation switched to minute heart rate.
- Elevation: which device is closer to the map. Needs a DEM comparison.
- Cadence and route: a three-run pilot (not scripted, not used above)
  showed cadence within 1 spm and GPS tracks a median 6–8 m apart. A
  scripted comparison needs routes, which `get_workouts` delivers only
  with metadata, the path that stalls in HAE 10.0.4.
