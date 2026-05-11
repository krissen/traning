# Tests for R/python_cli.R — the system2 wrapper around `traning`.

test_that(".parse_backfill_counts parses Wrote / Would write lines", {
  lines <- c(
    "  weight_body_mass: Wrote 12 new files",
    "  body_fat_percentage: Would write 0 new files",
    "  lean_body_mass: Wrote 7 new files",
    "Totalt: 19 nya filer"
  )
  counts <- traning:::.parse_backfill_counts(lines)
  expect_named(counts, c("weight_body_mass", "body_fat_percentage",
                          "lean_body_mass"))
  expect_equal(counts[["weight_body_mass"]], 12L)
  expect_equal(counts[["body_fat_percentage"]], 0L)
  expect_equal(counts[["lean_body_mass"]], 7L)
})

test_that(".parse_backfill_counts ignores noise lines", {
  lines <- c(
    "Identified archive as: withings",
    "  weight_body_mass: Wrote 3 new files",
    "Klart! 3 nya filer."
  )
  counts <- traning:::.parse_backfill_counts(lines)
  expect_equal(length(counts), 1L)
  expect_equal(counts[["weight_body_mass"]], 3L)
})

test_that(".parse_backfill_counts handles empty input", {
  expect_equal(length(traning:::.parse_backfill_counts(character(0))), 0L)
})

test_that("traning_cli_path honours TRANING_CLI override", {
  fake_bin <- tempfile("fake_traning_")
  writeLines("#!/bin/sh\necho fake", fake_bin)
  Sys.chmod(fake_bin, "0755")
  on.exit(unlink(fake_bin), add = TRUE)
  withr::with_envvar(c(TRANING_CLI = fake_bin), {
    expect_equal(normalizePath(traning_cli_path()),
                 normalizePath(fake_bin))
  })
})

test_that("traning_backfill returns clean error when CLI is missing", {
  # TRANING_CLI points at a non-existent path, and the bundled venv
  # lookup falls through. The function must surface a structured
  # error rather than crash inside system2().
  withr::with_envvar(c(TRANING_CLI = "/tmp/does-not-exist-xyz"), {
    # Force the bundled-venv lookup to also fail by passing an
    # explicit cli_path = NA_character_; mirrors how a fresh host
    # without the venv installed would behave.
    out <- traning_backfill("/tmp/anything.zip",
                            cli_path = NA_character_)
    expect_false(out$success)
    expect_match(out$stderr, "traning")
  })
})

test_that("traning_backfill rejects missing archive", {
  # Resolve the CLI normally (assumes the dev venv is installed
  # locally) but point it at a non-existent zip — we should never
  # invoke system2 in that case.
  skip_if(is.na(traning_cli_path()),
          "TRANING_CLI / bundled venv not available on this host")
  out <- traning_backfill("/tmp/this-does-not-exist.zip")
  expect_false(out$success)
  expect_match(out$stderr, "does not exist")
})
