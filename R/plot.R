# Plot functions — each returns a ggplot2 object

# NOTE: fetch.plot.monthly.top() is called in the old script (line 585)
# but was never defined. Known pre-existing bug — only triggers when
# isRStudio == TRUE && do_month_top == TRUE.

#' Bar + line plot of monthly distance and pace
#' @param month_summaries_til_day Tibble from report_monthstatus()
#' @return ggplot2 object
#' @export
fetch.plot.monthly.dist <- function(month_summaries_til_day) {
  my_month <- format(Sys.time(), "%B")
  my_title <- stringr::str_glue(
    "Distans och tempo för löpande månad ({my_month})")

  month_summaries_til_day %>%
    ggplot2::ggplot(ggplot2::aes(x = as.integer(year))) +
    ggplot2::geom_col(
      ggplot2::aes(y = dist_avg, fill = "Dist., medel")) +
    ggplot2::geom_col(
      ggplot2::aes(y = d_avg_dy, fill = "Dist. per dag, medel.")) +
    ggplot2::geom_line(
      ggplot2::aes(y = pace_avg, colour = 'Tempo, medel')) +
    ggplot2::scale_colour_manual("",
      values = c("Tempo, medel" = "red")) +
    ggplot2::scale_fill_manual(" ",
      values = c("Dist., medel" = "darkblue",
                 "Dist. per dag, medel." = "lightblue")) +
    ggplot2::theme(legend.key = ggplot2::element_blank(),
                   legend.title = ggplot2::element_blank()) +
    ggplot2::ggtitle(my_title) +
    ggplot2::labs(x = "År", y = "Kilometer") -> p1
  return(p1)
}

#' Compute yearly mean pace statistics
#' @param summaries Data frame of all workout summaries
#' @return Tibble with year, totDuration, meanPace, minPace
#' @export
fetch.my.mean.pace <- function(summaries) {
  mean.pace <- summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(year = format(sessionStart, "%Y")) %>%
    dplyr::group_by(year) %>%
    dplyr::summarise(
      totDuration = sum(durationMoving),
      meanPace = mean(avgPaceMoving, na.rm = TRUE),
      minPace = min(avgPaceMoving, na.rm = TRUE),
      .groups = "keep")
  return(mean.pace)
}

#' Scatter + smooth plot of yearly total distance
#' @param summaries Data frame of all workout summaries
#' @return ggplot2 object
#' @export
fetch.plot.sum.dist <- function(summaries) {
  summaries %>%
    dplyr::filter(stringr::str_detect(sport, 'running')) %>%
    dplyr::mutate(year = as.numeric(format(sessionStart, "%Y"))) %>%
    dplyr::group_by(year) %>%
    dplyr::summarise(
      dist_max = max(distance),
      dist_sum = sum(distance) / 1000,
      dist_avg = mean(distance, na.rm = TRUE) / 1000,
      .groups = "keep") %>%
    ggplot2::ggplot(ggplot2::aes(x = as.integer(year), y = dist_sum)) +
    ggplot2::geom_point() +
    ggplot2::geom_smooth(method = 'loess', formula = 'y ~ x') +
    ggplot2::ggtitle("Distans över år") +
    ggplot2::labs(x = "År", y = "Kilometer") -> plot.sum.dist
  return(plot.sum.dist)
}

#' Scatter + smooth plot of yearly mean pace
#' @param mean.pace Tibble from fetch.my.mean.pace()
#' @return ggplot2 object
#' @export
fetch.plot.mean.pace <- function(mean.pace) {
  mean.pace %>%
    ggplot2::ggplot(ggplot2::aes(x = as.integer(year), y = meanPace)) +
    ggplot2::geom_point() +
    ggplot2::geom_smooth(method = 'loess', formula = 'y ~ x') +
    ggplot2::ggtitle("Tempo över år") +
    ggplot2::labs(x = "År", y = "Medeltempo (min/km)") -> p1
  return(p1)
}
