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

## Phase 4b: Unified CLI

**Goal:** Single entry point `traning <command>` replacing the current split
between `python garmin_fetch.py`, `Rscript inst/cli.R --flag`, and manual
venv activation. Same pattern as `bifrost <command>`.

**Target UX:**
```bash
traning fetch              # Garmin Connect: hämta nya aktiviteter
traning fetch --all        # Garmin Connect: hämta alla som saknas
traning fetch --dry-run    # Förhandsgranska utan nedladdning
traning import             # Importera TCX → RData-cache
traning update             # fetch + import i ett steg

traning report month       # Nuvarande --month-running
traning report year        # Nuvarande --year-running
traning report pace        # Nuvarande --total-pace
traning report top         # Nuvarande --year-top / --month-top

traning ef                 # Effektivitetsfaktor-plot
traning acwr               # ACWR-plot
traning monotony           # Monotoni/strain-plot
traning datesum 2024-01-01--2024-06-30

traning shiny              # Starta tRanat Shiny-appen
```

**Architecture:**
- Python CLI (Click) as the unified dispatcher, like `bifrost`
- R commands invoked via `Rscript` subprocess
- Python commands (fetch) invoked directly
- Installable via `pip install -e .` with `console_scripts` entry point
- Venv management transparent to user

**Why Python, not R:**
- Garmin fetch is already Python
- Click gives clean subcommand structure
- Can dispatch to R via subprocess — same as bifrost does
- Single `traning` command instead of remembering which language to use

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
