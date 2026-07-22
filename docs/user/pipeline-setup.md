# Automated Data Pipeline — Setup & Operations

## Overview

The pipeline runs on **kailash** (Arch Linux server) and automatically collects:

1. **Health data** from iPhone via Health Auto Export (HAE) app → FastAPI receiver
2. **Garmin activities** via a systemd timer that fetches from Garmin Connect
   every 15 minutes (06–23)

Data is committed to `traning-data` git repo on kailash, pushed to GitHub daily,
and pulled to kedar for R analysis.

```
anandavani (iPhone)          kailash (Arch Linux)           kedar (Mac)
┌─────────────┐      ┌──────────────────────────┐     ┌─────────────┐
│ HAE app     │─POST─│ FastAPI :8421             │     │ Development │
│             │      │  /v1/health → metrics/    │     │             │
│             │      │  /v1/workouts → workouts/ │     │             │
│ Garmin watch│      │                           │     │             │
│ → Connect   │      │ systemd timer (15 min) →  │     │             │
│             │      │  traning fetch garmin     │     │             │
└─────────────┘      │                           │     │             │
                     │ git push daily → GitHub ──│─────│→ git pull   │
                     └──────────────────────────┘     └─────────────┘
```

> **Note:** The Garmin trigger was previously a Strava webhook (Garmin →
> Strava → Home Assistant → `POST /v1/trigger/garmin`). Strava moved its
> API behind a paid subscription in 2026, so that path was retired; the
> systemd timer is now the sole trigger. The `/v1/trigger/garmin`
> endpoint still exists and can be called manually.

## Daily operations

### Normal — everything is automatic

Nothing to do. Kailash collects data, runs R import automatically
(rebuilds summaries.RData and health_daily.RData), and pushes to
GitHub at 03:00.

### Get new data on kedar

```bash
traning pull                  # git pull from GitHub
traning import health         # R-parse new HAE files
traning import garmin         # R-parse new TCX files
# or:
traning sync all              # pull + import everything
```

### Seed kailash cache from kedar

After major import changes (e.g., reimport from scratch), build
the cache on kedar (fast) and copy to kailash:

```bash
# Garmin (summaries):
Rscript inst/cli.R --import
scp ~/Documents/traning-data/cache/summaries.RData kailash:~/dokument/traning-data/cache/
ssh kailash "cd ~/dev/traning && Rscript inst/cli.R --import"   # picks up only new files

# Health:
Rscript inst/cli.R --import-health --force
scp ~/Documents/traning-data/cache/health_daily.RData kailash:~/dokument/traning-data/cache/
# Do NOT copy health_import_manifest.json — it contains kedar-specific
# mtime values. Kailash builds its own manifest on next import.
ssh kailash "cd ~/dev/traning && Rscript inst/cli.R --import-health"
```

### Import metric filter

By default, only ~19 actively used metrics are imported into the health
cache. High-volume metrics (active_energy, basal_energy_burned, etc.)
are skipped to keep import fast (~5s instead of ~60s on kailash).

To add a metric to the import:

1. Add it to `.import_metrics` in `R/health_export.R`
2. Run `Rscript inst/cli.R --import-health --force`

Canonical files for all metrics are always saved to disk — no data is
lost by the filter.

### Deploy code changes

```bash
# 1. Develop and test locally
traning serve                 # local FastAPI on :8421

# 2. Commit and push
git push origin master

# 3. Deploy to kailash
bash python/traning_cli/server/deploy/deploy.sh code
```

### Garmin token refresh (~once/year)

```bash
# 1. Re-authenticate locally (opens browser)
traning fetch garmin --reauth --dry-run

# 2. Copy tokens to kailash
bash python/traning_cli/server/deploy/deploy.sh tokens
```

### Change credentials

```bash
# 1. Edit local copy (gitignored)
vim python/traning_cli/server/deploy/traning-env.local

# 2. Deploy to kailash
bash python/traning_cli/server/deploy/deploy.sh secrets
```

### Troubleshooting

```bash
# Service status (start here)
bash python/traning_cli/server/deploy/deploy.sh status

# Specific logs
ssh kailash 'sudo journalctl -u traning-receiver --since "1h ago"'
ssh kailash 'sudo journalctl -u traning-garmin --since "24h ago"'
ssh kailash 'sudo systemctl list-timers traning-*'

# Notifications — what was sent? (notification log, preferred)
ssh kailash 'cat ~/dokument/traning-data/logs/notifications.jsonl | python -m json.tool'
ssh kailash 'tail -5 ~/dokument/traning-data/logs/notifications.jsonl'

# Notifications — systemd journal (fallback)
ssh kailash 'sudo journalctl -u traning-receiver --since "24h ago" | grep "Avisering"'

# Garmin timer — recent fetch runs (new activities picked up?)
ssh kailash 'sudo journalctl -u traning-garmin --since "24h ago" | grep -iE "new activit|Done"'

# Data repo — what was actually saved?
ssh kailash 'cd ~/dokument/traning-data && git log --since="24h ago" --format="%ai %s"'

# Manual Garmin fetch on kailash
ssh kailash 'TRANING_DATA=~/dokument/traning-data ~/dev/traning/python/.venv/bin/traning fetch garmin -v'

# Test FastAPI over Tailscale
curl http://100.93.126.68:8421/health
curl -H "X-API-Key: <key>" http://100.93.126.68:8421/v1/status
```

## HAE configuration (iPhone)

Two automations in Health Auto Export app on anandavani:

1. **Health metrics:** REST API POST to `http://100.93.126.68:8421/v1/health`
2. **Workouts:** REST API POST to `http://100.93.126.68:8421/v1/workouts`

Both with header `X-API-Key: <key from traning-env.local>`.

The receiver is intended to be Tailscale-only on kailash. If you later move
the HAE client off tailnet, change `TRANING_RECEIVER_HOST` in
`/etc/traning/env` and redeploy the units from the repo.

### Running the freshness check from a dev machine

`traning doctor run --check freshness` asks the receiver when each flow
last delivered. On kailash the API key comes from `/etc/traning/env`, so
it just works. Elsewhere, set `TRANING_RECEIVER_HOST`,
`TRANING_RECEIVER_PORT` and `TRANING_API_KEY` in `.Renviron` (see
`.Renviron.example`) with the key from `/etc/traning/env`.

Without the key the check reports `warn` and says the receiver was not
queried — not `fail`. That distinction is deliberate: a dev box's copy
of the data is as old as its last `git pull`, so judging it by file age
alone would report a red pipeline on a perfectly healthy one, and an
alarm that cries wolf is worse than no alarm.

HAE pushes automatically in the background. iOS may delay execution;
frequency depends on Background App Refresh and device state (charging
improves reliability).

## Services on kailash

| Service | Type | Schedule |
|---------|------|----------|
| `traning-receiver` | long-running | Always on, auto-start at boot |
| `traning-garmin.timer` | timer (primary) | Every 15 min, 06–23 |
| `traning-push.timer` | timer | Daily 03:00 |

The `traning-garmin.timer` is the sole Garmin trigger. (The former
Strava-webhook trigger was retired when Strava paywalled its API — see
the Overview note.)

## Sensitive files

| File | Contains | Synced via |
|------|----------|------------|
| `/etc/traning/env` on kailash | API key, Garmin creds, HA token | `deploy.sh secrets` |
| `.garmin_tokens/` in traning-data | Garmin OAuth session | `deploy.sh tokens` |
| `deploy/traning-env.local` | Local copy of env (gitignored) | Never committed |
| `.Renviron` | TRANING_DATA, R_LIBS_USER, LANG (per-machine) | Generated by `deploy.sh secrets` |
