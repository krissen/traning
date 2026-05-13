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
TRANING_NOTIFY_TITLE="tRäning" \
TRANING_NOTIFY_MSG="Garmin (timer): $fetch_summary" \
TRANING_NOTIFY_TRIGGER="garmin_timer" \
    "$VENV/python" -c "
import os
from traning_cli.server.notify import notify, log_notification
title = os.environ['TRANING_NOTIFY_TITLE']
msg = os.environ['TRANING_NOTIFY_MSG']
trigger = os.environ['TRANING_NOTIFY_TRIGGER']
sent = notify(title, msg)
log_notification(trigger, title, msg, sent)
" || true

# Notify: import result
import_line=$(echo "$import_output" | grep -iE 'import|distance' | tail -1)
if [ -n "$import_line" ]; then
    TRANING_NOTIFY_TITLE="tRäning" \
    TRANING_NOTIFY_MSG="Import garmin: $import_line" \
    TRANING_NOTIFY_TRIGGER="garmin_timer" \
        "$VENV/python" -c "
import os
from traning_cli.server.notify import notify, log_notification
title = os.environ['TRANING_NOTIFY_TITLE']
msg = os.environ['TRANING_NOTIFY_MSG']
trigger = os.environ['TRANING_NOTIFY_TRIGGER']
sent = notify(title, msg)
log_notification(trigger, title, msg, sent)
" || true
fi

# Insight
TRANING_NOTIFY_REPO_ROOT="$REPO_ROOT" \
    "$VENV/python" -c "
import os
import subprocess
from traning_cli.server.notify import notify, log_notification

repo_root = os.environ['TRANING_NOTIFY_REPO_ROOT']
r = subprocess.run(
    ['Rscript', '-e',
     'devtools::load_all(\".\", quiet=TRUE); '
     'td <- Sys.getenv(\"TRANING_DATA\"); '
     'tl <- my_dbs_load(file.path(td,\"cache\",\"summaries.RData\"), '
     'file.path(td,\"cache\",\"myruns.RData\")); '
     'cat(report_insight(tl[[\"summaries\"]]))'],
    capture_output=True, text=True, timeout=120,
    cwd=repo_root)
if r.returncode == 0 and r.stdout.strip():
    msg = r.stdout.strip()
    title = 'tRäning'
    sent = notify(title, msg)
    log_notification('garmin_timer_insight', title, msg, sent)
" || true
