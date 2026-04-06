# tRäning — Roadmap

## Phase 5a+: Health import performance

**Goal:** Avoid re-parsing all 120+ JSON files on every `traning import health`.

**Problem:** `import_health_export()` reads every file in `health_export/metrics/`
on every run, even if they were already imported. With 120 files and growing,
this takes ~10 seconds and produces noisy output.

**Deliverables:**
- File manifest (`imported_files.json` or similar) tracking which files have
  been imported and their mtime/size at import time
- `import_health_export()` only parses new or modified files
- Merge new data onto cached `health_daily.RData` (already works)
- `--force` flag to re-import everything (bypass manifest)

**Dependencies:** Phase 5a (done), CLI sync redesign (done).

---

## Phase 5b: Automated health data pipeline

**Goal:** Automate daily health data import from iPhone to server.

**Deliverables:**
- FastAPI receiver on kailash (port 8421) accepting HAE JSON POST
- HAE iOS automations: health metrics at 06:00, workouts at 06:30
- Systemd service for receiver, Tailscale networking
- Resting HR export without aggregation (separate automation)

**Dependencies:** Health export pipeline (done), Tailscale (done).

---

## Phase 5c: MCP server

**Goal:** Expose tRäning as an MCP server for AI-powered training analysis.

**Deliverables:**
- FastMCP server (Python) wrapping R functions via subprocess
- Tools: readiness, sleep, HRV, training load, sessions, fitness trend,
  period comparison, taper planning, daily suggestion
- Plot tools returning PNG
- R bridge module for subprocess execution and result parsing

**Dependencies:** Phase 5a readiness model (done), automated pipeline (5b).

**References:** Hermod (FastMCP + R), Vyasa, garmin-connect-mcp (27 tools).

---

## Phase 5d: Taper planning & race analysis

**Goal:** Answer "I have a race on date X — help me prepare."

**Deliverables:**
- `compute_taper_plan(race_date, distance_km)` — weekly km targets
  with ACWR constraint (max +10%/week), 2-week taper, TSB target 5–15
- `compute_race_readiness(target_date)` — CTL/ACWR/HRV trajectory assessment
- Exposed via MCP and CLI

**Dependencies:** Phase 5a (done), Phase 5c (MCP).

---

## Phase 4f: HR zone distribution & polarization index

**Goal:** Track training intensity distribution and flag the "moderate
intensity trap" (excessive Zone 2 training).

**Deliverables:**
- Collapse Garmin 5-zone to research 3-zone (Seiler: Z1 < VT1, Z2 = VT1-VT2, Z3 > VT2)
- Per-second zone classification from myruns (covers full 20-year history)
- Polarization Index (Treff 2019)
- Stacked bar chart (monthly/yearly), PI trend line
- Cross-validate Garmin hrTimeInZone (316 activities) against per-second results
- CLI: `traning zones --after -1y`

**Data sources:** Garmin JSON hrTimeInZone_1..5 (316 activities, Dec 2024+),
per-second HR from myruns (3412 activities, full history).

**Dependencies:** `R/garmin_json.R`, `R/physiology.R` (both done).

---

## Phase 4g: Aerobic decoupling

**Goal:** Compare first-half vs second-half pace:HR ratio to quantify
aerobic fitness limitations within a single run.

**Deliverables:**
- `compute_decoupling()` — per-second data extraction, first 10 min excluded,
  midpoint split, 30s rolling mean on speed (GPS noise), temperature annotation
- Trend plot with threshold bands (<3%, 3-5%, 5-8%, >8%)
- CLI: `traning decoupling --after -1y`

**Filters:** running, >45 min, easy pace (>5:00/km).

**Dependencies:** Requires new `R/persecond.R` module for myruns access pattern.

---

## Phase 5: MCP server

**Goal:** Expose tRäning as an MCP (Model Context Protocol) server.

**API capabilities:**
- **Garmin download** — Trigger data fetch from Garmin Connect
- **Stats** — Serve computed statistics (monthly/yearly summaries, pace trends, totals)
- **Images** — Serve generated plots as PNG (cumulative distance, pace over time, etc.)
- **Tables** — Serve report tables as structured data (JSON/JSONL ready via `save_table()`)
- **Queries** — Date range summaries, month comparisons, year-over-year analysis

**Groundwork done (v0.3.0):**
- All report functions return tibbles — direct JSON serialization
- `save_table(format="jsonl")` produces one JSON object per row
- `save_plot(format="png")` for image responses
- `get_output_defaults()` for configurable paths

**Architecture considerations:**
- R-based (plumber?) or Python-based server wrapping R functions
- Reads from the same data store as CLI/Shiny
- Stateless queries against cached summaries

**References:**
- [garmin-connect-mcp](https://github.com/etweisberg/garmin-connect-mcp) — existing MCP server for Garmin Connect with 27 tools. Routes API calls through headless Playwright. Worth studying for API design and tool surface.
- `~/dev/vyasa` (Vyasa) — our most mature MCP server (research library). Best reference for patterns.
- `~/dev/bifrost/scripts/mcp/` (Hermod) — bibliometric analysis MCP server. FastMCP-based, R data backend.
- `~/dev/narada-mcp/` (Narada) — another of our MCP servers.
