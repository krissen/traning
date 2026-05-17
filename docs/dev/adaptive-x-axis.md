# Adaptive x-axis convention

## Problem

Date and datetime x-axes need to stay legible as the displayed span grows.
A 365-day chart at the default `date_breaks = "1 month"` produces ~12 wide
`"%b %Y"` labels; rendered horizontally on a typical panel they overlap.
Per-plot `theme(axis.text.x = element_text(angle = ...))` overrides
patched individual cases but were inconsistent, span-dependent and easy to
forget on new plots.

## Rule

All date / datetime x-axes go through one of:

```r
ggplot2::ggplot(...) +
  ... +
  .adaptive_date_scale(.compute_span_days(from, to))      # Date
ggplot2::ggplot(...) +
  ... +
  .adaptive_datetime_scale(.compute_span_days(from, to))  # POSIXct
```

Both helpers live in `R/plot.R` and read from a single source of truth
`.adaptive_date_spec(span_days)` which picks:

| span                  | breaks      | labels       | rotation |
|-----------------------|-------------|--------------|----------|
| ≤ 14 days             | `1 day`     | `%d %b`      | 45°      |
| ≤ 60 days             | `1 week`    | `%d %b`      | 45°      |
| ≤ 180 days            | `1 month`   | `%b %Y`      | 45°      |
| ≤ 2 years             | `2 months`  | `%b %Y`      | 45°      |
| ≤ 5 years             | `6 months`  | `%b %Y`      | 45°      |
| > 5 years             | `1 year`    | `%Y`         | 0°       |

`guide_axis(check.overlap = TRUE)` is applied on top so that any labels
that would still collide on a narrow panel are dropped. The rotation is
baked into the scale via `guide_axis(angle = ...)`, so callers do **not**
need a separate `theme(axis.text.x = element_text(angle = ...))` override.
Adding one would re-anchor `hjust` and risk fighting the guide.

## Span input

Use `.compute_span_days(from, to, data_dates = ...)` to derive the span.
When `from` or `to` is `NULL` (Allt-presetet), pass the actual date column
as `data_dates` so the span is read from data rather than falling back to
the 365-day default — otherwise a 20-year dataset would pick monthly
breaks and emit `scale_x_date` warnings.

## Documented exceptions

A handful of plots intentionally bypass the helpers because their x-axis
is not a real time span:

- `fetch.plot.heatmap_km` — x is week-of-year integer (1..52); uses
  `scale_x_continuous(breaks = c(1, 13, 26, 39, 52))`.
- `fetch.plot.cumulative_km` — same WoY layout.
- `fetch.plot.distance_pace_era` — x is log10 km, not a date.

None of those should trigger the enforcement test because they don't call
`scale_x_date()` / `scale_x_datetime()` directly. If a future plot legitimately
needs to bypass the helpers, mark it with an inline comment:

```r
# AVVIKELSE FRÅN ADAPTIV X-AXEL: <why this plot can't use the helper>
ggplot2::scale_x_date(date_breaks = "1 day", date_labels = "%H:%M")
```

The marker can be on the line directly above or up to 3 lines above the
`scale_x_*` call.

## Enforcement

`tests/testthat/test-adaptive-scales.R` structurally scans `R/` and `app/`
for `ggplot2::scale_x_date(` / `::scale_x_datetime(` callsites. The test
fails unless each callsite is either

- inside `.adaptive_date_scale()` or `.adaptive_datetime_scale()` (the
  canonical helper definitions in `R/plot.R`), or
- preceded by an `AVVIKELSE FRÅN ADAPTIV X-AXEL` marker.

This catches regressions in future plot additions without relying on
reviewer attention.

## When to revisit

- ggplot2 changes `guide_axis()` semantics (we pin `>= 3.5.0`).
- Add new plot with a non-standard x-axis (sub-daily resolution, etc.) —
  consider extending `.adaptive_date_spec()` rather than bypassing it.
- Wider Shiny layouts where 12 monthly labels would actually fit; the
  current thresholds err on the side of fewer labels.
