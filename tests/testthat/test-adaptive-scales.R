# Structural enforcement test for the adaptive x-axis convention.
#
# Date and datetime x-axes in this package MUST go through
# .adaptive_date_scale() / .adaptive_datetime_scale() (see R/plot.R).
# Direct ggplot2::scale_x_date() / ::scale_x_datetime() callsites are
# allowed only:
#   1) inside the helper definitions themselves (whitelisted by
#      enclosing-function detection below), or
#   2) when preceded by a `# AVVIKELSE FRÅN ADAPTIV X-AXEL: <why>` marker
#      (mirrors the AVVIKELSE FRÅN TEMA convention from the visual-theme
#      rollout).
#
# The point of this test is to keep future plot additions on the
# convention even when the reviewer forgets to spot it. If you have a
# legitimate reason to bypass the helpers, mark it with the AVVIKELSE
# comment so the exception is documented.

# Scan the project's R/ and app/ directories for offending callsites.
.scan_for_direct_date_scales <- function(root) {
  # recursive = TRUE on both trees: R packages don't ship subdirectories
  # under R/, but the project also has scripts/ and similar non-package
  # R sources at the top level — covering recursively makes the guard
  # robust against any future reorganisation that places plot code in a
  # subdirectory.
  paths <- c(
    list.files(file.path(root, "R"), pattern = "\\.R$",
               full.names = TRUE, recursive = TRUE),
    list.files(file.path(root, "app"), pattern = "\\.R$",
               full.names = TRUE, recursive = TRUE)
  )

  offenders <- character()

  for (path in paths) {
    lines <- readLines(path, warn = FALSE)
    if (!length(lines)) next

    current_fn <- NULL
    brace_depth <- 0L

    for (i in seq_along(lines)) {
      ln <- lines[[i]]

      # Function entry: capture the assignee. Triggers also on assignments
      # inside theme() etc., but those won't open a brace block at the
      # top level so the brace tracking below stays sane.
      m <- regmatches(ln, regexec("^([a-zA-Z._][a-zA-Z._0-9]*)\\s*<-\\s*function",
                                  ln))[[1]]
      if (length(m) >= 2) {
        current_fn <- m[[2]]
        brace_depth <- 0L
      }

      brace_depth <- brace_depth +
        (nchar(ln) - nchar(gsub("\\{", "", ln, fixed = FALSE)))
      brace_depth <- brace_depth -
        (nchar(ln) - nchar(gsub("\\}", "", ln, fixed = FALSE)))

      if (brace_depth <= 0L) current_fn <- NULL

      # Skip pure comment lines and roxygen docs
      if (grepl("^\\s*#", ln)) next

      # Match both namespace-qualified (`ggplot2::scale_x_date(`) and
      # bare (`scale_x_date(`) forms. The project convention is to
      # namespace-qualify everything, but the guard should catch the
      # bare form too — that's exactly the regression we want to fail
      # on if it ever slips in.
      if (!grepl("(?<![\\w.])(?:ggplot2::)?scale_x_date(?:time)?\\s*\\(",
                 ln, perl = TRUE)) next

      # Allow when inside the canonical helpers
      if (!is.null(current_fn) &&
          current_fn %in% c(".adaptive_date_scale",
                            ".adaptive_datetime_scale")) next

      # Allow when an AVVIKELSE marker sits on (or just above) the line
      ctx <- lines[max(1L, i - 3L):i]
      if (any(grepl("AVVIKELSE FRÅN ADAPTIV X-AXEL", ctx, fixed = TRUE))) next

      offenders <- c(offenders, sprintf("%s:%d", path, i))
    }
  }

  offenders
}

test_that("scale_x_date()/scale_x_datetime() only via adaptive helpers", {
  root <- rprojroot::find_root(rprojroot::has_file("DESCRIPTION"))
  offenders <- .scan_for_direct_date_scales(root)
  if (length(offenders) > 0) {
    cat("\nDirect scale_x_date()/scale_x_datetime() callsites outside\n",
        "the .adaptive_* helpers and without an `AVVIKELSE FRÅN ADAPTIV\n",
        "X-AXEL` marker. Use .adaptive_date_scale() /\n",
        ".adaptive_datetime_scale() in R/plot.R instead.\n",
        "Offenders:\n  ", paste(offenders, collapse = "\n  "), "\n",
        sep = "")
  }
  expect_length(offenders, 0)
})

test_that(".adaptive_date_spec returns expected fields and types", {
  for (span in c(7, 30, 90, 365, 730, 365 * 4, 365 * 10)) {
    spec <- traning:::.adaptive_date_spec(span)
    expect_named(spec, c("labels", "breaks", "angle"))
    expect_type(spec$labels, "character")
    expect_type(spec$breaks, "character")
    expect_type(spec$angle, "double")
    expect_true(spec$angle %in% c(0, 45))
  }
})

test_that(".adaptive_date_spec thresholds avoid over-dense breaks", {
  # 365 days used to fall into "1 month" (12 labels) — now into the
  # 2-month bucket so ~6 labels render.
  expect_equal(traning:::.adaptive_date_spec(365)$breaks, "2 months")
  # The 14-day bucket stays daily.
  expect_equal(traning:::.adaptive_date_spec(7)$breaks,  "1 day")
  # 5-year span = quarterly cadence (was "3 months", now "6 months").
  expect_equal(traning:::.adaptive_date_spec(365 * 5)$breaks, "6 months")
  # Decade+ spans collapse to yearly horizontal labels.
  expect_equal(traning:::.adaptive_date_spec(365 * 10)$angle, 0)
})

test_that(".adaptive_date_scale builds a ScaleContinuousDate with guide", {
  s <- traning:::.adaptive_date_scale(365)
  expect_s3_class(s, "ScaleContinuousDate")
  # The guide should be a guide_axis instance with check.overlap = TRUE.
  expect_s3_class(s$guide, "GuideAxis")
  expect_true(isTRUE(s$guide$params$check.overlap))
})
