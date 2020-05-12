#!/usr/local/bin/R

library(fitdc)
library(lubridate)

afile <- "../kristian/filer/fit/2015/2015-01-26_08-54-50-80-12991.fit"


is_record <- function(mesg) mesg$name == "record"

format_record <- function(record) {
  out <- record$fields
  names(out) <- paste(names(out), record$units, sep = ".")
  out
}

merge_lists <- function(ls_part, ls_full) {
  extra <- setdiff(names(ls_full), names(ls_part))
  append(ls_part, ls_full[extra])[names(ls_full)]  # order as well
}

fetch_run <- function(fitfile) {
  data_mesgs <- read_fit(fitfile)

  records <- Filter(is_record, data_mesgs)

  records <- lapply(records, format_record)

  ## Some records have missing fields:

  colnames_full <- names(records[[which.max(lengths(records))]])

  empty <- setNames(
                    as.list(rep(NA, length(colnames_full))),
                    colnames_full)

  records <- lapply(records, merge_lists, empty)
  records <- data.frame(
                        do.call(rbind, records))

  return(records)
}

fetch_run_overview <- function(arun) {
  # arun <- run_details
  last_entry <- length(arun$distance.m)
  distance <- arun$distance.m[[my_last_entry]]
  hr_mean <- mean(as.numeric(arun$heart_rate.bpm), na.rm = TRUE)
  hr_max <- max(as.numeric(arun$heart_rate.bpm), na.rm = TRUE)
  
  dur_start <- arun$timestamp.s[[1]]
  dur_end <- arun$timestamp.s[[last_entry]]
  time_start <- as.POSIXct(dur_start, origin="1990-01-01")
  time_end <- as.POSIXct(dur_end, origin="1990-01-01")
  interval <- time_start %--% time_end
  duration <- as.duration(interval)

  speed_mean_ms <- mean(as.numeric(arun$speed.m.s), na.rm = TRUE)
  speed_kmh <- speed_mean_ms * 3.6
  speed_minpkm <- 16.666666666667 / speed_mean_ms

  overview <- data.frame(
                       time_start, duration,
                       distance,
                       hr_mean, hr_max,
                       speed_mean_ms, speed_minpkm
  )

  return(overview)
}

run_details <- fetch_run(afile)

run_overview <- fetch_run_overview(run_details)

# vim: ts=2 sw=2 et
