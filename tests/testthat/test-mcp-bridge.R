# Tests for inst/mcp_bridge.R — the R-side MCP bridge

# Helper: run mcp_bridge.R and parse JSON output
run_bridge <- function(func, args = "{}", plot = FALSE) {
  bridge <- file.path(testthat::test_path("..", ".."), "inst", "mcp_bridge.R")
  cmd_args <- c(bridge, paste0("--func=", func), paste0("--args=", shQuote(args)))
  if (plot) cmd_args <- c(cmd_args, "--plot")
  result <- system2("Rscript", args = cmd_args, stdout = TRUE, stderr = NULL)
  jsonlite::fromJSON(paste(result, collapse = "\n"), simplifyVector = FALSE)
}

# --- Function whitelist ---

test_that("unknown function returns error", {
  out <- run_bridge("nonexistent_function")
  expect_equal(out$type, "error")
  expect_match(out$message, "Unknown")
})

test_that("NULL function returns error", {
  bridge <- file.path(testthat::test_path("..", ".."), "inst", "mcp_bridge.R")
  result <- system2("Rscript", args = c(bridge, paste0("--args=", shQuote("{}"))),
                    stdout = TRUE, stderr = NULL)
  out <- jsonlite::fromJSON(paste(result, collapse = "\n"), simplifyVector = FALSE)
  expect_equal(out$type, "error")
})

# --- Data mode ---

test_that("report_monthstatus returns data JSON", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("report_monthstatus", '{"n":2}')
  expect_equal(out$type, "data")
  expect_true(out$rows >= 0)
  expect_true(is.list(out$data))
})

test_that("report_yearstop returns data JSON", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("report_yearstop", '{"n":3}')
  expect_equal(out$type, "data")
  expect_true(out$rows > 0)
})

test_that("report_readiness returns data JSON", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("report_readiness", '{"n":3}')
  expect_equal(out$type, "data")
  expect_true(out$rows > 0)
  # Check expected columns
  first_row <- out$data[[1]]
  expect_true("Datum" %in% names(first_row))
  expect_true("Beredskap" %in% names(first_row))
  expect_true("Status" %in% names(first_row))
})

test_that("report_ef returns data JSON", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("report_ef", '{"n":5}')
  expect_equal(out$type, "data")
  expect_true(out$rows > 0)
})

# --- Date range filtering ---

test_that("from/to date filtering works", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("report_monthtop", '{"from":"2024-01-01","to":"2025-01-01","n":3}')
  expect_equal(out$type, "data")
  expect_true(out$rows <= 3)
})

# --- Plot mode ---

test_that("plot mode returns plot JSON with path", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("fetch.plot.ef", '{"from":"2025-01-01"}', plot = TRUE)
  expect_equal(out$type, "plot")
  expect_true(nchar(out$path) > 0)
  expect_match(out$path, "\\.png$")
})

test_that("plot mode with health data works", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("fetch.plot.sleep", '{}', plot = TRUE)
  expect_equal(out$type, "plot")
  expect_true(nchar(out$path) > 0)
  expect_match(out$path, "\\.png$")
})

# --- Args passing ---

test_that("empty args object is valid", {
  skip_if(Sys.getenv("TRANING_DATA") == "", "TRANING_DATA not set")
  out <- run_bridge("report_monthstatus")
  expect_equal(out$type, "data")
})

test_that("invalid JSON args handled gracefully", {
  bridge <- file.path(testthat::test_path("..", ".."), "inst", "mcp_bridge.R")
  rc <- system2("Rscript", args = c(bridge, "--func=report_monthstatus",
                                     "--args=not-json"),
                stdout = FALSE, stderr = NULL)
  # Should exit non-zero
  expect_true(rc != 0)
})
