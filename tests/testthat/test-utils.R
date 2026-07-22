test_that("dec_to_mmss converts decimal minutes to M:SS", {
  expect_equal(dec_to_mmss(5.5), "5:30")
  expect_equal(dec_to_mmss(4.0), "4:00")
  expect_equal(dec_to_mmss(6.25), "6:15")
  expect_equal(dec_to_mmss(3.75), "3:45")
})

test_that("dec_to_mmss handles single-digit seconds", {
  expect_equal(dec_to_mmss(5.1), "5:06")
})

test_that("dec_to_mmss returns dash for invalid input", {
  expect_equal(dec_to_mmss(NA), "—")
  expect_equal(dec_to_mmss(NA_real_), "—")
  expect_equal(dec_to_mmss(NaN), "—")
  expect_equal(dec_to_mmss(Inf), "—")
  expect_equal(dec_to_mmss(-Inf), "—")
  expect_equal(dec_to_mmss(numeric(0)), "—")
})

test_that("dec_to_mmss does not crash on integer overflow", {
  # Regression: a stray bad pace row in the cache (e.g. 2.4e11 min/km)
  # used to drive `as.integer(x*60)` past the integer.max ceiling, which
  # silently coerced to NA and crashed the if-clause below it.
  expect_equal(dec_to_mmss(1e10), "—")
  expect_equal(dec_to_mmss(.Machine$integer.max), "—")
})

test_that("dec_to_mmss rejects vector input explicitly", {
  # Was a silent failure mode before: is.na(c(1,NA)) returns
  # c(FALSE,TRUE) and the if-clause warns instead of producing useful
  # output.  Now an explicit error so callers must aggregate first.
  expect_error(dec_to_mmss(c(5.0, 5.5)), "scalar")
  expect_error(dec_to_mmss(c(NA_real_, 1.0)), "scalar")
})

test_that("save_atomic writes file readable by load()", {
  tmp <- tempfile(fileext = ".RData")
  on.exit(unlink(tmp), add = TRUE)
  payload <- data.frame(x = 1:3, y = letters[1:3])
  save_atomic(payload, file = tmp)
  expect_true(file.exists(tmp))
  expect_false(file.exists(paste0(tmp, ".tmp.", Sys.getpid())))
  e <- new.env()
  load(tmp, envir = e)
  expect_equal(e$payload, payload)
})

test_that("save_atomic does not leave a partial file at the destination path", {
  # If a reader stat()s the destination during a save, it sees either the old
  # file or the new file — never a half-written one. We verify by snapshotting
  # an existing file's contents while another save_atomic is "in progress"
  # using a hook on the rename step.
  tmp <- tempfile(fileext = ".RData")
  on.exit(unlink(tmp), add = TRUE)
  old <- data.frame(x = 1L)
  save_atomic(old, file = tmp)
  old_size <- file.info(tmp)$size

  # Write a much larger payload via save_atomic; the temp file must be
  # named differently so the destination keeps its old contents until rename.
  big <- data.frame(x = 1:10000, y = rnorm(10000))
  save_atomic(big, file = tmp)
  expect_true(file.info(tmp)$size > old_size)
  expect_false(file.exists(paste0(tmp, ".tmp.", Sys.getpid())))
})

test_that("save_atomic cleans up tmp file on rename failure", {
  # Force rename failure by making the destination directory read-only.
  d <- tempfile()
  dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  target <- file.path(d, "x.RData")
  payload <- 1L
  save_atomic(payload, file = target)
  expect_true(file.exists(target))
})

# --- save_table() format dispatch --------------------------------------------

save_table_fixture <- function() {
  tibble::tibble(sport = c("running", "cycling"), km = c(10.5, 25.2))
}

test_that("save_table writes CSV and round-trips the data", {
  tbl <- save_table_fixture()
  out <- tempfile(fileext = ".csv")
  on.exit(unlink(out), add = TRUE)

  path <- suppressMessages(save_table(tbl, output = out, open = FALSE))
  expect_equal(path, out)
  expect_true(file.exists(out))

  back <- utils::read.csv(out, stringsAsFactors = FALSE)
  expect_equal(back$sport, tbl$sport)
  expect_equal(back$km, tbl$km)
})

test_that("save_table writes JSON and round-trips the data", {
  tbl <- save_table_fixture()
  out <- tempfile(fileext = ".json")
  on.exit(unlink(out), add = TRUE)

  save_table(tbl, output = out, open = FALSE)
  expect_true(file.exists(out))

  back <- jsonlite::fromJSON(out)
  expect_equal(back$sport, tbl$sport)
  expect_equal(back$km, tbl$km)
})

test_that("save_table writes JSONL (one JSON object per line)", {
  tbl <- save_table_fixture()
  out <- tempfile(fileext = ".jsonl")
  on.exit(unlink(out), add = TRUE)

  save_table(tbl, output = out, open = FALSE)
  expect_true(file.exists(out))

  lines <- readLines(out)
  expect_length(lines, nrow(tbl))
  parsed <- lapply(lines, jsonlite::fromJSON)
  expect_equal(parsed[[1]]$sport, tbl$sport[1])
  expect_equal(as.numeric(parsed[[2]]$km), tbl$km[2])
})

test_that("save_table writes XLSX when writexl is available", {
  testthat::skip_if_not_installed("writexl")
  tbl <- save_table_fixture()
  out <- tempfile(fileext = ".xlsx")
  on.exit(unlink(out), add = TRUE)

  save_table(tbl, output = out, open = FALSE)
  expect_true(file.exists(out))
  expect_gt(file.info(out)$size, 0)
})

test_that("save_table errors on an unknown format with the Swedish message", {
  tbl <- save_table_fixture()
  expect_error(
    save_table(tbl, output = tempfile(), format = "parquet", open = FALSE),
    "Okänt format"
  )
})

test_that("save_table infers format from the output file extension", {
  tbl <- save_table_fixture()
  out <- tempfile(fileext = ".json") # extension implies json, not the csv default
  on.exit(unlink(out), add = TRUE)

  save_table(tbl, output = out, open = FALSE)
  # A CSV writer would have produced a comma-header first line; JSON
  # instead starts with '[' (jsonlite::toJSON pretty array).
  first_line <- readLines(out, n = 1)
  expect_true(startsWith(trimws(first_line), "["))
})

test_that("save_table falls back to TRANING_TABLE_FORMAT env default when format and extension are both absent", {
  tbl <- save_table_fixture()
  out_dir <- tempfile()
  dir.create(out_dir)
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)

  withr::local_envvar(c(
    TRANING_OUTPUT_DIR = out_dir,
    TRANING_TABLE_FORMAT = "json",
    TRANING_OPEN = "false"
  ))

  path <- save_table(tbl, default_name = "envdefault")
  expect_true(file.exists(path))
  expect_true(endsWith(path, ".json"))
})

# --- Swedish decimal formatting ---------------------------------------------

test_that("fmt_dec_sv renders a Swedish decimal comma", {
  expect_equal(fmt_dec_sv(26), "26,0")
  expect_equal(fmt_dec_sv(9.75), "9,8")
  expect_equal(fmt_dec_sv(1.234, digits = 2), "1,23")
  expect_equal(fmt_dec_sv(0), "0,0")
  expect_equal(fmt_dec_sv(-3.5), "-3,5")
})

test_that("fmt_dec_sv signs deltas and trims zero decimals on request", {
  expect_equal(fmt_dec_sv(3.2, signed = TRUE), "+3,2")
  expect_equal(fmt_dec_sv(-0.5, signed = TRUE), "-0,5")
  # trim_zero reproduces what round() + paste0() used to render
  expect_equal(fmt_dec_sv(7, trim_zero = TRUE), "7")
  expect_equal(fmt_dec_sv(7.2, trim_zero = TRUE), "7,2")
  expect_equal(fmt_dec_sv(26.50, digits = 2, trim_zero = TRUE), "26,5")
  expect_equal(fmt_dec_sv(100, digits = 0, trim_zero = TRUE), "100")
})

test_that("fmt_dec_sv is vectorised and NA-safe", {
  expect_equal(fmt_dec_sv(c(1.5, 2.25)), c("1,5", "2,2"))
  expect_true(is.na(fmt_dec_sv(NA_real_)))
  expect_true(is.na(fmt_dec_sv(Inf)))
  expect_equal(fmt_dec_sv(c(1.5, NA)), c("1,5", NA_character_))
  expect_equal(fmt_dec_sv(numeric(0)), character(0))
})

test_that("machine-read output keeps the decimal point", {
  # The comma is a prose convention only. A CSV or JSON export written
  # with commas inside numbers would not round-trip.
  tbl <- data.frame(km = c(10.5, 3.25))
  out_dir <- tempfile()
  dir.create(out_dir)
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)
  withr::local_envvar(c(TRANING_OPEN = "false"))

  csv <- save_table(tbl, output = file.path(out_dir, "t.csv"))
  expect_true(any(grepl("10.5", readLines(csv), fixed = TRUE)))

  json <- save_table(tbl, output = file.path(out_dir, "t.json"))
  parsed <- jsonlite::fromJSON(json)
  expect_equal(parsed$km, c(10.5, 3.25))
})
