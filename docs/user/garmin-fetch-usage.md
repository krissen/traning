# Garmin Fetch — Usage Guide

## Basic usage

Fetch up to 50 new activities (the default):

```bash
source python/.venv/bin/activate
python python/garmin_fetch.py
```

Then import into R:

```bash
Rscript inst/cli.R --import
```

## Options

| Flag | Description |
|------|-------------|
| `--limit N` | Fetch at most N new activities (default: 50) |
| `--all` | Fetch all missing activities (ignores --limit) |
| `--dry-run` | Show what would be fetched, don't download |
| `--reauth` | Force re-authentication (ignore saved tokens) |
| `--verbose` / `-v` | Enable debug logging |

## Initial backfill

If you have a gap in your data (e.g. activities since Nov 2023 are missing), fetch everything:

```bash
python python/garmin_fetch.py --all
```

This may take a while due to API rate limits. Progress is logged every 10 activities. If interrupted, re-run — it skips already-downloaded activities.

## Automation with cron

To fetch new activities daily at 06:00:

```bash
crontab -e
```

Add:

```
0 6 * * * TRANING_DATA=$HOME/Documents/traning-data /path/to/traning/python/.venv/bin/python /path/to/traning/python/garmin_fetch.py >> /tmp/garmin-fetch.log 2>&1
```

## What gets downloaded

Per activity, three files are saved to `$TRANING_DATA/kristian/filer/gconnect/`:

- `{timestamp}_{id}_summary.json` — Activity metadata
- `{timestamp}_{id}_details.json` — Detailed metrics
- `{timestamp}_{id}.tcx` — TCX track data

A symlink is created in `$TRANING_DATA/kristian/filer/tcx/`:

- `YYYYMMDD-HHMMSS.tcx` → `../gconnect/{timestamp}_{id}.tcx`

The R import pipeline (`Rscript inst/cli.R --import`) picks up the symlinks automatically.
