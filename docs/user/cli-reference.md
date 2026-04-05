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
| `traning import` | `--import` | Import TCX files into RData cache |
| `traning update` | — | Fetch + import in one step |
| `traning shiny` | — | Launch the tRanat Shiny app |

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
