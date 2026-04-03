# tRäning — Roadmap

## Phase 2: Reorganise project structure

**Goal:** Modern, sustainable R project layout.

**Target structure:**
```
traning/
├── DESCRIPTION          # R package metadata, declares imports
├── NAMESPACE
├── renv.lock            # Pinned dependencies via renv
├── R/
│   ├── import.R         # Parse FIT/TCX files (extract from read_my_fit.r)
│   ├── metrics.R        # Pace, HR zones, summaries, date-range aggregation
│   ├── report.R         # Text/table reporting functions
│   ├── plot.R           # ggplot2 visualizations
│   └── utils.R          # Shared helpers (dec_to_mmss, date handling)
├── inst/
│   └── cli.R            # optparse entry point — thin wrapper calling R/ functions
├── app/
│   ├── server.R         # Shiny app (currently tRanat/)
│   └── ui.R
├── tests/
│   └── testthat/
└── man/                 # roxygen2-generated docs
```

**Key moves:**
- Split `read_my_fit.r` (740 lines) into domain modules under `R/`
- Standard R package structure (`devtools::load_all()`)
- Add `renv` for dependency management
- CLI as thin script in `inst/`; Shiny app calls same exported functions
- Data stays entirely outside the repo

---

## Phase 3: Garmin data fetching library

**Goal:** Programmatic download of training data from Garmin Connect.

**Recommendation:** Python (`garth` + `garminconnect`), not R.
- No maintained R package exists for Garmin Connect
- `garth` — OAuth1/OAuth2 auth with token persistence, TOTP support
- `garminconnect` — High-level API: activities, sleep, HR, body composition (~2k GitHub stars, actively maintained)
- Call from R via `reticulate` if needed, or run Python fetch script that dumps to data directory

**Deliverables:**
- Python script for fetching new activities
- Output format compatible with R import pipeline
- Token management (no credentials in repo)

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
