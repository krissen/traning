"""Vayu — MCP server for tRäning (personal running analysis)."""

import sys

from fastmcp import FastMCP

from . import tools, prompts

mcp = FastMCP(
    "Vayu",
    instructions=(
        "Vayu: Personal running analysis server (Garmin + Apple Watch).\n\n"
        "RECOMMENDED WORKFLOW:\n"
        "1. get_readiness — check today's readiness score and recent trend\n"
        "2. get_sessions — see recent training sessions\n"
        "3. get_training_load — PMC (fitness/fatigue/form) or ACWR\n"
        "4. Use plot=True on any tool to get a visual chart\n\n"
        "All tools support date filtering via 'after' and 'before' parameters.\n"
        "Date formats: '2025-01-01', '2025-01', '2025', '-3w', '-1y', '-6m'.\n\n"
        "Data sources: ~4600 running sessions (2004-2026), Apple Watch health "
        "metrics (HRV, sleep, resting HR, VO2max from 2013+)."
    ),
)


# --- Register tools ---
mcp.tool()(tools.get_readiness)
mcp.tool()(tools.get_sleep)
mcp.tool()(tools.get_hrv)
mcp.tool()(tools.get_training_load)
mcp.tool()(tools.get_efficiency)
mcp.tool()(tools.get_zones)
mcp.tool()(tools.get_sessions)
mcp.tool()(tools.get_monthly_summary)
mcp.tool()(tools.get_yearly_summary)
mcp.tool()(tools.get_decoupling)
mcp.tool()(tools.get_recovery_hr)
mcp.tool()(tools.get_resting_hr)
mcp.tool()(tools.get_vo2max)
mcp.tool()(tools.compare_periods)
mcp.tool()(tools.explain_metric)

# --- Register prompts ---
mcp.prompt()(prompts.daglig_check)
mcp.prompt()(prompts.veckoutvardering)
mcp.prompt()(prompts.konditionsbedomning)

# --- Register resources ---
mcp.resource("vayu://metrics")(tools.resource_metrics)
mcp.resource("vayu://thresholds")(tools.resource_thresholds)


def main():
    """Entry point for the vayu command."""
    transport = "stdio"
    if "--sse" in sys.argv:
        transport = "sse"
    mcp.run(transport=transport)


if __name__ == "__main__":
    main()
