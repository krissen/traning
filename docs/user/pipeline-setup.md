# Automated Data Pipeline — Setup & Operations

## Overview

The pipeline runs on **kailash** (Arch Linux server) and automatically collects:

1. **Health data** from iPhone via Health Auto Export (HAE) app → FastAPI receiver
2. **Garmin activities** via Strava webhook → Home Assistant → FastAPI trigger

Data is committed to `traning-data` git repo on kailash, pushed to GitHub daily,
and pulled to kedar for R analysis.

```
anandavani (iPhone)          kailash (Arch Linux)           kedar (Mac)
┌─────────────┐      ┌──────────────────────────┐     ┌─────────────┐
│ HAE app     │─POST─│ FastAPI :8421             │     │ Development │
│             │      │  /v1/health → metrics/    │     │             │
│             │      │  /v1/workouts → workouts/ │     │             │
│ Garmin watch│      │                           │     │             │
│ → Connect   │      │ Strava webhook → HA →     │     │             │
│ → Strava    │      │  /v1/trigger/garmin       │     │             │
└─────────────┘      │                           │     │             │
                     │ git push daily → GitHub ──│─────│→ git pull   │
                     └──────────────────────────┘     └─────────────┘
```

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

# Notifications — what was sent?
ssh kailash 'sudo journalctl -u traning-receiver --since "24h ago" | grep "Avisering"'

# HA log (automations, errors — not individual notify calls)
ssh kailash 'grep -i "garmin_fetch\|rest_command" /var/local/docker/ha-stack/homeassistant/home-assistant.log'

# HA logbook (Strava sensor changes, automation triggers)
hass-cli --server https://niemi.cc:8123 --output json \
  raw get '/api/logbook/2026-04-07T19:00:00'

# Data repo — what was actually saved?
ssh kailash 'cd ~/dokument/traning-data && git log --since="24h ago" --format="%ai %s"'

# Manual Garmin fetch on kailash
ssh kailash 'TRANING_DATA=~/dokument/traning-data ~/dev/traning/python/.venv/bin/traning fetch garmin -v'

# Test FastAPI
curl http://kailash:8421/health
curl -H "X-API-Key: <key>" http://kailash:8421/v1/status
```

## HAE configuration (iPhone)

Two automations in Health Auto Export app on anandavani:

1. **Health metrics:** REST API POST to `http://<kailash-ip>:8421/v1/health`
2. **Workouts:** REST API POST to `http://<kailash-ip>:8421/v1/workouts`

Both with header `X-API-Key: <key from traning-env.local>`.

HAE pushes automatically in the background. iOS may delay execution;
frequency depends on Background App Refresh and device state (charging
improves reliability).

## Services on kailash

| Service | Type | Schedule |
|---------|------|----------|
| `traning-receiver` | long-running | Always on, auto-start at boot |
| `traning-garmin.timer` | timer (fallback) | Every 2h, 06–22 |
| `traning-push.timer` | timer | Daily 03:00 |

Primary Garmin trigger is the Strava webhook via Home Assistant
(`automation.garmin_fetch_on_new_strava_activity`).

## Sensitive files

| File | Contains | Synced via |
|------|----------|------------|
| `/etc/traning/env` on kailash | API key, Garmin creds, HA token | `deploy.sh secrets` |
| `.garmin_tokens/` in traning-data | Garmin OAuth session | `deploy.sh tokens` |
| `deploy/traning-env.local` | Local copy of env (gitignored) | Never committed |
| `.Renviron` | TRANING_DATA, R_LIBS_USER, LANG (per-machine) | Generated by `deploy.sh secrets` |
