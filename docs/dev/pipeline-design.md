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
| **kailash** | Server — runs FastAPI, timers, HA, Caddy ingress | Arch Linux | Yes |
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
FastAPI /v1/health (kailash Tailscale IP:8421)
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
Garmin watch → Garmin Connect (sync when phone in BT range / WiFi)
  │
  ▼
traning-garmin.timer (every 15 min, 06–23)
  │ scripts/garmin_fetch_import.sh
  ▼
traning fetch garmin
  │ Garmin Connect API → summary JSON + details JSON + TCX
  │ git add + git commit
  │ then: Rscript cli.R --import (rebuild summaries.RData)
  ▼
traning-data repo
```

The 15-minute cadence bounds trigger latency without depending on an
external push: a run typically lands in Garmin Connect within minutes of
the watch syncing, and the next timer tick picks it up.

**Retired Strava webhook trigger:** Until 2026 the primary trigger was a
Strava push webhook (Garmin → Strava auto-sync → `ha_strava` sensor → HA
state-trigger automation → `POST /v1/trigger/garmin`). Strava moved its
API behind a paid subscription (the app went `Inactive`, `athlete/activities`
returns 403), so the webhook path was removed and the timer — previously a
2-hour fallback — became the sole trigger at a tighter cadence. The
`/v1/trigger/garmin` endpoint (which also runs fetch + import) remains for
manual/future use.

### Notification chain

**Health data** — debounced, delta-based, silent on no-op:

```
POST /v1/health
  → save + git commit (synchronous)
  → _schedule_health_import(): add files to pending set, (re)arm timer
  ...                          (more pushes extend the set, reset timer)
  → after TRANING_HEALTH_DEBOUNCE seconds quiet (default 600):
    _flush_pending_health() → _import_and_notify()
      1. before = load_health_data()
      2. after  = import_health_export(pending_files)
      3. text   = health_insight_delta(before, after)
      4. notify(text)  if text is non-empty; otherwise stay silent
```

Multiple HAE batches that arrive within the debounce window collapse
into one import and at most one notification. An empty delta produces
no notification at all (silent success). Errors and timeouts always
notify.

Example notifications:
- `"Hälsa 9 apr.: HRV 55 ms (-12 vs 7d), sömn 4.2 h (kort natt)"`
- `"Hälsoimport: MISSLYCKADES (3s)"`

A `threading.Lock` serializes the import call to avoid RData cache
corruption when the timer fires concurrently with anything else.

**Workouts** — saved silently. The downstream health-push delta is
the actual signal; the workout receipt is not surfaced.

**Garmin** — single combined notification per fetch:
```
1. Fetch      (silent unless 0 new — then nothing fires)
2. Import     captured as "Import: N pass (..., Y km totalt.)"
3. Insight    captured as "Löpning K km, P/km, puls H. ..."
4. Notify     one of:
                insight only          (single-pass batch)
                import + insight      (multi-pass batch)
                import only           (insight failed)
                "Garmin import: …"    (import failed/timed out)
```

### Metric tier classification

The delta insight function classifies health metrics:

| Tier | Trigger | Metrics |
|------|---------|---------|
| 1 — rare, high signal | Any change | VO2max, SpO2, respiratory rate, wrist temp |
| 2 — daily, threshold | Significant vs 7d avg | HRV (>=5ms), resting HR (>=4bpm), sleep total (>=30min or <5h30), deep sleep (>=18min) |
| Pass-only | Never (in daily delta) | Cardio recovery, running ground contact / power / speed / stride / vertical osc. |
| 3 — noise, ignore | Never | Steps, energy, flights, heart rate, audio exposure, nutritional, etc. |

Pass-only metrics are recorded by the watch during a session and belong
to a per-session insight, not the daily digest. Their labels/units are
kept in `health_export.R` for that future use. Unknown metrics default
to tier 1.

### Status endpoint

`GET /v1/status` (API-key required) returns the receiver's runtime
state — the canonical "did the import run?" diagnosis source now that
empty-delta imports are silent:

```json
{
  "uptime_seconds": 8421,
  "last_received": "2026-04-25T22:09:17",
  "total_pushes": 142,
  "last_import": "2026-04-25T22:19:41",
  "last_import_files": 19,
  "pending_files": 0,
  "pending_timer_armed": false,
  "debounce_seconds": 600
}
```

- `last_received` — most recent `POST /v1/health` or `/v1/workouts`.
- `last_import` / `last_import_files` — when the last debounce flush
  finished and how many files it covered. Updated for every flush,
  including silent ones (empty delta).
- `pending_files` / `pending_timer_armed` — current debounce window:
  non-zero / true means new pushes have arrived and an import is
  scheduled for `<= debounce_seconds` from `last_received`.
- `debounce_seconds` — current value of `TRANING_HEALTH_DEBOUNCE`.

If `last_import` is older than `last_received + debounce_seconds`,
something blocked the flush (timer cancelled, R subprocess hung). In
the normal case the gap is exactly the debounce window.

### Notification logging

All notification events are logged to `$TRANING_DATA/logs/notifications.jsonl`
(JSONL, one line per event). Both sent and failed notifications are recorded.

```json
{"ts":"2026-04-09T07:15:07","trigger":"health_push","title":"tRäning",
 "message":"Hälsa 9 apr.: HRV 55 ms (-12 vs 7d)","sent":true}
```

Import and insight run as background tasks; failures are logged and
notified but never block the HTTP response.

### Import metric filter

`import_health_export()` only imports metrics listed in `.import_metrics`
(defined in `R/health_export.R`). This avoids parsing high-volume but
unused metrics. Metrics in `sum_metrics` are cheap regardless, since
`read_canonical_file()` takes the precomputed `daily_total` and never
touches the individual samples.

Currently imported (23 metrics):
`resting_heart_rate`, `heart_rate_variability`, `sleep_totalSleep`,
`sleep_deep`, `sleep_rem`, `sleep_core`, `sleep_awake`, `vo2_max`,
`blood_oxygen_saturation`, `cardio_recovery`, `respiratory_rate`,
`apple_sleeping_wrist_temperature`, `running_ground_contact_time`,
`running_power`, `running_speed`, `running_stride_length`,
`running_vertical_oscillation`, `step_count`, `active_energy`,
`walking_running_distance`, `basal_energy_burned`,
`alcohol_consumption`, `weight_body_mass`

To add a metric:
1. Add it to `.import_metrics` in `R/health_export.R`
2. Run `Rscript inst/cli.R --import-health --force` to reimport
3. Deploy to kailash + seed cache

Canonical files are always saved to disk by `save_health_push()`
regardless of the import filter. The filter only affects what ends up
in `health_daily.RData`.

An unparseable canonical file is skipped with a warning naming the file
and the parse error. A full sweep reads thousands of files, so aborting
on one truncated write would cost every other file in the run.

### Alcohol night table

`alcohol_nights.RData` sits beside `health_daily.RData` and is rebuilt
by `import_alcohol()` at the end of every saving health import. It reads
`canonical/alcohol_consumption/` and `canonical/dietary_energy/`
directly rather than going through the health cache, because two things
the derivation needs do not survive into it:

- **Per-sample source.** For a sum metric, `read_canonical_file()`
  returns the daily total tagged with the first sample's source, so
  `dietary_energy` cannot be filtered to DrinkControl afterwards. The
  day a food-logging app starts writing dietary energy, that column
  becomes food plus alcohol with no way to separate them.
- **The document date.** The timestamp on an alcohol sample is when the
  export ran, not when the drink was had: the day arrives as one
  aggregated row. Attribution therefore uses the canonical document's
  date, and a day's drinking is credited to the following morning.

The stored quantity is **grams of ethanol**, not drinks. A "drink" is
denominated by a setting inside DrinkControl (8, 10, 13.45 or 14 g by
jurisdiction; Sweden's 12 g standardglas is not offered), so a changed
setting would silently rewrite the meaning of every historical count.
Grams come from the app's own energy figure at 7 kcal/g, and `grams /
count` recovers the setting as a free integrity check: a drift beyond
15% sets `alcohol_unit_mismatch` and prints a message at import.
Standardglas for display is `grams / 12`.

Everything that is a parameter choice (baseline window, share window)
stays at query time, so tuning it does not require a reimport. A failure
to rebuild the alcohol table never fails the health import.

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

### Canonical sample deduplication

`canonicalize_metric()` merges every push into
`canonical/{metric}/{YYYY-MM-DD}.json`. Two rules govern what survives.

**Content keying with multiplicity.** A sample's dedup key is the whole
sample serialized with sorted keys, not `(timestamp, source)`. Sources
do write several samples in one second: DrinkControl stamps a logging
session with a single second and writes one `dietary_energy` sample per
drink. Keying on the timestamp collapsed those to one. Because two
drinks can also be byte-identical (the same beer twice in the same
second), the merge compares *counts* per key and keeps
`max(existing, incoming)`. A repeated push therefore adds nothing, while
identical-but-distinct samples both survive. Counts never shrink: a push
covers a window and is not authoritative about what it omits.

**Minute aggregates are reported, never removed.** HAE delivers the same
day in two shapes. The push automation aggregates by minute: one sample
per minute bucket, stamped at `:00`, with `foodType`/`start`/`end`
stripped. A later per-sample fetch returns the same events individually
at their real seconds. Both land in the file and the day reads double:
2026-09-05 held a 6-unit `alcohol_consumption` aggregate at 18:44:00
next to the 6-unit detail at 18:44:35.

The automation stays aggregated. Per-sample mode cannot be set per
metric, and turning it on makes heart-rate data unmanageable, so daily
aggregates are what the pipeline receives by design.

An earlier version of this branch deleted the aggregate when its `qty`
equalled the sum of its same-minute peers. That was wrong. Arithmetic
does not identify an aggregate: a real sample stamped at `:00` whose
same-minute companions happen to sum to its value has exactly the same
shape, and DrinkControl produces that shape routinely, several samples
in one minute with repeated quantities. The rule also ran over the whole
merged day on every write, so it could delete a sample that had been on
disk for weeks, contradicting the append-only invariant a few paragraphs
up. An over-counted evening is a number the reader can question; a
deleted drink cannot be restored by re-pushing, because the same rule
would delete it again.

What remains is a warning. When exactly one sample in a `(source,
minute)` bucket is stamped at `:00` and carries none of
`foodType`/`start`/`end`, while a later sample in the same minute
carries one, the bucket is named in the log with metric, date, minute
and source. It fires on a write, so a suspected double is reported when
it appears rather than on every push for the rest of the day. Nothing is
removed. Bare against bare, which is what `alcohol_consumption` looks
like in both shapes, is not reported at all: there is nothing to tell
the two apart.

Resolving a double is an operator action, `--replace-source-days` below.

`daily_total` is recomputed from what survives, and a file is rewritten
only when the merged sample list differs from what is on disk.

### Canonicalizing files fetched out of band

`traning import canonical PATH...` runs files already on disk through
`save_health_push()`. PATH may be a file or a directory of HAE exports,
in either the `{"data": {"metrics": [...]}}` envelope or a bare
`{"metrics": [...]}`. It exists so a manual fetch (the app's HTTP/MCP
server, a recovered export) is deduplicated by the same rules a live
push is, instead of by a one-off script calling `canonicalize_metric()`
directly.

All input files are folded into one payload before anything is written,
so a `(metric, date, source)` is written once per invocation however
many files cover it. Range files overlap routinely — the metrics
directory holds pairs like `active_energy_2026-04-03_2026-04-06.json`
beside `active_energy_2026-04-05_2026-04-07.json` — and writing per file
meant, under the flag below, that the second file replaced what the
first had just written. The fold uses the same multiplicity rule as the
merge onto disk, so a sample present in two files counts once while two
identical samples inside one file both survive.

`--replace-source-days` makes the input authoritative for every
`(metric, date, source)` it covers: existing samples from those sources
are discarded and replaced, other sources keep theirs. It is the
supported way to resolve an aggregate sitting on top of detail. Nothing
infers it, because the two are not distinguishable by content; the
operator asserts that the file in hand is the better record for those
days. Pair it with `--dry-run` first, which lists each combination and
how many samples would be displaced.

The receiver never sets the flag. A push that arrives on its own
schedule is not authoritative about days it did not set out to correct.
Legacy metrics (`sleep_analysis`) ignore it as well: their files span
midnight and are merged by date range rather than per day.

### Commit deduplication

`commit_health_data()` does:
1. `git add health_export/metrics/ health_export/workouts/`
2. `git diff --cached --quiet` — exit 0 means nothing changed
3. Only commits if diff found

This means HAE can push hourly but commits only happen when data changes.

### Notification (`notify.py`)

Calls HA REST API `script.traning_notify` on:
- Health data received
- Workout data received
- Garmin fetch with new activities

`script.traning_notify` (defined in
`/var/local/docker/ha-stack/homeassistant/scripts/traning_notify.yaml` on
kailash) fans out to two channels:
1. `notify.mobile_app_anandavani` (iOS push, legacy notify service —
   supports `title` + `message`)
2. `notify.send_message` targeting `notify.telegram_bot_752463669_284213061`
   (personal Telegram DM, modern notify entity — title prefixed into the
   message text)

The script-based fan-out is required because `platform: group` only
dispatches to *legacy* notify services. Modern Telegram entities created
by the `telegram_bot` integration are not addressable as
`notify.<service>` and would silently fail in a notify group.

Fail-safe: notification errors are logged but never block data operations.

Each call logs the full message to stderr (→ systemd journal):
```
INFO traning_cli.server.notify: Avisering skickad: [tRäning] Hälsodata: 29 metrics mottagna
```

**Caveat:** HA returns 200 OK once the script *starts*, not after both
channels deliver. `sent=True` in `notifications.jsonl` means HA accepted
the call — it does not guarantee Telegram or push actually went through.
Verify per-channel via HA state log on the underlying entities.

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

2. **Garmin timer journal** on kailash — confirms whether a fetch ran
   and picked up new activities:
   ```bash
   ssh kailash 'sudo journalctl -u traning-garmin --since "24h ago" --no-pager | grep -iE "new activit|Done"'
   ```

3. **data repo git log** — confirms what data was actually saved
   (complements notification log):
   ```bash
   ssh kailash 'cd ~/dokument/traning-data && git log --since="24h ago" --format="%ai %s"'
   ```

4. **iPhone notification history** — last resort if journal is
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

### Runtime bind policy

- `traning-receiver` binds to kailash's Tailscale IP (`100.93.126.68:8421`).
- `traning-vayu` binds to kailash's Tailscale IP (`100.93.126.68:8422`).
- `traning-shiny` binds to loopback (`127.0.0.1:8423`) and is published only
  through host-level reverse proxy.
- Public subdomain routing for `traning.niemi.cc` lives in the host/infra repo,
  not in this application repo.

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

HA (Docker at `/var/local/docker/ha-stack/homeassistant/`) is used for
**notifications** — the health/readiness push and Telegram fan-out via
`script.traning_notify` — not for the Garmin trigger.

The former Garmin-trigger files — `automations/traning_garmin_fetch.yaml`
and `rest_command.traning_fetch_garmin` in `configuration.yaml` — were
removed (2026-07-05) when the Strava trigger was retired. The
`/v1/trigger/garmin` endpoint remains and can still be called manually
(e.g. from HA host networking at `http://localhost:8421/v1/trigger/garmin`).

## Failure modes

| Failure | Impact | Recovery |
|---------|--------|----------|
| HAE push fails (iOS kills app) | Health data delayed | Next push catches up; manual TCP fallback |
| Garmin token expires (~1yr) | Garmin fetch fails | `deploy.sh tokens` from kedar after re-auth |
| Garmin timer stalls / disabled | New activities not imported | `traning doctor` flags it; run `traning fetch garmin` manually |
| HA down | Notifications not delivered (data unaffected) | Garmin timer + FastAPI are independent of HA |
| Tailscale down | HAE can't reach kailash | Data accumulates in HealthKit |
| FastAPI crash | All receiving stopped | systemd `Restart=on-failure` (10s delay) |
| Git conflict kedar↔kailash | Push/pull fails | Append-only files; conflict unlikely in practice |
