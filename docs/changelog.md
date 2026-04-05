# tRäning — Changelog

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
