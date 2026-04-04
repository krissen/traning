# tRäning — Roadmap

## ~~Phase 2: Reorganise project structure~~ DONE (2026-04-03)

Completed. See changelog for details. Project is now an R package with
`R/` modules, `inst/cli.R` entry point, and `devtools::load_all()` workflow.

---

## ~~Phase 3: Garmin data fetching library~~ DONE (2026-04-04)

Completed. Python script in `python/` fetches activities from Garmin Connect.
Auth via `pirate-garmin` (browser-based, bypasses Cloudflare). Downloads
TCX + JSON to `gconnect/`, creates symlinks in `tcx/`, auto-commits to
data repo. Compatible with existing R import pipeline. See
`docs/user/garmin-fetch-setup.md` and `docs/dev/garmin-fetch-design.md`.

---

## Phase 4: Build knowledge base

**Goal:** Ground all analysis decisions in running science literature.

**Priority topics (from Sports Analyst):**

1. **Training Load & Stress (TRIMP/HRSS)** — Transform raw HR data into cumulative load metrics; enable fatigue/fitness tracking (ATL/CTL/TSB) across 15+ years of data
2. **Cardiac Drift & Aerobic Decoupling** — Pace-to-HR ratio analysis over run halves; decoupling >5% signals aerobic deficiency
3. **Heart Rate Zone Distribution** — Time-in-zone per run and aggregated monthly/yearly; reveals training polarization (80/20)
4. **Pace-HR Efficiency Trend (Cardiac Cost)** — Pace/HR ratio over months and years to detect long-term aerobic fitness changes
5. **Volume Periodization** — Weekly/monthly km progression, acute:chronic workload ratio, monotony/strain indices for injury-risk patterns

**Process:** Librarian searches literature, saves to `research/`, creates primers in `research/_analys/`. Analysis decisions documented in `_decisions/`.

---

## Phase 5: MCP server

**Goal:** Expose tRäning as an MCP (Model Context Protocol) server.

**API capabilities:**
- **Garmin download** — Trigger data fetch from Garmin Connect
- **Stats** — Serve computed statistics (monthly/yearly summaries, pace trends, totals)
- **Images** — Serve generated plots as PNG (cumulative distance, pace over time, etc.)
- **Tables** — Serve report tables as structured data
- **Queries** — Date range summaries, month comparisons, year-over-year analysis

**Architecture considerations:**
- R-based (plumber?) or Python-based server wrapping R functions
- Reads from the same data store as CLI/Shiny
- Stateless queries against cached summaries
