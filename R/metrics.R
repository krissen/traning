# Data transformation functions for workout summaries

#' Add calculated stride columns to summary data
#' @param summarydata Data frame from trackeR summary
#' @return Data frame with avgStrideMoving and avgStride columns added
#' @export
add_my_columns <- function(summarydata) {
  summarydata %>%
    dplyr::mutate(avgStrideMoving = (
      60 * avgSpeedMoving) / (avgCadenceRunningMoving * 2)) %>%
    dplyr::mutate(avgStride = (
      60 * avgSpeed) / (avgCadenceRunning * 2)) -> summarydata
  return(summarydata)
}

#' Replace zero/NA moving metrics with overall values
#' @param summarydata Data frame from trackeR summary
#' @return Data frame with zeros/NAs patched
#' @export
fix_zero_moving <- function(summarydata) {
  summarydata %>%
    dplyr::mutate(
      durationMoving = ifelse(durationMoving == 0, duration, durationMoving),
      avgHeartRateMoving = ifelse(is.na(avgHeartRateMoving),
                                  avgHeartRate, avgHeartRateMoving),
      avgAltitudeMoving = ifelse(is.na(avgAltitudeMoving),
                                 avgAltitude, avgAltitudeMoving),
      avgPaceMoving = ifelse(avgPaceMoving == 0, avgPace, avgPaceMoving),
      avgSpeedMoving = ifelse(is.na(avgSpeedMoving), avgSpeed, avgSpeedMoving)
    ) -> summarydata
  return(summarydata)
}
