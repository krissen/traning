#!/usr/bin/env bash
# garmin_fetch_import.sh — Fetch + import + notify (for systemd timer)
#
# Only notifies if new activities were fetched. Silent otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV="$REPO_ROOT/python/.venv/bin"
CLI_R="$REPO_ROOT/inst/cli.R"

# Fetch
fetch_output=$("$VENV/traning" fetch garmin --login-method browser 2>&1) || true
echo "$fetch_output"

# Check if anything new was fetched
if echo "$fetch_output" | grep -q "fetched 0"; then
    exit 0
fi

# Something new — import
import_output=$(Rscript "$CLI_R" --import 2>&1) || true
echo "$import_output"

# Notify: fetch result
fetch_summary=$(echo "$fetch_output" | tail -1)
"$VENV/python" -c "
from traning_cli.server.notify import notify
notify('tRäning', 'Garmin (timer): $fetch_summary')
" 2>/dev/null || true

# Notify: import result
import_line=$(echo "$import_output" | grep -iE 'import|distance' | tail -1)
if [ -n "$import_line" ]; then
    "$VENV/python" -c "
from traning_cli.server.notify import notify
notify('tRäning', 'Import garmin: $import_line')
" 2>/dev/null || true
fi

# Insight
insight=$("$VENV/python" -c "
import subprocess, sys
r = subprocess.run(
    ['Rscript', '-e',
     'devtools::load_all(\".\", quiet=TRUE); '
     'td <- Sys.getenv(\"TRANING_DATA\"); '
     'tl <- my_dbs_load(file.path(td,\"cache\",\"summaries.RData\"), '
     'file.path(td,\"cache\",\"myruns.RData\")); '
     'cat(report_insight(tl[[\"summaries\"]]))'],
    capture_output=True, text=True, timeout=120,
    cwd='$REPO_ROOT')
if r.returncode == 0 and r.stdout.strip():
    from traning_cli.server.notify import notify
    notify('tRäning', r.stdout.strip())
" 2>/dev/null) || true
