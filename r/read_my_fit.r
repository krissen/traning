#!/usr/local/bin/R

# library(fitdc)
library(tracker)
library(lubridate)
suppressMessages(suppressWarnings(library(tidyverse)))


fetch_run_overview <- function(arun) {
  # arun <- run_details
  last_entry <- length(arun$distance.m)
  distance <- arun$distance.m[[last_entry]]
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

files <- list.files(path="../kristian/filer/tcx",
                    recursive = TRUE,
                    pattern="*.fit",
                    ignore.case = TRUE,
                    full.names=TRUE)

files %>%
  .[!grepl("fit/0000", .)] -> files

df <- data.frame()

for ( file in files ) {
  tryCatch({
    run_details <- fetch_run(file)
  run_overview <- fetch_run_overview(run_details)
  df <- rbind(df, run_overview)
  }, error = function(e){})
}

test <- readTCX(file, timezone = "", speedunit = "m_per_s",
        distanceunit = "m")
run_details <- fetch_run(file)

run_overview <- fetch_run_overview(run_details)

# vim: ts=2 sw=2 et
