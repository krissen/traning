# tRäning — Roadmap

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

**API capabilities:**
- **Garmin download** — Trigger data fetch from Garmin Connect
- **Stats** — Serve computed statistics (monthly/yearly summaries, pace trends, totals)
- **Images** — Serve generated plots as PNG (cumulative distance, pace over time, etc.)
- **Tables** — Serve report tables as structured data (JSON/JSONL ready via `save_table()`)
- **Queries** — Date range summaries, month comparisons, year-over-year analysis

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

## Refactor: Unified report function signatures

**Goal:** All `report_*()` functions share the same `(summaries, n, from, to)`
signature and use `.tail_or_daterange()` for filtering, limiting, and sorting.

**Deliverables:**
- Migrate `report_monthtop`, `report_monthstatus`, `report_monthlast`,
  `report_yearstop`, `report_yearstatus`, `report_runs_year_month` to
  `(summaries, n, from, to)` signature with `.tail_or_daterange()`
- `--limit` works on all commands (currently only `report_monthtop`)
- Remove pre-filtering in CLI layer (`summaries_filtered`) for migrated
  commands — let the functions handle it themselves
- Update Shiny app callers
- Update tests

**Dependencies:** None.

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
