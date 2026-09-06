# Incident report: daily-summary metrics missing from HAE automation 10 Aug – 5 Sep 2026

**Status:** Recovered. Manual export 5 Sep 2026 21:10 restored all affected
metrics; automation has delivered them normally again since 6 Sep 2026.
Root cause not confirmed; mechanism ruled out against the resting-hr
incident below. Two metrics (running_power, stair_speed_up) still absent
from automatic pushes as of 6 Sep and need separate watching.
**Discovered:** 2026-09-06
**Severity:** Low to moderate. Degraded data quality for a subset of
daily-summary metrics over 26 days; no incorrect values, and the gap was
invisible until an unrelated feature (alcohol tracking) exposed it.

## Summary

Health Auto Export's automatic pushes silently stopped including nine to
ten daily-summary metrics after the push at 2026-08-09 20:20. The gap
lasted 26 days, through 2026-09-04, and went unnoticed the whole time
because nothing consuming those metrics alerted on their absence. It was
found on 2026-09-06 while investigating why the alcohol-tracking feature's
energy share showed no denominator: `dietary_energy` and `active_energy`
turned out to be two of the missing metrics. A manual export on 2026-09-05
at 21:10 restored all of them at once, and the automation has delivered
them normally again since 2026-09-06.

## Affected metrics

Watch-generated daily-summary metrics, missing from every automatic push
2026-08-10 through 2026-09-04:

- `active_energy`
- `basal_energy_burned`
- `apple_exercise_time`
- `apple_stand_hour`
- `apple_stand_time`
- `walking_speed`
- `time_in_daylight`
- `environmental_audio_exposure`
- `stair_speed_up`
- `running_power` (this one had already stopped arriving on 2026-08-06,
  four days earlier than the rest)

Also affected, outside the metric list originally flagged but sharing the
same window: `stair_speed_down`, `walking_asymmetry_percentage`,
`walking_double_support_percentage`. `cardio_recovery` and `vo2_max`
thinned out during the same period but did not disappear completely
(they still appeared in a minority of pushes). A different, milder
pattern, likely just low sampling frequency rather than the same fault.

## Not affected

`resting_heart_rate`, `heart_rate_variability`, `step_count`,
`blood_oxygen_saturation`, `heart_rate`, `physical_effort`,
`walking_running_distance` and `sleep_analysis` (the legacy metric under
`kristian/health_export/metrics/sleep_analysis_*.json`) all continued to
arrive without interruption through the entire 26-day window.

## Timeline (local time)

| Time | Event |
|---|---|
| 2026-08-09 20:20 | Last automatic push carrying all of the metrics above |
| 2026-08-09 20:23 | Next automatic push (3 minutes later) already missing all of them |
| 2026-08-10 – 09-04 | Automation continues normally (2–7 pushes/day) but the nine to ten metrics never reappear |
| 2026-09-05 21:10 | Manual export (36 metrics in one push, far above the automation's usual 5–19) delivers every missing metric at once |
| 2026-09-06 08:47 and 11:12 | Automatic pushes resume carrying active_energy, apple_exercise_time, apple_stand_hour/time, basal_energy_burned, environmental_audio_exposure, time_in_daylight and walking_speed again |

`running_power` and `stair_speed_up` did not reappear in either of the two
automatic pushes on 2026-09-06; only the manual export on 2026-09-05
delivered them.

## Why this is not the resting-hr mechanism

The resting-hr incident
(`docs/dev/incidents/2026-08-07-resting-hr-export-gap.md`) traced its gap
to the automation's incremental export window anchoring on a sample's
timestamp rather than when it was written to HealthKit, so a back-dated
sample permanently missed the "Since Last Sync" window. Switching the
automation to a fixed "Today" window fixed it on 2026-08-11. Three
observations rule out the same mechanism here:

1. The "Today" window fix for resting heart rate held throughout this new
   gap. `resting_heart_rate` arrived in nearly every automatic push from
   2026-08-11 onward, unaffected by whatever caused the other metrics to
   disappear.
2. The new dropout started on 2026-08-09/10, after the "Today" window was
   already in effect (set 2026-08-10/11 and left in place). The window
   choice is not the variable that changed here.
3. `sleep_analysis`, the exact metric the resting-hr incident's own
   watchpoint (12 Aug) worried about because it is written retroactively
   like resting heart rate, kept arriving every single day through the
   whole 26-day gap. If the mechanism were "watchOS writes this metric
   retroactively/aggregated and it falls outside the export window," sleep
   should have been affected too. It was not.

What the affected metrics have in common instead is that they are all
watchOS-generated **daily rollups** (activity rings: active_energy,
basal_energy_burned, apple_exercise_time, apple_stand_hour/time; plus
time_in_daylight, environmental_audio_exposure, walking_speed,
stair_speed_up, running_power), as opposed to the metrics that kept
flowing throughout, which are either continuous point samples (heart
rate, heart rate variability, step count, blood oxygen saturation,
physical effort, walking/running distance) or already covered by the
"Today" window fix (resting heart rate, sleep_analysis).

## Hypothesis

That both the manual export on 2026-08-07 22:33 (35 metrics, from the
resting-hr incident) and the one on 2026-09-05 21:10 (36 metrics)
immediately delivered every missing metric, while identically configured
automatic pushes using the same "Today" window did not, points toward the
fault sitting in **the automation's own metric-type list**, separate
from the app's global export selection which manual export reads,
rather than in the window logic. This is closer to the precedent already
cited in the resting-hr report as HAE issue #51 ("automation silently
drops a segment behind a hidden flag") than to issues #56/#61
(window/back-dating), which explain the earlier resting-hr gap but not
this one.

## Discovery

Found on 2026-09-06, 27 days after the gap started, while investigating
why the alcohol-tracking feature's energy-share calculation had no
denominator: `active_energy` and `dietary_energy` were both silently
absent for the relevant dates. Nothing in the pipeline alerted on the
missing metrics before that; the gap was only surfaced as a side effect of
building an unrelated feature.

## Remediation

Backfill via the HAE MCP server from kedar, at minute-level aggregation,
covering the affected metrics and date range. In progress as of
2026-09-06.

## Follow-ups

1. **Per-metric staleness alarm in `traning doctor`.** Already tracked in
   `docs/roadmap.md`; now raised to the top of the HAE pipeline section
   because this is the second metric-scoped silent dropout in a month
   (resting heart rate in August, this one in September) and both went
   undetected until something downstream broke.
2. **Watch `running_power` and `stair_speed_up` specifically.** Both were
   already missing before the main 2026-08-10 group started
   (`running_power` since 2026-08-06) and neither had reappeared in
   automatic pushes as of 2026-09-06, unlike the rest of the group.
3. **Upstream issue to `Lybron/health-auto-export`.** Not yet filed. This
   report's hypothesis (a hidden per-automation metric-type list losing
   entries, distinct from the window bug behind issue #61) should be
   written up and posted once confirmed.
4. **Open question for the product owner:** did anything change in the
   automation's settings on the evening of 2026-09-05? The recovery lines
   up exactly with the manual export at 21:10 that evening, which raises
   the possibility that whatever fixed it was a manual settings change
   rather than an upstream app fix.
