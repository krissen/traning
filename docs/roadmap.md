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

## ~~Phase 4: Build knowledge base~~ DONE (2026-04-04)

Knowledge base built. 50 papers across 6 topics ingested in Vyasa and
checked out to `sources/`. Analysis primers with formulas and thresholds
in `research/_analys/`. First three metrics implemented in R:
Efficiency Factor, ACWR, and Monotony/Strain — with plot functions and
CLI flags (`--ef`, `--acwr`, `--monotony`).

Remaining for future implementation (per-second data needed):
- HR Zone Distribution (Polarization Index)
- Cardiac Drift & Aerobic Decoupling
- TRIMP / ATL / CTL / TSB (Performance Management Chart)

---

## ~~Phase 4b: Unified CLI~~ DONE (2026-04-05)

Completed. Single `traning <command>` entry point via Python Click dispatcher.
Garmin modules restructured as proper package (`python/traning_cli/garmin/`).
R reports/plots delegated via subprocess to `inst/cli.R`. Installable via
`pip install -e .` with `console_scripts` entry point.

---

## ~~Phase 4c: Flexible date ranges & plot variants~~ DONE (2026-04-05)

Completed. All report commands now accept `--after`/`--before`/`--span`
for flexible date filtering (absolute and relative expressions). All
table commands have plot variants via `--plot` flag. Shared helpers
(`R/daterange.R`, `R/plot_reports.R`) ensure zero duplication. Python
CLI updated with shared decorator. See `docs/user/cli-reference.md`.

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
