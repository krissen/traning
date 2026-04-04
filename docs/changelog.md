# tRäning — Changelog

## 2026-04-04 — Phase 3: Garmin data fetching

- Added Python-based Garmin Connect fetcher (`python/`)
  - `garmin_fetch.py` — CLI entry point with `--limit`, `--all`, `--dry-run`, `--reauth`
  - `garmin_auth.py` — OAuth authentication with TOTP/MFA support
  - `garmin_download.py` — Activity download (summary JSON, details JSON, TCX)
  - `garmin_utils.py` — Naming conventions matching existing gconnect/ format
- Created `requirements.txt` (garth, garminconnect, requests) and `setup_venv.sh`
- Symlinks in `tcx/` created automatically (relative paths, same convention as bulk export)
- Incremental fetching: scans existing files, only downloads new activities
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
