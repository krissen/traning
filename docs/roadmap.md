# tRäning — Roadmap

## Service hardening and ingress control

**Goal:** Make tRanat private-by-default on kailash, with one explicit ingress
layer for the web UI and Tailscale-only binds for machine-to-machine services.

**Deliverables:**
- Bind `traning-shiny` to loopback and publish it only through reverse proxy.
- Bind `traning-receiver` and `traning-vayu` to Tailscale instead of
  `0.0.0.0`.
- Keep the web UI on its own host name (`traning.niemi.cc`) while restricting
  access to trusted networks only.
- Document the supported kailash deployment so the host can be rebuilt from
  repo state plus secrets.

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

## Shiny import UI

**Goal:** Upload zip exports (Withings, etc.) via browser for backfill
into canonical health storage.

**Deliverables:**
- New Shiny page with file upload widget
- Auto-detect archive type from contents (reuse `identify_archive()`)
- Preview: show date range, metrics found, new vs existing counts
- Confirm → write canonical files
- Builds on `traning backfill` CLI infrastructure (`health/backfill.py`)

---

## Daily pre-aggregation for high-volume metrics

**Goal:** Import high-volume metrics (active_energy, basal_energy_burned,
walking_running_distance) without parsing thousands of intra-day samples.

**Current state:** These metrics are excluded from import because their
canonical files contain minute-level data (25K+ samples/day for
basal_energy_burned). step_count is included but parses 1100+ samples
to produce one daily row.

**Approach:** Pre-aggregate to daily totals at the canonical file level
(in Python's `save_health_push()` or a new post-save step), or add a
fast-path in `read_canonical_file()` that sums without full parsing.

**Outcome:** Could add step_count, active_energy, walking_running_distance
to the cache at near-zero cost, useful for daily activity dashboards.

---

## Smart insight notifications

**Goal:** Post-import push notifications that are contextually relevant
and actionable, not just raw numbers.

**Current state:** Basic one-liner with km, pace, HR, TRIMP, and
month comparison (always positive framing).

**Future examples:**
- "Löpning 6 km. Långsammare än snittet men längre — månadens total: 45 km."
- "Sovtimmar (6) registrerade. HRV sjunkande trend — ta det lugnt idag?"
- "Första löpningen på 5 dagar. ACWR 0.6 — bra återhämtning."
- Health: flag red metrics (HRV below baseline, sleep < 6h)

**Depends on:** Readiness model (Phase 5a), PMC data.

---

## Shiny "Utveckling"-fliken: full historik visas inte

**Bug:** Most figures on the Utveckling page only show the last 1–2
years even though `summaries` contains 20+ years of data. Examples:
- "April över åren" visar endast 2026
- Löpande månad-jämförelse mot tidigare år visar bara 2025 och 2026

**Likely cause:** the global date-range selector at the top of the
app (defaults to "12 months") leaks into the Utveckling page. The
page is meant to span the full dataset, so it should either ignore
the global `dates` reactive entirely or expose its own range
selector. Check `page_progress_server()` and the plot helpers
(`fetch.plot.*`) to see which branch is actually filtering.

**Deliverables:**
- Audit each plot on the page; confirm whether the limitation is in
  the plot helper (`fetch.plot.*`) or in the date filter.
- Either default to "all years" or expose a year-count selector per
  plot. The full 20-year history should be reachable.

---

## Sport-mix per month: kcal/time, not just km

**Goal:** Make the sport-mix view comparable across sports. Kilometres
say nothing meaningful when comparing a cycling commute (high km, low
load) with a strength session (zero km).

**Deliverables:**
- Page on Sport-mix to switch between kcal, duration, and km
  (kcal and duration are the meaningful defaults).
- Verify Garmin/HAE data sources for kcal availability per sport.

**Note:** Sport-selector visibility — sport-mix is by construction
cross-sport and should not show the global sport selector (same UX
issue flagged on Overview).

---

## Vayu plot returns "Plot file not found"

**Symptom:** `get_readiness(plot=True)` (and any other vayu MCP tool
asking for a plot) returns `{"type": "error", "message": "Plot file
not found"}`.

**Root cause:** Race condition between R's per-process temp directory
and the Python reader.

Flow today:
1. `mcp_bridge.R` runs as a subprocess of `r_bridge.py`.
2. R writes a PNG to a tempfile via `tempfile()` under `/tmp/RtmpXXX/`.
3. R prints a JSON envelope with the path to stdout, e.g.
   `{"type":"plot","path":"/tmp/Rtmp7is7hp/vayu_fd….png"}`.
4. `r_bridge.py` parses the path and tries
   `Path(png_path).read_bytes()`.
5. The file is gone — R cleaned up its `RtmpXXX` session as soon as
   the subprocess exited (which is before Python gets to step 4).

Confirmed manually: running `mcp_bridge.R` from a shell returns a
path, but `ls` of that path right after shows nothing. R's
`tempdir()` is tied to the R process's lifetime; the session cleanup
on exit removes the directory.

**Options** (pick later in the implementation plan):

- **A. Fixed external tmp directory.** Write to e.g. `/tmp/vayu_plots/`
  which Python controls. Need a hash/date stem on filenames so two
  concurrent plots don't collide; a registry is overkill since
  plots are transient (only useful "right now"). Likely cleanest:
  one-shot temp file with random suffix + age-based GC.
- **B. Inline base64 PNG.** R reads the PNG, base64-encodes the
  bytes and embeds the data in the JSON envelope. No filesystem
  hand-off. Bigger JSON payloads but eliminates the race entirely.
- **C. `on.exit()` / `sys.on.exit()` to suppress Rtmp cleanup.**
  Hacky; not pursued.

User leaning: A keeps payloads small and is the natural fit when
volumes are low; revisit B if the file-handoff complexity outgrows
its benefit.

**Environment:** kailash, Arch Linux, R via Rscript, vayu MCP server
in `/home/krisse/dev/traning/python/traning_cli/mcp/`.

---
