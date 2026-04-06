# tRäning — Roadmap

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

**Dependencies:** Phase 5a readiness model (done), automated pipeline (5b, done).

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
