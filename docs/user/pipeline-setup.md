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
ssh kailash 'cd ~/dokument/traning-data && git log --since="24 hours ago" --format="%ai %s"'

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

HAE pushes automatically in the background. iOS may delay execution;
frequency depends on Background App Refresh and device state (charging
improves reliability).

The two automations are independent. Workouts can stop while metrics keep
flowing (and vice versa) — always check both endpoints separately.

### When HAE data stops arriving

**1. Ask the server what it last saw.**

```bash
# Last actual POST per endpoint, with the app version that sent it
ssh kailash 'sudo journalctl -u traning-receiver --since "14 days ago" | grep -E "push from|rejected|POST /v1/(health|workouts)"'

# In-memory counters (last_received, last_workouts_import, pending_files)
ssh kailash 'curl -s -H "X-API-Key: <key>" http://100.93.126.68:8421/v1/status'

# What actually landed on disk — authoritative, survives journal rotation.
# Sorted by write time, so the top entry is the most recent arrival.
ssh kailash 'ls -lt ~/dokument/traning-data/kristian/health_export/workouts | head -3'
ssh kailash 'ls -lt ~/dokument/traning-data/kristian/health_export/canonical/heart_rate | head -3'
```

Two caveats: `/v1/status` counters live in the process and reset on every
receiver restart (compare against `uptime_seconds`), and the journal can
have gaps. When the two disagree, trust the files on disk.

Every push logs one line identifying its sender, written before the payload
is validated so even a rejected push leaves a trace. The shape of the line
is fixed by the code; what fills the second field is whatever the app sends:

```
/v1/health push from <client ip> (User-Agent: <client string>)
```

The User-Agent normally carries the HAE app's version. Compare the last
push before the silence with the first one after it: a string that changed
across the gap makes an app update the likely trigger — it is a correlation,
not proof, but it is the only version signal the server has.

A push rejected as malformed logs a second line naming the field that
failed and why, so a changed payload shape can be read off the journal:

```
/v1/health rejected by validation: body.data.metrics: too_short
```

The values are deliberately left out — they are health samples, and the
journal is not the place for them. To see the payload itself, look at the
export in the app.

**2. Read the outcome.**

| What you see | Where the fault is |
|--------------|--------------------|
| `401`/`403` on POST | API key mismatch — key in HAE no longer matches `/etc/traning/env` |
| `422` on POST | Payload rejected — app changed its format; the log names the field |
| Connection resets, no POST logged | Network — Tailscale down on phone or on kailash |
| No POST at all, `/health` still 200 | Phone side — automation disabled, expired, or never fired |

**Known failure mode: silent stop after an HAE app update.** After the app
updates, its automations can stay dormant until the app is opened manually
once. Nothing fails visibly — no error on the phone, no request at the
receiver, and `/health` keeps answering 200. The only symptom is that
`last_received` in `/v1/status` stands still while the clock moves.

Check the User-Agent from step 1 afterwards — a string that differs on
either side of the gap points to the update as the likely trigger.

Fix: open Health Auto Export on anandavani and leave it in the foreground
for a few seconds. A dormant automation catches up with one large backfill
push covering the whole silence, so a fresh commit in the data repo right
after opening the app confirms this was the cause.

The two flows wake independently and not at the same pace. Metrics usually
arrive within a minute; workouts can take considerably longer, since the app
works through every session in the gap. Give workouts time before concluding
that its automation is disabled — count the files in
`health_export/workouts/` again after a while rather than immediately.

**3. Total silence — check the phone (anandavani).**

- Both automations still **enabled** in Health Auto Export, not just one.
- Last run / error status per automation — a failed run usually shows there.
- `X-API-Key` header still present. App updates and re-installs can drop
  custom headers; re-paste from `deploy/traning-env.local` if unsure.
- Tailscale connected, and `http://100.93.126.68:8421/health` reachable
  from Safari on the phone (should return `{"status":"ok"}`).
- Background App Refresh on for the app, and Low Power Mode off.

**4. Verify the flow is alive again.**

Trigger a manual export in the app, then:

```bash
# The files themselves — written during the push, so they are there at once
ssh kailash 'ls -t ~/dokument/traning-data/kristian/health_export/workouts | head -3'
ssh kailash 'cd ~/dokument/traning-data && git log --since="1 hour ago" --format="%ai %s"'

# The POST itself, with sending client and metric/sample counts
ssh kailash 'sudo journalctl -u traning-receiver --since "10 min ago" | grep -E "push from|rejected|Received|POST /v1/"'

# last_received should move to now
ssh kailash 'curl -s -H "X-API-Key: <key>" http://100.93.126.68:8421/v1/status'
```

Files land **during the push**, not after a delay: workouts in
`health_export/workouts/`, metrics in
`health_export/canonical/<metric>/<date>.json` (sleep stays in
`health_export/metrics/`). The 10-minute debounce delays only the R import
that folds the data into the caches — `TRANING_HEALTH_DEBOUNCE` for metrics,
`TRANING_WORKOUTS_DEBOUNCE` for workouts (which falls back to the health
value when unset). A manual export backfills the whole gap in one push, so
expect a large sample count.

Check the files, not the counters. `pending_files` and `pending_workouts`
are non-zero only between the push and the flush — after the debounce they
read 0 again, whether the push succeeded or never happened. The files on
disk and the data-repo commits are the lasting evidence.

Confirm both endpoints separately — `last_received` moving proves only that
*something* arrived. Test arrival, not content: a canonical file named with
today's date may well have been written by an earlier push the same day.
Ask which files were **touched** instead:

```bash
# Metrics that arrived in the last 10 minutes (0 = nothing came in)
ssh kailash 'find ~/dokument/traning-data/kristian/health_export/canonical -name "*.json" -newermt "10 minutes ago" | wc -l'

# Same question for workouts
ssh kailash 'find ~/dokument/traning-data/kristian/health_export/workouts -name "*.json" -newermt "10 minutes ago" | wc -l'
```

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
