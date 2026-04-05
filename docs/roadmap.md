# tRäning — Roadmap

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
- **Tables** — Serve report tables as structured data
- **Queries** — Date range summaries, month comparisons, year-over-year analysis

**Architecture considerations:**
- R-based (plumber?) or Python-based server wrapping R functions
- Reads from the same data store as CLI/Shiny
- Stateless queries against cached summaries

**References:**
- [garmin-connect-mcp](https://github.com/etweisberg/garmin-connect-mcp) — existing MCP server for Garmin Connect with 27 tools. Routes API calls through headless Playwright. Worth studying for API design and tool surface.
- `~/dev/vyasa` (Vyasa) — our most mature MCP server (research library). Best reference for patterns.
- `~/dev/bifrost/scripts/mcp/` (Hermod) — bibliometric analysis MCP server. FastMCP-based, R data backend.
- `~/dev/narada-mcp/` (Narada) — another of our MCP servers.
