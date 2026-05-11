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
  # POSIX-specific: we rely on chmod execute bits + a /bin/sh shebang.
  # The exec-permission check on Windows works differently (file
  # extensions, ACLs) so the helper's resolution path would diverge.
  skip_on_os("windows")
  fake_bin <- tempfile("fake_traning_")
  writeLines("#!/bin/sh\necho fake", fake_bin)
  Sys.chmod(fake_bin, "0755")
  on.exit(unlink(fake_bin), add = TRUE)
  withr::with_envvar(c(TRANING_CLI = fake_bin), {
    expect_equal(normalizePath(traning_cli_path()),
                 normalizePath(fake_bin))
  })
})

test_that("traning_cli_path rejects non-executable TRANING_CLI override", {
  # A regular file at the configured path used to pass `file.exists()`
  # and slip through; system2() would then crash instead of producing
  # the structured error this helper guarantees. The exec check must
  # fall through to the next candidate (here: bundled venv if present,
  # otherwise NA).
  skip_on_os("windows")  # see above re: chmod / exec-bit semantics
  fake_bin <- tempfile("fake_traning_noexec_")
  writeLines("not a real binary", fake_bin)
  # Explicitly strip execute bits in case the platform mounts the
  # tempdir with permissive defaults.
  Sys.chmod(fake_bin, "0644")
  on.exit(unlink(fake_bin), add = TRUE)
  withr::with_envvar(c(TRANING_CLI = fake_bin), {
    out <- traning_cli_path()
    expect_false(identical(normalizePath(out, mustWork = FALSE),
                            normalizePath(fake_bin)))
  })
})

test_that("traning_cli_path rejects a directory at TRANING_CLI", {
  tmp_dir <- tempfile("fake_traning_dir_")
  dir.create(tmp_dir)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  withr::with_envvar(c(TRANING_CLI = tmp_dir), {
    out <- traning_cli_path()
    expect_false(identical(normalizePath(out, mustWork = FALSE),
                            normalizePath(tmp_dir)))
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
  fake_zip <- file.path(tempdir(), "this-does-not-exist.zip")
  out <- traning_backfill(fake_zip)
  expect_false(out$success)
  expect_match(out$stderr, "does not exist")
})

test_that("traning_backfill rejects unusable zip_path inputs", {
  # The wrapper promises a structured envelope; a NULL / empty
  # vector / directory must fall back to that contract rather than
  # crashing inside file.exists() or the CLI.
  skip_if(is.na(traning_cli_path()),
          "TRANING_CLI / bundled venv not available on this host")

  # NULL
  out_null <- traning_backfill(NULL)
  expect_false(out_null$success)
  expect_match(out_null$stderr, "Archive")

  # character(0)
  out_empty <- traning_backfill(character(0))
  expect_false(out_empty$success)

  # vector
  out_vec <- traning_backfill(c("a.zip", "b.zip"))
  expect_false(out_vec$success)

  # directory
  tmp_dir <- tempfile("zip_path_dir_")
  dir.create(tmp_dir)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  out_dir <- traning_backfill(tmp_dir)
  expect_false(out_dir$success)
  expect_match(out_dir$stderr, "regular file|Archive")
})

test_that("traning_backfill flags no_new_dates from CLI no-op line", {
  # The CLI prints "Inga nya datum att backfilla." when nothing
  # needs writing; the wrapper must surface that as a structured
  # flag so the Shiny page can show the right card.
  stdout_lines <- c(
    "Identified archive as: withings",
    "Inga nya datum att backfilla."
  )
  no_new <- any(grepl("Inga nya datum att backfilla",
                       stdout_lines, fixed = TRUE))
  counts <- traning:::.parse_backfill_counts(stdout_lines)
  expect_true(no_new)
  expect_equal(length(counts), 0L)
})
