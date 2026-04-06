# tRäning — Changelog

## 2026-04-06 — Refactor: Unified report function signatures

### Unified `(summaries, n, from, to)` signature (`R/report.R`)
- All 6 basic report functions now accept `n`, `from`, `to` parameters:
  `report_monthtop`, `report_monthstatus`, `report_monthlast`,
  `report_yearstop`, `report_yearstatus`, `report_runs_year_month`
- New `.filter_input()` helper filters raw summaries by `from`/`to`
  on `sessionStart`, reusing `filter_by_daterange()` from `R/daterange.R`
- `report_runs_year_month` no longer uses `do_year`/`do_month` — replaced
  by `from`/`to` with default=current month
- `report_monthlast` `print()` side effect removed

### `--limit` on all commands (`inst/cli.R`)
- All basic report commands now support `--limit` (`report_monthstatus`,
  `report_monthlast`, `report_yearstop`, `report_yearstatus`,
  `report_runs_year_month` — `report_monthtop` already had it)
- `summaries_filtered` pre-filter variable removed — each function
  handles its own filtering via `from`/`to`
- `--total-pace` uses inline `filter_by_daterange()` call

### Plot pass-through (`R/plot_reports.R`)
- All 6 plot functions accept and forward `from`/`to` to their report functions
- `plot_runs_month` no longer uses `do_year`/`do_month`

### Shiny app (`app/tRanat/server.R`)
- 12 call sites (6 report + 6 plot) switched from `summaries_f()` to
  `summaries` + `from`/`to` from global date preset
- `summaries_f()` kept for pace tab only

### Tests
- 259 tests total (was 223), all passing
- New `test-report-basic.R` (38 tests): signature validation, `n` limiting,
  `from`/`to` filtering, descending sort, no side effects

---

## 2026-04-06 — Remove Phase 4h (FIT & Polar import) from roadmap

Data audit confirmed that all 2 093 FIT files (2012–2020) are already
covered by corresponding TCX files (~1:1 per year). The 265 SRD files
(2004–2006) were previously converted to TCX (in `tcx/srd-import/`).
Cache covers 4 619 activities from 2004-12-31 to 2026-04-05 — no gaps.
FIT/SRD import adds no new data; phase removed.

## 2026-04-06 — Phase 4f: HR zone distribution & polarization index

### Zone computation (`R/hr_zones.R`)
- Seiler 3-zone model: Z1 (low, <VT1), Z2 (threshold, VT1–VT2),
  Z3 (high, ≥VT2) with configurable thresholds (default 80%/90% HRmax)
- Two data sources with hybrid fallback:
  - Per-second HR classification from myruns (2932 sessions, 2004–2022)
  - Garmin JSON hrTimeInZone fallback for sessions without per-second
    data (317 sessions, 2023+)
- Treff (2019) Polarization Index: PI = log₁₀((Z1/Z2) × Z3 × 100)
  with edge-case handling (Z2=0 uses Eq. 2, Z3=0 → PI=0)
  - PI > 2.0 = polarized, PI ≤ 2.0 = non-polarized
- Cross-validation function comparing Garmin device zones vs per-second
- Incremental cache (`zone_distribution.RData`): first run ~8s for
  4500 sessions, subsequent runs ~2s; caches both computed and skipped
  sessions; `--force` clears cache

### Time-varying HRmax (`R/physiology.R`)
- `get_hr_max_at(date)` returns per-date HRmax that declines with age
- Priority: BIRTH_YEAR env + Tanaka formula (208 − 0.7 × age), then
  linear fit of yearly 98th percentile from garmin_maxHR, then fallback
- Zone thresholds now per-session: a 2004 run (HRmax 192) gets different
  VT1/VT2 than a 2026 run (HRmax 176)
- `BIRTH_YEAR` added to `.Renviron` / `.Renviron.example`

### Visualizations (`R/plot_zones.R`)
- `fetch.plot.hr_zones()` — stacked bar chart (monthly zone distribution)
  with 80% Z1 target line; auto-scaling x-axis for 1–20+ year spans
- `fetch.plot.polarization()` — PI trend with polarized/non-polarized bands
- `fetch.plot.zone_comparison()` — scatter cross-validation (Garmin vs
  per-second) with identity line and deviation coloring

### CLI
- R CLI: `--hr-zones` flag (table or `--plot`)
- Python CLI: `traning zones [--plot] [--force] [--after/--before]`

### Report sorting
- All `report_*()` tables now sort newest first (descending chronological)
- Applies to all 15 report commands via `.tail_or_daterange()` and
  individual `arrange(desc())` calls

### Tests
- 223 tests total (was 174), all passing
- New `test-hr-zones.R` (49 tests): zone distribution, PI formula with
  Treff 2019 reference values, report formatting, edge cases

---

## 2026-04-06 — Phase 5a+: Health import performance

### Incremental health import (`R/health_export.R`)
- File manifest (`health_import_manifest.json`) tracks mtime and size per
  imported JSON file in `$TRANING_DATA/cache/`
- `import_health_export()` compares files against manifest and only parses
  new or modified files — skips unchanged ones entirely
- Typical incremental import: 2–3 new files instead of 120+
- `--force` flag bypasses manifest and re-imports everything
- Manifest updated atomically after successful cache save

### CLI updates
- R CLI: new `--force` flag on `--import-health`
- Python CLI: `traning import health --force`, `traning sync health --force`

### Tests
- 174 tests total (was 159), all passing
- New manifest tests: new file detection, unchanged skip, modified detection,
  roundtrip save/load, force bypass

---

## 0.4.0 — Apple Watch integration & readiness model

### Apple Watch health data pipeline (`R/health_export.R`)
- New module parses Health Auto Export (HAE) iOS app JSON exports
- Handles 3 data formats: standard qty, heart rate Min/Avg/Max, nested sleep
- Source filtering: removes Garmin Connect contamination from resting HR
  (Connect reports ~100 bpm vs Apple Watch ~50 bpm; HAE averages them)
- Raw sleep segment parser: 96K+ segments across 13 years from 6+ sources
  (Sleep Cycle, Apple Watch, Oura, AutoSleep, etc.), with per-night source
  selection (prefers AW staging), segment deduplication, and overlap-safe
  aggregation
- Daily aggregation for non-aggregated exports (sum for steps/energy,
  mean for physiological metrics, min/max for heart rate)
- Cache I/O: `load_health_data()` / `save_health_data()` → `health_daily.RData`
- Convenience: `pivot_health_wide()`, `get_readiness()` with Ln(RMSSD)

### Data backfill
- TCP backfill script (`python/backfill_tcp.py`) queries HAE TCP server on
  iPhone in 3-month chunks, saves per-metric JSON files
- 117K rows, 91 metrics, 2013–2026 imported:
  - Sleep: 4471 nights (2013+), Resting HR: 2976 days (2017+),
    HRV: 2934 days (2017+), VO2max: 2204 days (2017+),
    Cardio recovery: 858 days (2022+), plus step count, active energy,
    walking metrics, body composition, running mechanics, etc.
- Known gaps: 2023-06 → 2024-03 and 2025-03 → 2025-12 (missing from HealthKit)

### Health visualizations (`R/plot_health.R`)
- `fetch.plot.resting_hr()` — 9-year trend with LOESS + annual means
- `fetch.plot.hrv()` — Ln(RMSSD) with 7-day rolling baseline ± 1 SD band
- `fetch.plot.sleep()` — total sleep LOESS + monthly stage breakdown
  (kärnsömn/REM/djupsömn/vaken) with 7h target line
- `fetch.plot.vo2max()` — Apple Watch VO2max estimate trend

### Readiness model (`R/readiness.R`)
- `compute_readiness()` — daily composite score (0–100) fusing Apple Watch
  health data with Garmin training load
- Four components via piecewise-linear scoring:
  - HRV (35%): Ln(RMSSD) z-score vs 7-day rolling baseline
  - Sleep (30%): total hours + staging quality bonus/penalty
  - Resting HR (20%): deviation from 30-day rolling baseline
  - Training load (15%): previous day's TRIMP ratio to ATL
- NA-aware weight redistribution when components are missing
- Warning flags: HRV suppression (z < -1), sustained RHR elevation
  (>5 bpm for 3+ consecutive days), poor sleep + suppressed HRV,
  acute load spike (>2× ATL)
- Traffic-light status: Grön (≥70), Gul (40–69), Röd (<40)
- Data quality tracking: full/partial/minimal
- `fetch.plot.readiness_score()` — 4-panel patchwork dashboard:
  score with zone bands, HRV with baseline ribbon + flag markers,
  sleep bars with flag coloring, ATL/CTL lines + TRIMP bars
- Based on Seshadri 2019, Plews 2013, Buchheit 2014, Simpson 2017

### Shiny app updates
- New top-level "Readiness" tab with integrated 4-panel dashboard + table
- New "Hälsa" menu with Vilopuls, HRV, Sömn, VO2max tabs
- Health data loaded at startup via `load_health_data()` in global.R
- Readiness dashboard uses renderPlot (patchwork incompatible with plotly)

### CLI updates
- `--readiness` — daily readiness table or 4-panel dashboard (with `--plot`)
- `--import-health` — import Apple Watch health data from HAE JSON files
- Supports `--after`/`--before`/`--limit` for date filtering
- `patchwork` added to Suggests in DESCRIPTION

### Tests
- 159 tests total (was 93), all passing
- New `test-health-export.R` (28 tests): parser formats, source cleaning,
  aggregation, pivot, readiness accessor
- New `test-readiness.R` (66 tests): piecewise scoring, component scores,
  weighted composite, consecutive flag, integration tests

---

## 0.3.0 — Unified output system

### Consistent table/plot toggle for all commands
- All 14 report commands now support both table and plot output via `--plot`
- Advanced metrics (EF, HRE, ACWR, monotony, PMC, recovery HR) previously
  plot-only — now default to table output like all other commands
- New `report_ef()`, `report_hre()`, `report_acwr()`, `report_monotony()`,
  `report_pmc()`, `report_recovery_hr()` functions in `R/report.R`
- `report_monthtop()` now accepts `n` parameter (was hardcoded to 10)
- `--limit` flag to control table row count on any command

### File output with format support
- `--output FILE` saves output to file (both plots and tables)
- `--format` for explicit format: plots (`pdf`, `png`), tables (`csv`,
  `json`, `jsonl`, `xlsx`)
- Default save location: `$TRANING_DATA/output/plots/` and
  `$TRANING_DATA/output/tables/` with timestamped filenames
- `--no-open` suppresses auto-opening of saved files (open is default)
- `save_plot()` and `save_table()` helpers in `R/utils.R`
- JSONL output in preparation for MCP server integration

### Configurable defaults via environment
- `TRANING_OUTPUT_DIR` — base directory for saved output
- `TRANING_PLOT_FORMAT` — default plot format (default: pdf)
- `TRANING_TABLE_FORMAT` — default table format (default: csv)
- `TRANING_OPEN` — auto-open after save (default: true)

### Date filtering fix for time-series metrics
- ACWR, monotony, PMC, EF, HRE, recovery HR now receive full unfiltered
  data for computation; date range applied to the output only
- Previously, `--after`/`--before` pre-filtered input data, corrupting
  rolling-window calculations at boundaries
- Time-series plot functions accept `from`/`to` parameters that override
  the `days=365` default

### Python CLI updates
- All commands forward `--output`, `--format`, `--no-open`, `--limit`
- Advanced metric commands now respect `--plot` toggle (was hardcoded to
  always-plot)

### Shiny app rebuilt from scratch
- `global.R` — data loading at startup with Garmin JSON augmentation
- `ui.R` — `navbarPage` with 5 sections: Månad (4 tabs), År (2 tabs),
  Tempo, Datumperiod (with date picker), Avancerat (6 tabs)
- `server.R` — all 14 report types with both plot and table output
- Each tab shows plot + interactive DT table simultaneously
- Recovery HR gracefully handles missing Garmin data

### Tests
- 65 tests total (was 36), all passing
- New `test-report-advanced.R` covering all 6 advanced report functions,
  `save_plot()`, and `save_table()` (CSV, JSON, JSONL)

---

## 2026-04-05 — Phase 4e: Literature-driven metric expansion

### Data pipeline: Garmin JSON integration (`R/garmin_json.R`)
- New module reads 4398 Garmin JSON file pairs (summary + details)
- Handles both old format (summaryDTO-nested, pre-late-2024) and new format
  (flat top-level keys)
- `import_garmin_json()` — batch-reads all JSON, extracts maxHR,
  hrTimeInZone_1..5, vO2MaxValue, recoveryHeartRate, directWorkoutRpe,
  averageTemperature, minHR
- `augment_summaries()` — joins Garmin JSON fields to summaries via
  timestamp matching (±120 s tolerance)
- Added `jsonlite` to DESCRIPTION Imports

### Physiological configuration (`R/physiology.R`)
- `import_resting_hr()` — parses Apple Watch resting HR CSV
  (2431 daily observations, 2017-09 to 2024-10); filters out Garmin
  "Connect" entries and physiological outliers
- `get_hr_max()` — four-level priority: HR_MAX env → 98th percentile of
  Garmin maxHR → Tanaka formula → 185 bpm fallback
- `get_hr_rest(date)` — time-varying resting HR from Apple Watch data
  (backward-looking 30-day rolling mean); falls back to HR_REST env or
  50 bpm for dates outside AW coverage
- `save_resting_hr()` / `load_resting_hr()` — RData cache

### New metric: HRE — Heart Rate Efficiency (`R/advanced_metrics.R`)
- `compute_hre()` — avgHR × avgPace = beats/km (Votyakov et al. 2025)
- Filter: running, >5 km, HR > 0; 28-day rolling mean
- Votyakov thresholds: <700 well-fitted, 700-750 fitted, >800 poorly-fitted
- `fetch.plot.hre()` — scatter + rolling mean + threshold bands
- CLI: `traning hre`

### New metric: TRIMP / CTL / ATL / TSB — Performance Management Chart
- `compute_trimp()` — Banister bTRIMP per session (Morton 1990 formula)
  with time-varying HRrest from Apple Watch data
- `compute_pmc()` — daily CTL (42-day EWMA), ATL (7-day EWMA),
  TSB = CTL - ATL (Murray 2017 EWMA method)
- `fetch.plot.pmc()` — three-panel chart: fitness/fatigue lines, TSB zone
  bars (with coaching heuristic caveat), daily TRIMP bars
- CLI: `traning pmc --after -1y`

### New metric: Recovery Heart Rate
- `compute_recovery_hr()` — extracts post-workout recovery HR from enriched
  summaries (520 activities, Nov 2023+), 28-day rolling mean
- `fetch.plot.recovery_hr()` — scatter + rolling mean trend
- CLI: `traning recovery-hr`

### ACWR corrections (literature-driven)
- Fixed underloading threshold 0.5 → 0.8 (Hulin 2016)
- Added uncoupled ACWR as dashed grey line on plot (Impellizzeri 2020:
  coupled variant systematically dampens spikes)
- Added `weekly_pct_change` column (Nielsen 2014: >30% = injury risk)

### EF improvements (literature-driven)
- Refactored `fetch.plot.ef()` to dual-panel chart with weekly km bars
  below (volume context, per Votyakov 2025 recommendation)

### CLI updates
- R CLI: new `--hre`, `--pmc`, `--recovery-hr` flags
- Python CLI: new `traning hre`, `traning pmc`, `traning recovery-hr`
  commands

---

## 2026-04-05 — Phase 4d: Evidence-based primer rework

All 6 research themes rewritten with actual literature findings:
1. Continuous Wearable Data (6 papers)
2. Cardiac Drift & Decoupling (5 papers)
3. Pace-HR Efficiency (6 papers)
4. HR Zone Distribution (7 papers)
5. Volume Periodization / ACWR (9 papers)
6. Training Load / TRIMP (12 papers)

Tracking: `research/_analys/PROGRESS.md` (all items complete).

---

## 2026-04-05 — Phase 4c: Flexible date ranges & plot variants

### Date range system (`R/daterange.R`)
- New `--after`, `--before`, `--span` flags on all report and plot commands
- Flexible date expressions: absolute (`2023`, `2023-03`, `2023-03-04`) and
  relative (`-3w`, `-1y`, `-6m`, `-10d`)
- `--span` for windowed queries: `--after -1y --span 3m` = 3-month window
  starting 1 year ago
- Legacy `--datesum YYYY-MM-DD--YYYY-MM-DD` format still works
- Pre-filters summaries upstream — existing report functions unchanged

### Plot variants for all table commands (`R/plot_reports.R`)
- New `--plot` flag switches table output to a chart
- `plot_monthtop()` — horizontal bar chart, colored by year
- `plot_runs_month()` — lollipop chart with pace color scale
- `plot_monthstatus()` — year-comparison bar chart for current month
- `plot_monthlast()` — year-comparison bar chart for last month
- `plot_yearstatus()` — year-to-date bar chart
- `plot_yearstop()` — full-year totals bar chart
- `plot_datesum()` — auto-aggregated bars (daily/weekly/monthly by span)
- Shared `.plot_year_bars()` helper for consistent styling
- `--total-pace --plot` wires to existing `fetch.plot.mean.pace()`

### Python CLI updates (`python/traning_cli/main.py`)
- Shared `report_options` decorator adds `--plot`/`--after`/`--before`/`--span`
  to all report commands
- `_r_report()` helper eliminates per-command boilerplate
- Plot commands (`ef`, `acwr`, `monotony`) also accept date range flags

### Tests
- `tests/testthat/test-daterange.R` — 15 test cases for parsing, range building,
  and filtering

---

## 2026-04-05 — Phase 4b: Unified CLI

- Single `traning` command replacing `Rscript inst/cli.R` and `python garmin_fetch.py`
- Python Click CLI dispatcher (`python/traning_cli/main.py`)
  - `traning fetch` — Garmin Connect fetch (pure Python, calls garmin modules directly)
  - `traning import` — TCX → RData cache (delegates to R)
  - `traning update` — fetch + import in one step
  - `traning report {month,year,pace,top,month-top,month-this,month-last}` — reports
  - `traning ef`, `traning acwr`, `traning monotony` — plot commands
  - `traning datesum RANGE` — date range summary
  - `traning shiny` — launch tRanat Shiny app
- Garmin modules restructured: `python/garmin_*.py` → `python/traning_cli/garmin/`
  - Proper Python package with relative imports
  - Path resolution updated for new directory depth
- `pyproject.toml` with `console_scripts` entry point (`pip install -e .`)
- `setup_venv.sh` updated to install CLI automatically
- Same pattern as bifrost CLI

## 2026-04-04 — Phase 4: Knowledge base & advanced metrics

### Knowledge base
- Literature search across 6 topics: training load (TRIMP), cardiac drift,
  HR zone distribution, pace-HR efficiency, volume periodization, wearable data
- 50 papers ingested in Vyasa, checked out as symlinks in `sources/`
- 6 analysis primers in `research/_analys/` with formulas, thresholds, and
  implementation guidance
- Analysis spec with prioritized implementation order in
  `research/_decisions/analysis-spec.md`
- Garmin Connect JSON field catalogue in `research/_decisions/garmin-json-fields.md`
  — discovered `hrTimeInZone_1..5`, `directWorkoutRpe`, `recoveryHeartRate`,
  `vO2MaxValue`, and `averageTemperature` fields

### Advanced metrics (`R/advanced_metrics.R`)
- `compute_efficiency_factor()` — pace:HR ratio per run + 28-day rolling mean
- `compute_acwr()` — acute:chronic workload ratio (coupled + uncoupled)
- `compute_monotony_strain()` — Foster's training monotony and strain indices
- All three use summaries data only (no per-second data needed)

### Visualizations (`R/plot.R`)
- `fetch.plot.ef()` — EF scatter + loess + rolling mean trend
- `fetch.plot.acwr()` — dual-panel ACWR zones + weekly km bars
- `fetch.plot.monotony()` — dual-panel monotony + strain
- CLI flags: `--ef`, `--acwr`, `--monotony`

### Import fixes (`R/import.R`)
- Fix trackeR 1.6.1 unit converter bug (`.onLoad()` copies all converters)
- Match files by basename to handle relative vs absolute path mismatch
- Improved error handling with actual error messages in Swedish
- Fix `report_mostrecent()` NA total distance (`na.rm = TRUE`)

## 2026-04-04 — Phase 3: Garmin data fetching

- Added Python-based Garmin Connect fetcher (`python/`)
  - `garmin_fetch.py` — CLI with `--limit`, `--all`, `--dry-run`, `--reauth`, `--login-method`
  - `garmin_auth.py` — Auth via pirate-garmin (browser login, DI tokens ~1 year)
  - `garmin_download.py` — Activity download (summary JSON, details JSON, TCX)
  - `garmin_utils.py` — Naming conventions matching existing gconnect/ format
- Authentication: pirate-garmin handles post-Cloudflare Garmin auth (mobile SSO + DI OAuth)
  - `--login-method browser` (default): pirate-garmin browser login
  - `--login-method native`: garminconnect TLS impersonation (fallback)
  - Credentials from `.Renviron` (GARMIN_EMAIL/GARMIN_PASSWORD) or interactive prompt
- `requirements.txt` (garminconnect, pirate-garmin, requests) and `setup_venv.sh`
- Symlinks in `tcx/` created automatically (relative paths, same convention as bulk export)
- Incremental fetching: scans existing files, only downloads new activities
- Auto-commits new activities to data repo after fetch
- Rate limiting with exponential backoff for Garmin API
- Documentation: `docs/user/` (setup + usage), `docs/dev/` (design)
- Added test bootstrap (`tests/testthat.R`) and smoke test for `dec_to_mmss()`

## 2026-04-03 — Phase 2: R package structure

- Restructured project as an R package (`DESCRIPTION`, `NAMESPACE`, `R/`)
- Split `read_my_fit.r` (747 lines) into 5 domain modules:
  - `R/utils.R` — `dec_to_mmss()`
  - `R/metrics.R` — `add_my_columns()`, `fix_zero_moving()`
  - `R/import.R` — data I/O functions (`my_dbs_load`, `get_new_workouts`, etc.)
  - `R/report.R` — all 8 `report_*` functions
  - `R/plot.R` — all 4 plot/data functions
- Created thin CLI wrapper at `inst/cli.R` (replaces `r/read_my_fit.r`)
- Fixed global variable leaks: `get_new_workouts(verbose=)`, `report_mostrecent(n_imported=)`
- Moved `r/` → `scripts/` (standalone scripts) and `r/tRanat/` → `app/tRanat/`
- Removed personal training graphs (PNG) from git tracking
- Consolidated `.Renviron` to project root
- All functions namespace-qualified (`dplyr::filter`, `ggplot2::ggplot`, etc.)

## 2026-04-03 — Phase 1: Externalize data

- Training data now lives in a separate repo (`~/Documents/traning-data/`)
- Data paths configured via `TRANING_DATA` env var in `.Renviron`
  - Updated `r/read_my_fit.r`, `r/gor_sa_har.r`, `r_aw/aw_heartrate.r`
  - Added `.Renviron.example` templates in `r/` and `r_aw/`
- Created public GitHub repo: https://github.com/krissen/traning
