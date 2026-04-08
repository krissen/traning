# Pipeline Architecture — Design Document

## Context

Phase 5b automates health and training data collection. Previously all data
fetching was manual (`traning fetch health` with HAE TCP server open,
`traning fetch garmin` run by hand). Now data flows automatically to kailash
and syncs to kedar via GitHub.

## Infrastructure

### Devices

| Name | Role | OS | Tailscale |
|------|------|----|-----------|
| **kailash** | Server — runs FastAPI, timers, HA | Arch Linux | Yes |
| **anandavani** | iPhone — HAE app, health data source | iOS | Yes |
| **kedar** | Development Mac — code, R analysis | macOS | Yes |

### Paths on kailash

- Code: `~/dev/traning/` (git clone of krissen/traning)
- Data: `~/dokument/traning-data/` (git clone of krissen/traning-data)
- Env: `/etc/traning/env` (credentials, mode 0600)
- Venv: `~/dev/traning/python/.venv/`
- Systemd units: `/etc/systemd/system/traning-*.{service,timer}`

### Git remotes on kailash

SSH deploy keys (no passphrase) via `~/.ssh/config` aliases:

```
Host github-data  → ~/.ssh/github_deploy      → krissen/traning-data
Host github-code  → ~/.ssh/github_deploy_code  → krissen/traning
```

GitHub requires unique deploy keys per repo, hence two keys.

## Data flow

### Health data (HAE → kailash)

```
HAE app (anandavani)
  │ HTTP POST (JSON, API key auth)
  ▼
FastAPI /v1/health (kailash:8421)
  │ save_health_push() — one file per metric
  │ {metric}_{first_date}_{last_date}.json
  ▼
health_export/metrics/
  │ git add + git diff --cached --quiet + git commit
  │ background: Rscript cli.R --import-health
  ▼
health_daily.RData (cache, available to Vayu)
  │ traning-push.timer (daily 03:00)
  ▼
GitHub (krissen/traning-data)
  │ traning pull (on kedar)
  ▼
R import (import_health_export → health_daily.RData)
```

HAE may push multiple times per day. The `git diff --cached --quiet` check
ensures commits only happen when file content actually changes. Typical
pattern: 1-2 commits/day as new samples accumulate.

### Workout data (HAE → kailash)

Same flow via `POST /v1/workouts`. Files saved as
`{workout_name}-{YYYYMMDD_HHMMSS}.json` in `health_export/workouts/`.

### Garmin activities (watch → kailash)

```
Garmin watch → Garmin Connect → Strava (auto-sync)
  │
  ▼
ha_strava HACS integration (sensor update)
  │
  ▼
HA automation (state trigger on sensor.strava_kristian_niemi_recent_activity)
  │ REST command POST
  ▼
FastAPI /v1/trigger/garmin (kailash:8421)
  │ BackgroundTasks → subprocess: traning fetch garmin
  ▼
traning fetch garmin
  │ Garmin Connect API → summary JSON + details JSON + TCX
  │ git add + git commit
  │ then: Rscript cli.R --import (rebuild summaries.RData)
  ▼
traning-data repo
```

**Fallback:** `traning-garmin.timer` polls every 2h during 06–22.
Catches activities if HA/Strava webhook misses them.

**HA automation filter:** The automation triggers on Strava sensor state
changes, but filters out `unavailable` and `unknown` states to avoid
spurious fetches on sensor reconnect.

### Notification chain

Each data path triggers three notifications in sequence:

```
1. Receive    "Hälsodata: 28 metrics mottagna"
2. Import     "Import hälsa: klart"
3. Insight    "Hälsa 2026-04-07: vila 64 bpm, HRV 107 ms, sömn 6.2 h"
```

Garmin variant:
```
1. Trigger    "Garmin fetch triggered by Strava: ..."   (from HA)
2. Fetch      "Garmin fetch: Fetched 1 new activities"  (from receiver)
3. Import     "Import garmin: 1 workouts imported..."   (from _run_import)
4. Insight    "Löpning 8.1 km, 5:00/km, TRIMP 63..."   (from _run_insight)
```

Import and insight run as background tasks; failures are logged and
notified but never block the HTTP response.

### Cache portability

`summaries.RData` can be copied from kedar to kailash. The import
function matches on `basename(summaries$file)`, not full paths, so
kedar-specific paths in the file column don't prevent matching.

Strategy for bulk changes: build cache on kedar (fast), `scp` to
kailash, run `--import` to pick up any new files (seconds).

**Important:** Do NOT copy `health_import_manifest.json` between
machines. It contains mtime values that are machine-specific (files
have different mtimes after git pull). Each machine must build its
own manifest. Copy only `*.RData` cache files.

**Why not shell_command?** HA runs in Docker. Even with host networking,
shell_commands execute inside the container where the Python venv doesn't
exist. The REST command to our FastAPI server (which runs on the host via
systemd) solves this cleanly.

## FastAPI server design

### Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/health` | No | Healthcheck |
| GET | `/v1/status` | API key | Uptime, stats |
| POST | `/v1/health` | API key | Receive HAE health metrics |
| POST | `/v1/workouts` | API key | Receive HAE workouts |
| POST | `/v1/trigger/garmin` | API key | Trigger Garmin fetch (background) |

### Storage module (`storage.py`)

Reuses file-writing pattern from `health/tcp.py:158-186`:
- Same `{"data":{"metrics":[...]}}` JSON wrapper
- Same `{metric}_{first}_{last}.json` filename convention
- R-side `import_health_export()` uses manifest-based incremental import
  keyed on filename + mtime, so new files from FastAPI are picked up
  automatically

### Commit deduplication

`commit_health_data()` does:
1. `git add health_export/metrics/ health_export/workouts/`
2. `git diff --cached --quiet` — exit 0 means nothing changed
3. Only commits if diff found

This means HAE can push hourly but commits only happen when data changes.

### Notification (`notify.py`)

Calls HA REST API `notify.mobile_app_anandavani` on:
- Health data received
- Workout data received
- Garmin fetch with new activities

Fail-safe: notification errors are logged but never block data operations.

Each call logs the full message to stderr (→ systemd journal):
```
INFO traning_cli.server.notify: Avisering skickad: [tRäning] Hälsodata: 29 metrics mottagna
```

### Debugging notifications

To verify what notifications were sent and when, check these sources
in order:

1. **systemd journal** (primary) — contains the actual notification
   text logged by `notify.py`:
   ```bash
   ssh kailash 'sudo journalctl -u traning-receiver --since "1h ago" --no-pager'
   ```
   Look for lines matching `Avisering skickad:` (success) or
   `Avisering misslyckades:` (failure).

2. **HA log file** on kailash — useful for verifying the Strava
   trigger automation fired, but does NOT log individual notify
   service calls at default log level:
   ```bash
   ssh kailash 'grep -i "garmin_fetch\|rest_command" /var/local/docker/ha-stack/homeassistant/home-assistant.log'
   ```
   Rotated logs: `.log.1`, `.log.crash`, `.log.fault` in the same dir.

3. **HA logbook** via hass-cli from kedar — shows automation
   triggers and entity state changes:
   ```bash
   hass-cli --server https://niemi.cc:8123 --output json \
     raw get '/api/logbook/2026-04-07T19:00:00' \
     | python3 -c "import json,sys; [print(f'{e[\"when\"]}  {e[\"name\"]}: {e.get(\"message\",\"\")}') for e in json.load(sys.stdin) if any(k in (e.get('name','')+e.get('entity_id','')).lower() for k in ['strava','garmin','traning'])]"
   ```

4. **data repo git log** — confirms what data was actually saved
   (complements notification log):
   ```bash
   ssh kailash 'cd ~/dokument/traning-data && git log --since="24h ago" --format="%ai %s"'
   ```

5. **iPhone notification history** — last resort if journal is
   unavailable or logging was not yet configured.

## Deploy workflow

All operations from kedar via `deploy.sh`:

```
deploy.sh code      git pull + pip install + R deps + systemd restart
deploy.sh secrets   SCP traning-env.local → /etc/traning/env
deploy.sh tokens    SCP .garmin_tokens/ → traning-data on kailash
deploy.sh status    systemctl + journalctl overview
deploy.sh all       code + secrets + tokens + enable services
```

Code is deployed via git (not rsync). Both kailash and kedar work from
the same GitHub remote. Sensitive files (credentials, tokens, .Renviron)
are never committed — transferred via SCP only.

### R dependencies

`deploy.sh code` runs `scripts/install_r_deps.sh` which:
1. Parses Imports + server-critical Suggests from DESCRIPTION
2. Tries pacman (Arch binaries) first — currently none available
3. Falls back to CRAN source install with `Ncpus=4`
4. Verifies all packages installed

System dependencies required (pacman/paru): `gdal`, `udunits` (AUR).

### Generated `.Renviron`

`deploy.sh secrets` writes `~/dev/traning/.Renviron` with:
- `TRANING_DATA` — path to data repo
- `TRANING_OPEN=false` — suppress interactive plot windows
- `R_LIBS_USER=~/R/library` — user library (system `/usr/lib/R/library` is not writable)
- `LANG=sv_SE.utf8` — UTF-8 locale for Swedish column names

## Home Assistant configuration

Files on kailash in `/var/local/docker/ha-stack/homeassistant/`:

- `conf.d/shell_commands/traning.yaml` — (legacy, replaced by rest_command)
- `automations/traning_garmin_fetch.yaml` — Strava trigger automation
- `configuration.yaml` — `rest_command.traning_fetch_garmin` definition

The rest_command uses `http://localhost:8421/v1/trigger/garmin` which works
because the HA container uses host networking mode.

## Failure modes

| Failure | Impact | Recovery |
|---------|--------|----------|
| HAE push fails (iOS kills app) | Health data delayed | Next push catches up; manual TCP fallback |
| Garmin token expires (~1yr) | Garmin fetch fails | `deploy.sh tokens` from kedar after re-auth |
| Strava webhook misses | Garmin fetch delayed | 2h timer fallback catches it |
| HA down | Strava trigger lost, notifications lost | Timer fallback; FastAPI is independent |
| Tailscale down | HAE can't reach kailash | Data accumulates in HealthKit |
| FastAPI crash | All receiving stopped | systemd `Restart=on-failure` (10s delay) |
| Git conflict kedar↔kailash | Push/pull fails | Append-only files; conflict unlikely in practice |
