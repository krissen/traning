# Unified visual theme — figures and tables

> **Status: delivered (2026-05-16).** This design has been implemented.
> `R/theme.R` now provides `traning_palette`, `theme_traning()`, and
> `scale_fill_traning()` / `scale_colour_traning()`; the hardcoded blues
> (`steelblue`, `firebrick`, `#7BA7C9`, `#4682B4`) are gone from `R/plot.R`,
> `R/plot_reports.R`, and `R/plot_health.R`. See the changelog entry
> "Enhetligt visuellt tema över alla plottar" (2026-05-16) for the shipped
> scope. The text below is retained as the original design rationale and
> describes the pre-migration state; line and callsite references point at
> the code as it looked before the migration.

## Problem

Plot output across the project mixes a deliberate brown/warm palette with
default-ggplot blues. The Shiny app has a complete theme defined as CSS custom
properties in `app/tRanat/www/styles.css` (`--primary: #3e2723`,
`--accent: #8d6e63`, `--accent-warm: #c8a882`, `--status-{green,yellow,red,blue}`),
but R plot functions don't know about it. Local palettes (`zon_farger`,
`palette_traffic`, `stage_colours`) are well chosen but live inside individual
plot files. Hardcoded `steelblue`, `firebrick`, `#7BA7C9`, `#4682B4` are
sprinkled across `R/plot.R` and `R/plot_reports.R`. There is no
`theme_traning()` and no shared palette object.

Concrete contrast that anchors the problem:

- **On-theme.** First-page weekly volume in Shiny —
  `geom_col(fill = "#8d6e63")` in `app/tRanat/modules/mod_overview.R:184`.
  Brown, matches CSS — but only by coincidence (hex copied by hand).
- **Off-theme.** "Förra månaden" under Utveckling — `fill = "#7BA7C9"` in
  `R/plot_reports.R:165` (`plot_monthlast`). Reads as default ggplot.

The same audit applies to tables, but `DT::datatable` already inherits styling
from `styles.css`, so the table side is expected to be a smaller verification
job rather than a migration.

## Goal

One visual language across Shiny, CLI-rendered PNGs, and all reports. Two
non-negotiables:

1. **Single source of truth for colour.** A palette object in R that is
   manually kept in sync with the CSS custom properties (CSS remains the
   authority for UI chrome; R mirrors it for plots).
2. **Documented exceptions.** Plots that intentionally diverge from the
   palette (status semantics, traffic-light readiness colours) carry an
   in-code comment explaining why. No silent off-theme defaults.

Subgoals: DRY (one palette, one theme function, one set of scales), KISS
(no theme inheritance pyramid), and discoverability (a developer who adds a
new plot finds `theme_traning()` immediately and reuses it).

## Design

### `R/theme.R` — new module

Exports:

- **`traning_palette`** — named list mirroring the CSS custom properties.
  Sub-lists for the cases where a single colour isn't enough:
  - `traning_palette$accent` (single brown for solo bars)
  - `traning_palette$status` (`green`, `yellow`, `red`, `blue` for semantic
    use; matches `--status-*` in CSS)
  - `traning_palette$zones` — replaces `zon_farger` (HR-zone palette currently
    in `R/plot_zones.R`)
  - `traning_palette$traffic` — replaces `palette_traffic` (currently in
    `R/plot.R`)
  - `traning_palette$sleep_stages` — replaces `stage_colours` (currently in
    `R/plot.R`)
  - `traning_palette$sequence` — ordered categorical palette for stacked /
    grouped bars (warm browns + warm accents, stays on-theme)
- **`theme_traning()`** — ggplot theme. Built on `theme_minimal()`. Folds in
  what `.theme_run_profile()` and `.theme_rotated_x()` currently provide
  (those helpers get deprecated and re-exported as thin wrappers during
  migration, then removed when no callers remain).
- **`scale_fill_traning()`** / **`scale_colour_traning()`** — discrete
  scales backed by `traning_palette$sequence`. Continuous variants only if a
  caller actually needs them (don't pre-build).

The palette file carries a header comment that names `app/tRanat/www/styles.css`
as the source of truth and lists each `--var: #hex` mapping inline. Any change
to the CSS variables must be reflected here in the same commit; a TODO note
covers whether a build-time check is worth adding later.

### Migration plan for plots

In rough order of visibility:

| File | Callsite | Current | After |
|---|---|---|---|
| `R/plot_reports.R` | `.plot_year_bars` default | `"steelblue"` | `traning_palette$accent` |
| `R/plot_reports.R` | `plot_monthlast` | `"#7BA7C9"` | `traning_palette$accent` |
| `R/plot_reports.R` | `plot_yearstop` | `"#8E5A33"` | `traning_palette$accent` (canonical brown) |
| `R/plot_reports.R:145` | bar fill | `"#4682B4"` | `traning_palette$accent` |
| `R/plot_reports.R:239` | bar fill | `"steelblue"` | `traning_palette$accent` |
| `R/plot.R` | ~10 sites | `steelblue` / `firebrick` | palette colour or documented exception |
| `R/plot_zones.R` | `zon_farger` | local list | reference `traning_palette$zones` |
| `R/plot.R` | `palette_traffic` | local | reference `traning_palette$traffic` |
| `R/plot.R` | `stage_colours` | local | reference `traning_palette$sleep_stages` |
| `R/plot_health.R` | `c("ATL"="tomato","CTL"="steelblue")` | hardcoded | palette pair |
| `R/plot_multisport.R` | `.theme_rotated_x()` | local theme | `theme_traning()` |
| `app/tRanat/modules/mod_overview.R:184` | `fill = "#8d6e63"` | hex copy | `traning_palette$accent` |

Other plot modules (`plot_health.R`, `plot_multisport.R`, `plot_zones.R`)
already use bespoke palettes — they get re-pointed at `traning_palette` but
keep their visual output. Same pixels, single source.

### Migration plan for tables

Smaller scope. Steps:

1. Grep `app/` and `R/` for `DT::datatable`, `kable`, `gt`, raw `<table>`.
2. Confirm each callsite is unstyled at the R level and inherits from
   `styles.css`.
3. Move any inline `style = ...` colours into CSS variables.
4. If `DT` callbacks set row colours by status (e.g. tier highlights),
   route them through `traning_palette$status` rendered as inline style.

No new table abstraction is introduced unless step 1–4 surfaces real
duplication.

### Exception convention

When a plot must diverge from the palette (semantic colour, brand alignment,
existing scientific convention), the diverging line carries a brief comment:

```r
# AVVIKELSE FRÅN TEMA: traffic-light semantics (green/yellow/red) signal
# readiness state, not aesthetics. Keep fixed hex.
fill = c("#27ae60", "#f1c40f", "#e74c3c")
```

Reviewer rule of thumb: if a hex literal lives in plot code without an
`AVVIKELSE FRÅN TEMA` comment above it, that's a bug.

## Verification

End-to-end visual smoke test, run after the migration commit:

1. **CLI render.** Generate every plot the CLI knows about into a temp dir:
   `traning report month --plot`, `--year --plot`, `--month-top --plot`,
   `--year-top --plot`, `--zones --plot`, `--datesum --plot`,
   `--acwr --plot`, `--pmc --plot`, `--decoupling --plot`,
   `--ef --plot`, `--hre --plot`, `--vo2max --plot`, `--sleep --plot`,
   `--resting-hr --plot`, `--hrv --plot`. (Exact list confirmed against
   `inst/cli.R` at implementation time.)
2. **Shiny walkthrough.** Start the app locally and scroll every page:
   `page_overview`, `page_health`, `page_performance`, `page_progress`,
   `page_race`, `page_runprofile`, `page_sport_mix`, `page_training`,
   `page_import`. Visit each tab in `mod_metric_panel` and `mod_date_preset`.
3. **Ocular check.** No plot may show "default ggplot blue" unless an
   `AVVIKELSE FRÅN TEMA` comment justifies it. Tables follow CSS theme.
4. **Snapshot tests.** If `vdiffr` is available, capture baselines in the
   migration PR. If not, add it as a dependency only if the reviewer-burden
   case is clear.

A follow-up commit adds a `traning render-all` CLI subcommand that performs
step 1 automatically — useful for future regressions, optional for the
initial migration.

## Scope notes

- Implementation was delivered in a separate PR (2026-05-16). This document
  originally described the target state; it is now the historical design record.
- `R/theme.R` is the only new file required. Everything else is editing.
- No data layer, model, or pipeline changes. Pure presentation.
- Backwards compatibility is not a concern (single user, no API surface).
