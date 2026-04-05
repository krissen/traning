# Shared utility functions

# --- Output defaults from environment ----------------------------------------

#' Read output defaults from environment variables
#'
#' Reads \code{TRANING_OUTPUT_DIR}, \code{TRANING_PLOT_FORMAT},
#' \code{TRANING_TABLE_FORMAT}, and \code{TRANING_OPEN} from the environment.
#' These can be set in \code{.Renviron}.
#'
#' @return A list with elements: \code{output_dir}, \code{plot_format},
#'   \code{table_format}, \code{open}.
#' @export
get_output_defaults <- function() {
  traning_data <- Sys.getenv("TRANING_DATA", "")
  list(
    output_dir   = Sys.getenv("TRANING_OUTPUT_DIR",
                              file.path(traning_data, "output")),
    plot_format  = Sys.getenv("TRANING_PLOT_FORMAT", "pdf"),
    table_format = Sys.getenv("TRANING_TABLE_FORMAT", "csv"),
    open         = tolower(Sys.getenv("TRANING_OPEN", "true")) %in%
                     c("true", "1", "yes")
  )
}

# --- File opening ------------------------------------------------------------

#' Open a file with the system default application
#' @param path Character. File path.
#' @export
open_file <- function(path) {
  sys <- Sys.info()[["sysname"]]
  cmd <- switch(sys,
    Darwin  = "open",
    Linux   = "xdg-open",
    Windows = "start",
    "open"
  )
  system2(cmd, shQuote(path), wait = FALSE)
}

# --- Plot output -------------------------------------------------------------

#' Save a ggplot to file
#'
#' When \code{output} is provided, saves to that path (format inferred from
#' extension).  When \code{output} is NULL, auto-generates a path using
#' \code{default_name}, the current timestamp, and the format from
#' \code{TRANING_PLOT_FORMAT} (default: \code{"pdf"}).
#'
#' @param p A ggplot2 object.
#' @param output Character path or NULL.  If NULL, auto-generates a path.
#' @param default_name Character.  Base name for auto-generated filename.
#' @param format Character or NULL.  Override format (e.g. \code{"png"}).
#'   When NULL, inferred from \code{output} extension or env default.
#' @param open Logical or NULL.  Open file after saving.  When NULL, uses
#'   \code{TRANING_OPEN} env var (default TRUE).
#' @param width Numeric.  Plot width in inches.  Default 10.
#' @param height Numeric.  Plot height in inches.  Default 6.
#' @return The output path (invisibly).
#' @export
save_plot <- function(p, output = NULL, default_name = "plot",
                      format = NULL, open = NULL, width = 10, height = 6) {
  defaults <- get_output_defaults()

  if (is.null(open)) open <- defaults$open
  if (is.null(format)) format <- defaults$plot_format

  if (is.null(output)) {
    out_dir <- file.path(defaults$output_dir, "plots")
    if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
    output <- file.path(out_dir,
      paste0(default_name, "_", format(Sys.time(), "%Y%m%d_%H%M%S"),
             ".", format))
  }

  ggplot2::ggsave(output, plot = p, width = width, height = height)
  cat("Sparad:", output, "\n")
  if (open) open_file(output)
  invisible(output)
}

# --- Table output ------------------------------------------------------------

#' Save a table (tibble/data.frame) to file
#'
#' Supports CSV, JSON, JSONL, and XLSX formats.  When \code{output} is NULL,
#' auto-generates a path using \code{default_name} and the format from
#' \code{TRANING_TABLE_FORMAT} (default: \code{"csv"}).
#'
#' @param tbl A data.frame or tibble.
#' @param output Character path or NULL.  If NULL, auto-generates a path.
#' @param default_name Character.  Base name for auto-generated filename.
#' @param format Character or NULL.  One of \code{"csv"}, \code{"json"},
#'   \code{"jsonl"}, \code{"xlsx"}.  When NULL, inferred from \code{output}
#'   extension or \code{TRANING_TABLE_FORMAT} env var.
#' @param open Logical or NULL.  Open file after saving.
#' @return The output path (invisibly).
#' @export
save_table <- function(tbl, output = NULL, default_name = "table",
                       format = NULL, open = NULL) {
  defaults <- get_output_defaults()

  if (is.null(open)) open <- defaults$open
  if (is.null(format) && !is.null(output)) {
    format <- tolower(tools::file_ext(output))
  }
  if (is.null(format) || format == "") format <- defaults$table_format

  if (is.null(output)) {
    out_dir <- file.path(defaults$output_dir, "tables")
    if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
    output <- file.path(out_dir,
      paste0(default_name, "_", format(Sys.time(), "%Y%m%d_%H%M%S"),
             ".", format))
  }

  switch(format,
    csv = utils::write.csv(tbl, output, row.names = FALSE),
    json = {
      json_str <- jsonlite::toJSON(tbl, pretty = TRUE, auto_unbox = TRUE)
      writeLines(json_str, output)
    },
    jsonl = {
      lines <- apply(tbl, 1, function(row) {
        jsonlite::toJSON(as.list(row), auto_unbox = TRUE)
      })
      writeLines(lines, output)
    },
    xlsx = {
      if (!requireNamespace("writexl", quietly = TRUE)) {
        stop("Paketet 'writexl' krävs för XLSX-export. ",
             "Installera med: install.packages('writexl')")
      }
      writexl::write_xlsx(tbl, output)
    },
    stop("Okänt format: '", format, "'. Välj csv, json, jsonl eller xlsx.")
  )

  cat("Sparad:", output, "\n")
  if (open) open_file(output)
  invisible(output)
}

# --- Utility -----------------------------------------------------------------

#' Convert decimal minutes to M:SS format
#' @param myint Numeric, minutes as decimal (e.g. 5.5 -> "5:30")
#' @return Character string in "M:SS" format
#' @export
dec_to_mmss <- function(myint) {
  myint_secs <- as.integer(myint * 60, units = "seconds")
  myint_mmss <- lubridate::seconds_to_period(myint_secs)
  myint_min <- lubridate::minute(myint_mmss)
  myint_sec <- lubridate::second(myint_mmss)
  if (myint_sec <= 9) {
    myint_sec <- stringr::str_glue("0{myint_sec}")
  } else if (nchar(as.character(myint_sec)) == 1) {
    myint_sec <- stringr::str_glue("{myint_sec}0")
  }
  myint_manual <- stringr::str_glue("{myint_min}:{myint_sec}")
  return(myint_manual)
}
