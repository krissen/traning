# Sport filtering policy

This codebase routinely answers two different questions about training
metrics:

1. **"How is my running going?"** — running-specific reports (pace,
   efficiency factor, HRE, decoupling, weekly km). These should filter
   to running only; mixing other sports muddles the answer.

2. **"How loaded am I right now?"** — system-wide load/form/readiness
   (PMC, ACWR in non-running contexts). These should include **every**
   activity that produces physiological stress, including strength
   sessions, cycling, vandring, and vardagsrörelse (the non-workout
   walking captured by daily step / distance metrics) — not just
   logged workouts.

   Monotony is the current exception: `compute_monotony_strain()`
   still aggregates kilometres, not TRIMP, so it stays running-only
   until a future TRIMP-mode change. See the table below.

The same function may be used in either context, so the rule lives in
the **default `sport` argument** and the **caller's explicit override**.

## Defaults by function

| Function | Default `sport` | Why |
|---|---|---|
| `compute_trimp()` | `"all"` | Whole-system HR-based load. Folds in background TRIMP from `health_daily` when supplied. |
| `compute_pmc()` | `"all"` | CTL/ATL/TSB is whole-system fitness/fatigue/form. |
| `compute_acwr()` | `"running"` | Default mode is km — only meaningful within one sport. Caller passes `sport="all"` for the multisport TRIMP-mode variant. |
| `compute_monotony_strain()` | `"running"` | The implementation aggregates daily km, so mixing cycling and running km blurs the signal. A future TRIMP-mode (mirroring `compute_acwr()`) would unlock a meaningful `"all"` default. |
| `compute_recovery_hr()` | `"all"` | Sport-agnostic cardiovascular signal. |
| `compute_zone_distribution()` | `"running"` | Garmin's per-row zone columns are anchored to per-sport zone configs; mixing configs is misleading. |
| `compute_efficiency_factor()` | `"running"` | Pace-based, running-specific aerobika. |
| `compute_hre()` | `"running"` | Pace-based, running-specific. |
| `compute_decoupling()` | `"running"` | Pace-based, running-specific. |

## ACWR mode logic

`compute_acwr(summaries, sport, mode = NULL, …)` auto-resolves the load
mode by passing `sport` through `.resolve_sport_bucket()` — the same
resolver `.filter_sport()` uses for case variants, Swedish aliases and
curated buckets. The resolver returns either `NULL` (whole-system
sentinel: `NULL`/`"all"`/`"any"`, case-insensitive) or a vector of
canonical English sport names:

- Resolver returns `NULL` → `mode = "trimp"`.
- Resolver returns a vector of length > 1 (curated bucket like
  `"endurance"`, or an explicit vector `c("running", "cycling")`) →
  `mode = "trimp"` — km doesn't compose across sports.
- Resolver returns a single canonical sport → `mode = "km"` (classic
  Hulin/Gabbett running formulation; cycling/walking/etc. ACWR are
  km-meaningful per-sport but typically only reported for running).

An explicit `mode = "km"` or `mode = "trimp"` always wins. The result
tibble carries an `attr(., "mode")` so plot/report code can branch on
it. `report_acwr()` renames the daily/weekly columns to
`TRIMP/dag` / `TRIMP/vecka` in TRIMP mode so consumers see the right
unit; the km columns are explicitly `NA` in that mode rather than
TRIMP values mis-labelled as km.

## Background-activity TRIMP

`compute_background_trimp(health_daily, summaries = NULL)` converts
non-workout daily activity into a synthetic Banister TRIMP:

1. Take daily `walking_running_distance` (km) from HAE; fall back to
   `step_count × meters_per_step_fallback` (0.7 m default) when wrd
   is missing. Step count is the fallback because its units are
   unambiguous — HAE can write `active_energy` in kJ or kcal
   depending on user configuration and the cache doesn't preserve
   the unit field, so basing the fallback on energy was a footgun.
2. Subtract running and walking workout distance for workouts that
   `compute_trimp()` would also count (HR + duration > 10 min);
   short / HR-less walks are left in the background so they still
   contribute load somewhere.
3. Skip the step-count fallback on days with any non-walking
   workout — cycling, strength, ballsport, etc. The step counter
   drifts up during indoor cycling (pedal strokes), strength reps
   (rack motion) and similar; crediting that as walking km would
   inflate background load. The gate uses every non-walking workout
   that day regardless of HR / duration, since step-drift happens
   whether or not the session qualifies under compute_trimp()'s
   filters.
4. Convert remainder to walking minutes at 12 min/km (5 km/h default).
5. Apply Banister exponential at a fixed HR ratio of 0.30 (typical
   vardagsgång: HRrest + 30 % of reserve).

This adds ~4 TRIMP per km of background walking, so a 20 km walking
day with no logged workout contributes ~80 TRIMP — visible in CTL,
visible in readiness, visible in the daily push ACWR commentary.

The model is intentionally conservative. Per-minute HR for background
activity isn't available, so the fixed HR ratio assumes moderate
effort. Users with HR-tracked all-day data can extend
`compute_background_trimp()` to use a measured HR-ratio.

## Caller responsibility

Functions exposing a `sport` parameter (Shiny pages, CLI flags, Vayu
MCP tools) should pick the default that matches the context:

- Running-prestation pages and reports → pass `sport = "running"`
  explicitly.
- Beredskap / dagsform / belastning views → omit `sport` (let the
  function default to `"all"`) or pass `sport = "all"` explicitly.
- Mixed views (overview KPI cards): pick coherently — if PMC is
  whole-system, ACWR should be too; if the "Vecka km" card shows
  running km, it should explicitly call `compute_acwr(sport="running",
  mode="km")`.

`mod_overview.R` is the current canonical example: PMC card and ACWR
card both use whole-system load; "Vecka km" card uses an explicit
running-km computation.
