# tRäning — Changelog

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
