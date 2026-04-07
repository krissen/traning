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
