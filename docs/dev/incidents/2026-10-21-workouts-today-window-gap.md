# Incident report: HAE workouts missing after each day's last push, October 2026

**Status:** Recovered. 23 missing workouts backfilled and imported on
2026-10-21. The workouts automation's period changed from "Today" to
"Default" the same day, as a test; whether that closes the gap is listed
under Follow-ups.
**Discovered:** 2026-10-21
**Severity:** Low. 25 of 84 Apple Watch workouts from 1–20 Oct never
reached kailash, including every workout on 13 and 18 Oct. No incorrect
values. Runs were still covered by the Garmin pipeline, so running
summaries were unaffected; walks, rides and Apple Watch heart-rate detail
for the affected sessions were missing.

## Summary

The HAE automation "Exportera workouts" used the period "Today". Each push
only carries workouts that started on the day of the push, so any workout
recorded after the day's last successful push was never sent: the next
push, on a later day, no longer covers that day. Pushes were sparse in
October (zero to two per day, none on 8, 13 and 18 Oct), so the gap grew
to 25 workouts in 20 days.

The product owner reports that the automation has also been unreliable
since iOS 27, and that 21 Oct was the first time since about 17 Oct that
the automation ran successfully. The phone was upgraded to iOS 27.2 on
21 Oct, which is supposed to fix the iOS 27 problems. The receiver did
log one push in between (19 Oct 13:03, 4 workouts), so the automation was
not completely dead in that period.

The switch to second-resolution workout metadata on 2026-10-11 was not
the cause. Workouts were already missing before it (3, 6, 8 and 9 Oct),
and no HAE#78-style stall occurred: fetching each workout over MCP with
second metadata took 0.3–3 s.

## Timeline (local time)

| Time | Event |
|---|---|
| 2026-10-01 – 10-20 | Workouts automation on period "Today"; zero to two pushes per day |
| 2026-10-08, 10-13, 10-18 | No workouts push at all; every workout on those days missing |
| 2026-10-11 ~17:50 | Workout metadata switched from minutes to seconds (unrelated to the gap) |
| 2026-10-21 | Product owner upgrades to iOS 27.2 |
| 2026-10-21 08:23 | Push delivers the six workouts of 20 Oct |
| 2026-10-21 08:31 | Backfill of 23 workouts posted to the receiver, committed in the data repo (`0e181be2a`) |
| 2026-10-21 08:42 | Debounced import OK: "26 pass (03 okt–20 okt), 56,9 km" |
| 2026-10-21 | Workouts automation period changed from "Today" to "Default" as a test |

## Missing workouts per day

Phone (HAE MCP `get_workouts`, one day per call) against files in
`kristian/health_export/workouts/` on kailash, 1–20 Oct:

| Day | On phone | Missing | Last stored start | Note |
|---|---|---|---|---|
| 03 Oct | 4 | 1 | 12:59 | Last push 14:34; ride 16:48 missed |
| 06 Oct | 6 | 1 | 18:34 | Last push 18:48; ride 20:07 missed |
| 08 Oct | 1 | 1 | none | No push |
| 09 Oct | 3 | 2 | 07:46 | Only push 11:08 |
| 11 Oct | 4 | 1 | 16:05 | Last push 17:44; walk 18:42 missed |
| 12 Oct | 5 | 1 | 17:02 | Garmin Connect duplicate of a stored run |
| 13 Oct | 7 | 7 | none | No push |
| 16 Oct | 7 | 5 | 08:47 | Only push 12:17 |
| 18 Oct | 4 | 4 | none | No push |
| 19 Oct | 6 | 2 | 12:21 | Only push 13:03 |

Every missing workout started after the day's last push, or fell on a
day without a push.

## Remediation

1. Each missing workout fetched individually over the HAE MCP server
   from kedar: window start to start + 1 s, `includeMetadata`,
   `includeRoutes`, `metadataAggregation: seconds`. Same JSON shape as a
   live push.
2. Two workouts with source "Connect" (12 Oct 16:29:35, 13 Oct 11:32:02)
   left out. They are Garmin Connect copies of runs the Garmin pipeline
   already has, and live pushes almost never carry Connect workouts
   (3 of 15 715 stored files).
3. The remaining 23 posted to the receiver's `/v1/workouts` on kailash,
   which saved, committed and imported them through the normal path.
   `/v1/status` afterwards: `pending_workouts: 0`.

## Follow-ups

1. **Check whether "Default" catches late-day workouts.** Over the next
   days, compare phone and kailash per day (MCP `get_workouts` with
   `includeMetadata: false`, one day per call). If workouts after the
   last push still go missing, add a second workouts automation with
   period "Yesterday" once a day, the same pattern as the metrics
   Backsync.
2. **Watch automation reliability on iOS 27.2.** Count workouts pushes
   per day in the receiver journal
   (`grep "Received .* workouts"`). Days without a push in spite of
   recorded workouts mean the iOS problem remains.
3. **Staleness check for workouts.** A per-day phone-versus-stored
   comparison in `traning doctor` would have caught this within a day
   instead of three weeks. Requires the phone's server to be reachable,
   so at most a manual or opportunistic check.
