# tRäning — Roadmap

## Phase 5d: Taper planning & race analysis

**Goal:** Answer "I have a race on date X — help me prepare."

**Deliverables:**
- `compute_taper_plan(race_date, distance_km)` — weekly km targets
  with ACWR constraint (max +10%/week), 2-week taper, TSB target 5–15
- `compute_race_readiness(target_date)` — CTL/ACWR/HRV trajectory assessment
- Exposed via MCP and CLI

**Dependencies:** Phase 5a (done), Phase 5c (MCP).

---

## MCP transport: SSH → SSE over Tailscale

**Goal:** Replace current SSH stdio transport with persistent SSE server
accessible over Tailscale, reducing latency and improving reliability.

**Current state:** Vayu runs via `ssh kailash` with stdio transport —
each invocation pays SSH handshake cost and R session startup.

**Plan:**
1. Add SSE transport support to Vayu entrypoint (`--transport sse --port <port>`)
2. Validate that FastMCP SSE mode works with the existing R bridge
3. Create systemd unit for persistent Vayu service on kailash
4. Update Claude Code MCP config: `"type": "sse", "url": "http://kailash:<port>/sse"`
5. Keep SSH config as fallback until SSE is proven stable

**Benefits:**
- No SSH overhead per tool call
- Persistent R session (faster repeated queries)
- More robust over Tailscale than SSH tunneled stdio

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

## Per-sport CTL overlay

**Goal:** Track chronic training load per discipline so a heavy cycling
or strength week doesn't artificially deflate the running CTL story.

**Default sport buckets:** cycling, walking, running, strength.

**Deliverables:**
- Extend `compute_pmc()` (or wrapper) so it returns a CTL/ATL/TSB
  series per sport bucket alongside the existing running-only view.
- Plot overlay (already partly present in `page_sport_mix.R`) becomes
  a first-class metric per the four buckets.
- MCP exposure via `get_training_load(sport=<bucket>)`.

**Dependencies:** TRIMP must be computed per sport, not just running.

---

## Shiny "Utveckling"-fliken: full historik visas inte

**Bug:** Most figures on the Utveckling page only show the last 1–2
years even though `summaries` contains 20+ years of data. Examples:
- "April över åren" visar endast 2026
- Löpande månad-jämförelse mot tidigare år visar bara 2025 och 2026

**Likely cause:** plot helpers using `Sys.Date() - lubridate::years(N)`
default with a too-small N, or default `dates` reactive narrowing
the window before the page sees it.

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
