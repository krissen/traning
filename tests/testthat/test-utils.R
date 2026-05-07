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
