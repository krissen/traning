# Phase 5d — Taper plan & race readiness design

## Goal

Answer the user-level question "I have a race on X — am I on track, and
what should the next weeks look like?" without resorting to spreadsheet
work. Two computational primitives back the answer:

- `compute_taper_plan(summaries, race_date, distance_km, taper_weeks)` —
  weekly km targets from "today" through the race.
- `compute_race_readiness(summaries, health_daily, target_date)` —
  a composite 0–100 readiness score for the target date plus a Swedish
  prose summary.

Both reuse the existing PMC / TRIMP machinery and the readiness
components already exposed by `R/readiness.R`. No new training-load
math is introduced.

## Taper-plan algorithm

### Inputs

| Name | Type | Meaning |
|---|---|---|
| `summaries` | tibble | Augmented summaries from `my_dbs_load()`. |
| `race_date` | Date | The race day. Must be in the future. |
| `distance_km` | numeric | Race distance in km. Used to label the race-week schedule but does not change the volume curve. |
| `taper_weeks` | integer | Number of "true" taper weeks before the race. Default 2 (matches the most-cited evidence for half-marathon to marathon distances). |

### Baseline weekly volume

Take the **last four complete ISO weeks** of running-only sessions
ending before `Sys.Date()`. Compute `weekly_km` per week, then
`baseline_km = median(weekly_km)`. Median (not mean) so a single
overshoot week doesn't pull the taper schedule above what the athlete
is actually maintaining.

Reasons for "running only" for the volume target:
- Mixed-sport km is not directly comparable.
- The taper plan is consumed alongside CTL views that are sport-aware
  anyway. The user can request `sport=` later if needed.

### Taper schedule

For each week in the lookback window, the schedule produces a row with
a target volume relative to the baseline:

- **Build** weeks (where `weeks_until_race > taper_weeks`): full
  baseline.
- **Taper** weeks (where `1 <= weeks_until_race <= taper_weeks`) and
  the **race** week (`weeks_until_race == 0`): linear interpolation
  between the **0.45 race-week floor** and **1.0** at
  `weeks_until_race == taper_weeks + 1`, i.e.
  `relative = 0.45 + 0.55 × weeks_until_race / (taper_weeks + 1)`.

For the default `taper_weeks = 2` this yields:

| weeks_until_race | phase | relative_to_baseline |
|---|---|---|
| 0 (race) | race | 0.45 |
| 1 (taper -1) | taper | ≈ 0.63 |
| 2 (taper -2) | taper | ≈ 0.82 |
| ≥ 3 | build | 1.00 |

Race week is the ISO week (Mon–Sun) containing `race_date`. The 0.45
floor sits inside the 40–55 % race-week envelope from Bosquet 2007
and Mujika 2010; the linear ramp keeps each taper step proportional
so a longer `taper_weeks` lowers volume more gradually rather than
crashing it.

### Empty-baseline edge case

When the four-week lookback contains no running at all,
`compute_taper_plan()` returns an empty tibble with the attribute
`insufficient_baseline = TRUE`. The renderer surfaces a clear
"Otillräcklig baseline"-message rather than a chart of zero-km
targets that nominally read "100 % av baseline".

### Outputs

A tibble, one row per ISO week:

| Column | Type | Meaning |
|---|---|---|
| `week_start` | Date | Monday |
| `week_end` | Date | Sunday |
| `weeks_until_race` | integer | 0 = race week, 1 = the week before, etc. |
| `phase` | character | "build" / "taper" / "race" |
| `baseline_km` | numeric | The median of the 4 preceding weeks (constant across rows for traceability). |
| `target_km` | numeric | What the schedule says to run this week. |
| `relative_to_baseline` | numeric | `target_km / baseline_km`. |

Plus a sibling helper that renders the tibble as Swedish prose for
notifications / Shiny.

## Race readiness algorithm

### Components

Four components, each producing a 0–100 sub-score:

1. **CTL trend (fitness)** — compare CTL today vs CTL 28 days ago.
   - Rising or flat (`delta >= -2`): 100.
   - Falling (`delta < -10`): 0.
   - Linear between.

2. **TSB projection (form)** — project today's TSB toward an
   asymptote of `0.3 × CTL` (a typical well-tapered form/fitness
   ratio), with the time-to-reach scaled by `taper_weeks`. Past
   race-day passes today's TSB through unchanged. The simplified
   blend avoids tightly coupling the readiness score to the taper
   plan's per-week TRIMP estimate — that estimate carries its own
   assumptions about session pacing and would compound errors.
   Score the projected TSB:
   - `5 <= TSB <= 15`: 100 (the well-tapered band).
   - `0 <= TSB < 5` or `15 < TSB <= 25`: 50.
   - Otherwise: 0.

3. **HRV stability (autonomic)** — compare 7-day mean HRV against the
   28-day mean.
   - Within ±0.5 ms or rising: 100.
   - 0.5–3 ms below 28d: 50.
   - More than 3 ms below: 0.

4. **Resting HR stability** — same shape as HRV, opposite direction:
   - Within ±1 bpm or falling vs 28d: 100.
   - 1–3 bpm above: 50.
   - More than 3 bpm above: 0.

Components without enough data (e.g. health_daily missing) are dropped
from the average rather than scored as 0; the prose call-out makes
that explicit so the user knows what wasn't measured.

### Composite score

`score = mean(available components)`, then status buckets:

- `score >= 70` → "Klar"
- `score >= 40` → "Tveksam"
- `score < 40`  → "Inte klar"

### Outputs

A list:

| Field | Meaning |
|---|---|
| `target_date` | The race date echoed back. |
| `days_until` | `target_date - Sys.Date()`. |
| `components` | Named list — each component carries `score`, `raw_today`, `raw_baseline`, `delta`. |
| `score` | The composite 0–100. |
| `status` | "Klar" / "Tveksam" / "Inte klar". |
| `prose` | Multi-line Swedish text suitable for push / Shiny. |

## Surfaces

- **R API:** `compute_taper_plan()`, `compute_race_readiness()` in
  `R/advanced_metrics.R`. Sibling renderers
  (`render_taper_plan_prose()`, `render_race_readiness_prose()`) in
  the same file.
- **MCP:** `get_taper_plan(race_date, distance_km, taper_weeks)` and
  `get_race_readiness(target_date, taper_weeks)` in
  `python/traning_cli/mcp/tools.py`.
- **Shiny:** `app/tRanat/pages/page_race.R` replaces the Phase-5d
  placeholder with a date input + distance input + cards showing the
  plan tibble and the readiness prose.
- **CLI:** intentionally deferred — the Python CLI doesn't have a
  `race` group today and the MCP + Shiny surfaces cover the day-to-
  day need. A future task can wire `traning race plan` / `traning
  race readiness` when Phase 5e starts.

## Out of scope (Phase 5e+)

- Per-sport taper schemas (cycling / triathlon).
- Goal-pace prediction or VDOT.
- Multi-race scheduling.
- Automatic detection of the next planned race from a calendar.
