#!/usr/local/bin/R

# library(fitdc)
# remotes::install_github("trackeRproject/trackeR", ref = "develop")
library(trackeR)
library(stringr)
# devtools::install_github("trackerproject/trackeRapp")
library(lubridate)
suppressMessages(suppressWarnings(library(tidyverse)))

# library("trackeRapp")
# trackeR_app()

db_summaries <- "summaries.RData"
db_myruns <- "myruns.RData"

load(db_summaries)
load(db_myruns)

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


mytcxpath = "../kristian/filer/tcx"

# oddrun <- read_container("../kristian/filer/tcx/20200202-115430.tcx")

# plot_route(run, maptype = "watercolor")
# plot_route(run, maptype = "terrain")

# runs <- read_directory(mytcxpath)

# plot_route(runs, session = NULL)

# strides <- lapply(my_run, function(x) (60 * x$speed) / (x$cadence_running))

# plot(strides[[1]])

# run_sum <- summary(run)

files <- list.files(path=mytcxpath,
                    recursive = TRUE,
                    pattern="*.tcx",
                    ignore.case = TRUE,
                    full.names=TRUE)

summaries <- data.frame()
myruns <- list()

for ( i in 1:length(files) ) {
  thefile <- files[[i]]
  if ( thefile %in% summaries$file ) {
    cat("\nHar redan läst in ", thefile, sep = "")
  } else {
    cat("\nReading ", files[[i]], "...", sep = "")
    myruns[[i]] <- read_container(files[[i]])
    cat("\n")
    cat("Creating summary ...\n")
    run_summary <- summary(myruns[[i]])
    cat("Binder ihop\n")
    summaries <- rbind(summaries, run_summary,
                       deparse.level = 0,
                       make.row.names = FALSE
                       )
  }
}

summaries %>%
  mutate(avgStrideMoving = (
    60 * avgSpeedMoving) / (avgCadenceRunningMoving * 2)) %>%
  mutate(avgStride= (
    60 * avgSpeed) / (avgCadenceRunning* 2)) -> summaries

summaries %>%
  filter(str_detect(sport, 'running')) %>%
  mutate(year = format(sessionStart, "%Y")) %>%
  group_by(year) %>%
  summarise(totDuration = sum(durationMoving), 
            meanPace = mean(avgPaceMoving),
            minPace = min(avgPaceMoving)
            )

#save(myruns, file = db_myruns)
#save(summaries, file = db_summaries)

# files %>%
#   .[!grepl("fit/0000", .)] -> files


# vim: ts=2 sw=2 et
