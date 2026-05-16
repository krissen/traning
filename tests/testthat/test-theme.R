# Tests for R/theme.R — palette, theme_traning(), and scales.

# --- traning_palette --------------------------------------------------------

test_that("traning_palette has expected top-level keys", {
  expect_true(exists("traning_palette"))
  expected <- c(
    "accent", "primary", "secondary", "accent_warm", "border_warm",
    "bg_card", "text_dark", "status", "zones", "traffic", "traffic_bg",
    "readiness_bg", "sleep_stages", "seasons", "run_profile",
    "duration_rank", "sequence"
  )
  expect_true(all(expected %in% names(traning_palette)))
})

test_that("traning_palette CSS-mirrored vars match styles.css", {
  # These hex values are duplicated from app/tRanat/www/styles.css. If
  # CSS changes, both files must be updated in the same commit.
  expect_identical(traning_palette$primary, "#3e2723")
  expect_identical(traning_palette$secondary, "#6d4c41")
  expect_identical(traning_palette$accent, "#8d6e63")
  expect_identical(traning_palette$accent_warm, "#c8a882")
  expect_identical(unname(traning_palette$status["green"]), "#5a8a5a")
  expect_identical(unname(traning_palette$status["yellow"]), "#b8963a")
  expect_identical(unname(traning_palette$status["red"]), "#a85a4a")
  expect_identical(unname(traning_palette$status["blue"]), "#5a7a9a")
})

test_that("traning_palette hex values are well-formed", {
  hex_ok <- function(x) grepl("^#[0-9a-fA-F]{6}$", x)
  flat <- unlist(traning_palette, recursive = TRUE, use.names = FALSE)
  expect_true(all(hex_ok(flat)),
    info = paste("invalid:", paste(flat[!hex_ok(flat)], collapse = ", ")))
})

test_that("traning_palette$status carries exactly the four CSS status keys", {
  expect_setequal(names(traning_palette$status),
                  c("green", "yellow", "red", "blue"))
})

test_that("traning_palette$zones covers Z1..Z5", {
  expect_setequal(names(traning_palette$zones),
                  paste0("Z", 1:5))
})

test_that("traning_palette$seasons covers four seasons", {
  expect_setequal(names(traning_palette$seasons),
                  c("winter", "spring", "summer", "autumn"))
})

test_that("traning_palette$run_profile has current/history pair", {
  expect_true("current" %in% names(traning_palette$run_profile))
  expect_true("history" %in% names(traning_palette$run_profile))
})

# --- theme_traning ----------------------------------------------------------

test_that("theme_traning() returns a ggplot theme", {
  th <- theme_traning()
  expect_s3_class(th, "theme")
  expect_true(inherits(th, "gg"))
})

test_that("theme_traning(rotated_x = TRUE) adds rotated x axis", {
  th <- theme_traning(rotated_x = TRUE)
  expect_s3_class(th, "theme")
  # axis.text.x should be an element_text with a non-zero angle
  ax <- th$axis.text.x
  expect_true(!is.null(ax))
  expect_equal(ax$angle, 45)
})

test_that("theme_traning() applies to a real ggplot without error", {
  df <- data.frame(x = 1:3, y = 1:3, g = letters[1:3])
  p <- ggplot2::ggplot(df, ggplot2::aes(x, y, fill = g)) +
    ggplot2::geom_col() +
    theme_traning()
  expect_silent(ggplot2::ggplot_build(p))
})

# --- scale_fill_traning / scale_colour_traning -----------------------------

test_that("scale_fill_traning() returns a ggplot scale", {
  sc <- scale_fill_traning()
  expect_true(inherits(sc, "Scale") || inherits(sc, "ScaleDiscrete") ||
              inherits(sc, "ggproto"))
})

test_that("scale_colour_traning() returns a ggplot scale", {
  sc <- scale_colour_traning()
  expect_true(inherits(sc, "Scale") || inherits(sc, "ScaleDiscrete") ||
              inherits(sc, "ggproto"))
})

test_that("scale_fill_traning() can be applied to a real ggplot", {
  df <- data.frame(x = 1:5, y = 1:5, g = letters[1:5])
  p <- ggplot2::ggplot(df, ggplot2::aes(x, y, fill = g)) +
    ggplot2::geom_col() +
    scale_fill_traning()
  expect_silent(ggplot2::ggplot_build(p))
})

test_that("scale_fill_traning() interpolates past the 5 anchor colours", {
  df <- data.frame(x = 1:8, y = 1:8, g = letters[1:8])
  p <- ggplot2::ggplot(df, ggplot2::aes(x, y, fill = g)) +
    ggplot2::geom_col() +
    scale_fill_traning()
  built <- ggplot2::ggplot_build(p)
  fills <- unique(built$data[[1]]$fill)
  expect_length(fills, 8)
  expect_true(all(grepl("^#[0-9a-fA-F]{6}$", fills)))
})

test_that("scale_colour_traning() interpolates past the 5 anchor colours", {
  df <- data.frame(x = 1:7, y = 1:7, g = letters[1:7])
  p <- ggplot2::ggplot(df, ggplot2::aes(x, y, colour = g)) +
    ggplot2::geom_point() +
    scale_colour_traning()
  expect_silent(ggplot2::ggplot_build(p))
})

# --- back-compat wrappers ---------------------------------------------------

test_that(".theme_run_profile() and .theme_rotated_x() still work", {
  expect_s3_class(traning:::.theme_run_profile(), "theme")
  expect_s3_class(traning:::.theme_rotated_x(), "theme")
})
