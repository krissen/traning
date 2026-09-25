# CLI Reference

## Quick start

```bash
# Via Python CLI (recommended):
traning report month               # Current month vs previous years
traning report year --plot          # Year comparison as bar chart
traning report month-top --after 2022  # Top months, only 2022+

# Via R directly:
Rscript inst/cli.R --month-running
Rscript inst/cli.R --year-running --plot --after=2022
```

## Commands

### Reports (table output by default, add `--plot` for chart)

| Command | R flag | Description |
|---------|--------|-------------|
| `traning report month` | `--month-running` | Current month vs same month in previous years (truncated at today's day) |
| `traning report month-this` | `--month-this` | Individual runs this month with totals |
| `traning report month-last` | `--month-last` | Last month compared across years |
| `traning report month-top` | `--month-top` | Top 10 months by total distance |
| `traning report year` | `--year-running` | Year-to-date vs previous years (truncated at today's day-of-year) |
| `traning report top` | `--year-top` | Full-year totals across all years |
| `traning report pace` | `--total-pace` | Mean pace per year |
| `traning datesum` | `--datesum` | Summary for a date range |

### Plots (always chart output)

| Command | R flag | Description |
|---------|--------|-------------|
| `traning ef` | `--ef` | Efficiency Factor (pace per heartbeat) trend |
| `traning acwr` | `--acwr` | Acute:Chronic Workload Ratio (injury risk) |
| `traning monotony` | `--monotony` | Training Monotony & Strain |

### Data management

| Command | R flag | Description |
|---------|--------|-------------|
| `traning fetch` | — | Fetch new activities from Garmin Connect |
| `traning import garmin` | `--import` | Import Garmin TCX files into RData cache |
| `traning import health` | `--import-health` | Import HAE health data (JSON) into RData cache |
| `traning import canonical <path>...` | — | Merge HAE metric JSON files (or a directory of them) into canonical/. `--replace-source-days` lets the input replace existing samples for the (metric, date, source) it covers; `--dry-run` lists what would be displaced |
| `traning import all` | — | Import everything (Garmin + Health) |
| `traning backfill <zip>` | — | Backfill canonical metrics from export archive (Withings, etc.) |
| `traning update` | — | Fetch + import in one step |
| `traning dedup` | `--dedup` | List Apple Watch sessions that duplicate a Garmin recording. Reports only; add `--apply` to remove them |
| `traning shiny` | — | Launch the tRanat Shiny app |

### Device log

Firmware and watch changes can shift how metrics (HR, cadence, ...) are
computed, so `$TRANING_DATA/kristian/devices.csv` keeps a dated record of
which device/OS version was active when. Columns: `valid_from` (date the
change took effect), `platform` (`apple_watch` | `garmin`), `model`,
`os_version`, `certainty` (`exact` — derived from data — or
`known_since` — a manual, possibly-approximate date), `origin`
(`manual` | `fit` | `tcx` | `healthkit`), `note`. Newest change first.

**Invariant: at most one row per `(platform, valid_from)`.** The file
only carries a date, never a time, so two real changes on the same
calendar day (e.g. a watch arriving with one firmware version and
updating itself to another hours later) can't be told apart as two
rows — that row describes the day's actual end-of-day state (the
latest model/version reached that day); an earlier version reached the
same day is named in `note` instead (`"samma dag: <version>"`).
`certainty`/`origin` describe the surviving row. Every write path
(`device add`, `device scan --apply`) enforces this automatically, and
collapses any pre-existing same-day duplicates in the file too — no
separate cleanup step needed after upgrading.

| Command | Description |
|---------|-------------|
| `traning device list` | Print devices.csv, newest first |
| `traning device add --platform ... --model ... --os-version ...` | Log a manual device/OS change. `--from DATE` (default today), `--certainty` (default `known_since`), `--note` |
| `traning device scan [--source fit\|tcx\|healthkit\|all] [--healthkit-export PATH] [--apply]` | Derive device-change candidates from the historical FIT/TCX archives and an Apple Health export, merged so the same real change isn't double-counted. Dry-run by default; `--apply` writes the new rows |

**New Garmin changes are logged automatically**: every `traning fetch
garmin` run reads the freshly downloaded TCX's device info and adds a
row if it's new — no manual step needed.

**Garmin dates are local days.** A change is dated by the wall-clock
day where the activity happened: Garmin's `startTimeLocal` first, then
the FIT activity's `local_timestamp` when present, otherwise the
activity start converted to Europe/Stockholm time. (The Apple Watch
scan already dates by local day, via the export's `creationDate`.) A
change first seen just after local midnight no longer lands on the
previous day.

**Concurrent writes take turns.** The timer fetch, a manual fetch or
`device add`, and `device scan --apply` can all write at once; they
serialize on an exclusive lock (`devices.csv.lock` next to
`devices.csv`, never committed) instead of silently dropping each
other's rows. A scan `--apply` also rewrites a log that predates the
one-row-per-day rule above and reports it (`Städade N dag(ar) med
dubbletter`); the post-fetch hook never fails a fetch over the lock —
it logs a warning instead.

**Apple Watch history comes from a manual Health app export.** Health
Auto Export's live feed (the one `traning fetch health` runs on) only
ever sends `sourceName`, no device identifier, so it can't drive this
the way the Garmin fetch does. A full export from the iPhone Health
app (profile icon -> Export All Health Data -> a zip containing
`apple_health_export/export.xml`) carries a `device` attribute per
record with the watch's hardware identifier and firmware version.

The export lives **outside the data repo entirely**, unpacked, on
kailash: `$TRANING_HEALTHKIT_EXPORTS/<YYYY-MM-DD>/apple_health_export/export.xml`
(one dated directory per export; restic backs up that tree and dedups
well against the mostly-unchanged bulk of an unpacked export between
runs — a zip wouldn't dedup at all). `$TRANING_HEALTHKIT_EXPORTS` is
set in kailash's server env
(`python/traning_cli/server/deploy/traning-env.example`); it isn't
part of `$TRANING_DATA` and has no dev-machine default. Drop a new
export in its own `<YYYY-MM-DD>/` directory (unpacked, or as the zip
straight off the phone — either is fine) and run `traning device scan
--source healthkit --apply` (or just `--source all`, which skips this
source silently if nothing is found). `--healthkit-export PATH`
overrides the default newest-dated-directory lookup, and accepts a
zip, a bare `export.xml`, or a directory containing either — useful
for scanning a fresh export before it's been filed into the dated
tree. Absent any export, log a change by hand with `traning device add
--platform apple_watch ...` instead.

## Date range filtering

All report and plot commands accept date range flags.

### Flags

| Flag | Description |
|------|-------------|
| `--after EXPR` | Start of range (inclusive) |
| `--before EXPR` | End of range (exclusive) |
| `--span DURATION` | Length from `--after` point (alternative to `--before`) |

`--before` and `--span` are mutually exclusive. `--span` requires `--after`.

### Date expressions

| Format | Example | Meaning |
|--------|---------|---------|
| `YYYY` | `2023` | 2023-01-01 |
| `YYYY-MM` | `2023-03` | 2023-03-01 |
| `YYYY-MM-DD` | `2023-03-04` | Exact date |
| `-Nd` | `-10d` | 10 days ago |
| `-Nw` | `-3w` | 3 weeks ago |
| `-Nm` | `-6m` | 6 months ago |
| `-Ny` | `-1y` | 1 year ago |

Span expressions (for `--span` only) use the same units without minus:
`3m`, `1y`, `6w`, `30d`.

### Examples

```bash
# Everything from 2022 onwards
traning report month --after 2022

# Last 3 years
traning report year --after -3y

# Specific period
traning report top --after 2023 --before 2025

# 3-month window starting 1 year ago
traning datesum --after -1y --span 3m

# Last 6 months as a chart
traning datesum --after -6m --plot

# All-time pace trend, filtered to 2020+
traning report pace --after 2020 --plot
```

### Direct R CLI with relative dates

When using `Rscript inst/cli.R` directly, relative date expressions
(starting with `-`) must use `=` syntax to avoid optparse confusion:

```bash
# This works:
Rscript inst/cli.R --year-running --after="-3y"

# This does NOT work (optparse misinterprets -3y as a flag):
Rscript inst/cli.R --year-running --after -3y
```

The Python CLI (`traning`) handles this automatically.

## Plot mode

Add `--plot` to any report command to get a chart instead of a table:

```bash
traning report month --plot              # Bar chart
traning report month-top --plot          # Horizontal bar chart
traning report month-this --plot         # Lollipop chart (runs by day, colored by pace)
traning report year --plot --after 2020  # Bar chart, filtered
```

### Plot types per command

| Command | Table columns | Plot type |
|---------|--------------|-----------|
| `report month` | Year, Km/day, Total km, Max km, Pace, Runs | Bar chart by year |
| `report month-this` | Day, Km, Pace, HR | Lollipop (day vs km, color = pace) |
| `report month-last` | Year, Km/day, Total km, Max km, Pace, Runs | Bar chart by year |
| `report month-top` | Year-month, Total km, Max km, Pace, Runs | Horizontal bar, color by year |
| `report year` | Year, Km/day, Total km, Max km, Pace, Runs | Bar chart by year |
| `report top` | Year, Km/day, Total km, Max km, Pace, Runs | Bar chart by year |
| `report pace` | Year, Duration, Mean pace, Min pace | Scatter + loess trend |
| `datesum` | Totals (1 row) | Auto-aggregated bars (daily/weekly/monthly) |

## Legacy date format

The old `traning datesum YYYY-MM-DD--YYYY-MM-DD` format still works:

```bash
traning datesum 2024-01-01--2024-06-30        # table
traning datesum 2024-01-01--2024-06-30 --plot  # chart
```
