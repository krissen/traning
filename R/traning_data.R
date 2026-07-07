# S7 data bundle: foundation for collapsing the four hand-threaded data
# objects (summaries, myruns, health_daily, and the sport-keyed derived
# caches zone_data/decoupling_data) into a single object with a uniform
# fn(data, ...) signature. See docs/dev for the migration plan; this file
# is purely additive (PR 1 of 9) and touches no existing caller.

#' A bundled tRäning data object
#'
#' @description
#' \code{traning_data} bundles the data objects that thread through the
#' tRäning analysis surface (\code{summaries}, \code{myruns},
#' \code{health_daily}) together with derived, sport-keyed side-channel
#' caches (\code{zone_data}, \code{decoupling_data}) into a single S7
#' object. Migrated report/plot functions take one \code{data} argument
#' of this class instead of a hand-maintained list of positional
#' arguments.
#'
#' @param summaries A data.frame of per-session workout summaries.
#'   Required; must contain a \code{sessionStart} column.
#' @param myruns A list of per-session trackeR run objects, aligned to
#'   \code{summaries} rows. Defaults to \code{list()}.
#' @param health_daily A long daily health metrics data.frame, or
#'   \code{NULL} if not loaded. Defaults to \code{NULL}.
#' @param decoupling_data A data.frame of cardiac-decoupling results, or
#'   \code{NULL} if not computed. Defaults to \code{NULL}.
#' @param zone_data A list of HR-zone distribution results, or \code{NULL}
#'   if not computed. Defaults to \code{NULL}.
#' @param sport Character scalar naming the sport that \code{zone_data}
#'   and \code{decoupling_data} were computed for. Defaults to
#'   \code{"running"}. These two caches are sport-keyed derivations of
#'   \code{summaries}/\code{myruns}; a bundle should never have its
#'   \code{zone_data}/\code{decoupling_data} treated as valid for any
#'   sport other than the one recorded here, or results will be silently
#'   wrong for multi-sport data.
#' @param augmented Logical; whether \code{summaries} carries the Garmin
#'   \code{garmin_*} augmentation columns (see \code{augment_summaries()}
#'   in R/advanced_metrics.R). Defaults to \code{FALSE}.
#'
#' @return An object of class \code{traning_data}.
#' @export
traning_data <- S7::new_class(
  "traning_data",
  properties = list(
    summaries = S7::class_data.frame,
    myruns = S7::new_property(S7::class_list, default = list()),
    # NB: `default = NULL` (or `default = quote(NULL)`, which R evaluates
    # to the same literal NULL) is indistinguishable in S7 from "no
    # default supplied", which makes new_property() fall back to the
    # "empty instance" of the property's class (empty data.frame for a
    # `class_data.frame | NULL` union) instead of an actual NULL. Wrapping
    # in `if (TRUE) NULL` produces a genuine unevaluated call object as
    # the default expression, which S7 evaluates lazily to NULL as
    # intended. See S7 issue: default = NULL means "use class default".
    health_daily = S7::new_property(S7::class_data.frame | NULL, default = quote(if (TRUE) NULL)),
    decoupling_data = S7::new_property(S7::class_data.frame | NULL, default = quote(if (TRUE) NULL)),
    zone_data = S7::new_property(S7::class_list | NULL, default = quote(if (TRUE) NULL)),
    sport = S7::new_property(S7::class_character, default = "running"),
    augmented = S7::new_property(S7::class_logical, default = FALSE)
  ),
  validator = function(self) {
    # S7's class_data.frame / class_list property types already enforce that
    # @summaries is a data.frame and @myruns a list, so only the constraints
    # S7 cannot express are validated here.
    if (!"sessionStart" %in% names(self@summaries)) {
      return("@summaries must contain a 'sessionStart' column")
    }
    # @sport is always meaningful (defaults to "running"), keys the derived
    # zone_data/decoupling_data caches, and feeds the one-line print contract,
    # so it must always be a single non-empty string — not only when a cache
    # is present. A multi-element @sport would otherwise break format()/print().
    if (length(self@sport) != 1 || is.na(self@sport) || !nzchar(self@sport)) {
      return("@sport must be a single non-empty string")
    }
    NULL
  }
)

#' @name format.traning_data
#' @title Compact one-line summary of a traning_data bundle
#' @param x A \code{traning_data} object.
#' @param ... Unused, present for S7/S3 generic compatibility.
#' @return A character scalar.
#' @noRd
S7::method(format, traning_data) <- function(x, ...) {
  n <- nrow(x@summaries)
  span <- if (n > 0 && "sessionStart" %in% names(x@summaries)) {
    rng <- range(x@summaries$sessionStart, na.rm = TRUE)
    paste(format(rng[1], "%Y-%m-%d"), "to", format(rng[2], "%Y-%m-%d"))
  } else {
    "no sessions"
  }
  optional <- c(
    if (!is.null(x@health_daily)) "health_daily",
    if (!is.null(x@decoupling_data)) "decoupling_data",
    if (!is.null(x@zone_data)) "zone_data"
  )
  optional_str <- if (length(optional) > 0) paste(optional, collapse = ", ") else "none"
  sprintf(
    "<traning_data> %d sessions (%s) | sport=%s | augmented=%s | optional: %s",
    n, span, x@sport, x@augmented, optional_str
  )
}

#' @name print.traning_data
#' @title Print a compact summary of a traning_data bundle
#' @param x A \code{traning_data} object.
#' @param ... Unused, present for S7/S3 generic compatibility.
#' @return \code{x}, invisibly.
#' @noRd
S7::method(print, traning_data) <- function(x, ...) {
  cat(format(x), "\n", sep = "")
  invisible(x)
}

#' Coerce legacy positional data into a traning_data bundle
#'
#' @description
#' Internal compatibility shim bridging the legacy
#' \code{fn(summaries, myruns, ...)} calling convention to the new uniform
#' \code{fn(data, ...)} contract used by \code{\link{traning_data}}. A
#' function under migration calls \code{.as_traning_data(data, ...)} as its
#' first line:
#'
#' \preformatted{
#' report_ef <- function(data, n = 28, ...) {
#'   td <- .as_traning_data(data)
#'   summaries <- td@summaries
#'   ...
#' }
#' }
#'
#' \strong{Contract:}
#' \itemize{
#'   \item If \code{data} already inherits \code{traning_data}, it is
#'     returned unchanged. Any named args in \code{...} are ignored — the
#'     bundle is already complete, so there is nothing to fold in.
#'   \item Otherwise \code{data} is treated as a legacy \code{summaries}
#'     data.frame (the first positional arg of the un-migrated function).
#'     Named arguments in \code{...} matching \code{traning_data} slot
#'     names (\code{myruns}, \code{health_daily}, \code{decoupling_data},
#'     \code{zone_data}, \code{sport}, \code{augmented}) are folded into
#'     the corresponding slots of the new bundle. This lets a caller
#'     migrating a multi-arg legacy function forward its other legacy data
#'     args, e.g. a function that used to take
#'     \code{fn(summaries, myruns, ...)} can call
#'     \code{.as_traning_data(summaries, myruns = myruns)} so that both
#'     the legacy call site and a future \code{traning_data}-only call
#'     site keep working during the incremental migration.
#' }
#'
#' @param data Either a \code{traning_data} object, or a legacy
#'   \code{summaries} data.frame.
#' @param ... Named legacy data args (\code{myruns}, \code{health_daily},
#'   \code{decoupling_data}, \code{zone_data}, \code{sport},
#'   \code{augmented}) to fold into the bundle when \code{data} is a bare
#'   data.frame. Ignored when \code{data} is already a \code{traning_data}
#'   object.
#' @return A \code{traning_data} object.
#' @keywords internal
.as_traning_data <- function(data, ...) {
  if (S7::S7_inherits(data, traning_data)) {
    return(data)
  }

  if (!is.data.frame(data)) {
    stop(
      "`.as_traning_data()` expects a `traning_data` object or a legacy ",
      "`summaries` data.frame as its first argument, got: ",
      paste(class(data), collapse = "/"),
      call. = FALSE
    )
  }

  extra <- list(...)
  slot_names <- c(
    "myruns", "health_daily", "decoupling_data", "zone_data", "sport", "augmented"
  )
  unknown <- setdiff(names(extra), slot_names)
  if (length(unknown) > 0) {
    stop(
      "`.as_traning_data()` received unrecognised argument(s): ",
      paste(unknown, collapse = ", "),
      ". Expected one or more of: ", paste(slot_names, collapse = ", "),
      call. = FALSE
    )
  }

  do.call(traning_data, c(list(summaries = data), extra))
}
