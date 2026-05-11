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

For `taper_weeks = 2` (the default), produce these week rows from
**this Monday** through the race week (inclusive):

| Phase | Window | target_km |
|---|---|---|
| Build / maintain | Today → (taper start - 1 week) | baseline_km |
| Taper -1 | First taper week | 0.65 × baseline_km |
| Race week | Final week containing race_date | 0.45 × baseline_km |

Race week is identified by the week (Mon–Sun) containing `race_date`.
The two preceding weeks become the taper window.

Rationales for the 65 % / 45 % coefficients (round numbers, within the
65–80 % / 40–55 % envelope from Bosquet 2007 and Mujika 2010):
- 65 % keeps a stimulus that limits detraining (CTL falls only slowly).
- 45 % gives the legs roughly half-volume the race week — race-day
  effort still feels familiar but accumulated fatigue (ATL) has time
  to decay.

For shorter or longer tapers, `taper_weeks` scales the schedule
linearly: each taper week step reduces by `(1 - 0.45) / taper_weeks`.

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

2. **TSB projection (form)** — project today's TSB through `target_date`
   using the taper plan's target_km converted to expected TRIMP, then
   score the projected TSB:
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
- **CLI:** `Rscript inst/cli.R --race-date YYYY-MM-DD --race-distance KM
  [--taper-weeks N]` produces both the plan table and the readiness
  card.
- **MCP:** `get_taper_plan(race_date, distance_km, taper_weeks)` and
  `get_race_readiness(target_date)` in `python/traning_cli/mcp/tools.py`.
- **Shiny:** replace the placeholder in
  `app/tRanat/pages/page_race.R` with a date input + distance input +
  cards showing the plan tibble and the readiness prose.

## Out of scope (Phase 5e+)

- Per-sport taper schemas (cycling / triathlon).
- Goal-pace prediction or VDOT.
- Multi-race scheduling.
- Automatic detection of the next planned race from a calendar.
