# Shared utility functions

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
