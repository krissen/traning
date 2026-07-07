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
