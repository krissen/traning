#!/usr/local/bin/Rscript

# todo: ge info om senast tillagda traningar

# library(fitdc)
# remotes::install_github("trackeRproject/trackeR", ref = "develop")
suppressMessages(suppressWarnings(library(trackeR)))
library(stringr)
# devtools::install_github("trackerproject/trackeRapp")
suppressMessages(suppressWarnings(library(lubridate)))
suppressMessages(suppressWarnings(library(tidyverse)))
library(optparse)

# library("trackeRapp")
# trackeR_app()

isRStudio <- Sys.getenv("RSTUDIO") == "1"

if ( isRStudio ) {
  no_means <- FALSE
  do_graphs <- FALSE
  do_verbose <- FALSE
  do_month_running <- TRUE
  do_total_pace <- TRUE
  do_import <- FALSE
} else {
  my_options = list(
                    make_option(c("-g", "--graphs"),
                                 type="logical",
                                 action="store_true",
                                 default=FALSE,
                                 help="Print graphs (default %default)"),
                    make_option(c("-v", "--verbose"),
                                type="logical",
                                action="store_true",
                                default=FALSE,
                                help="Verbose output"),
                    make_option(c("-n", "--no_means"),
                                type="logical",
                                action="store_false",
                                default=TRUE,
                                help="Print table of means (default TRUE)"),
                    make_option("--import",
                                type="logical",
                                action="store_true",
                                default=FALSE,
                                help="Import new workouts (and save)"),
                    make_option("--total-pace",
                                type="logical",
                                action="store_true",
                                default=FALSE,
                                help="Print summarization of pace (all-time)"),
                    make_option("--month-running",
                                type="logical",
                                action="store_true",
                                default=FALSE,
                                help="Print summarization of current running month")
                    );

  opt_parser <- OptionParser(option_list=my_options);
  options <- parse_args(opt_parser);

  do_import <- options$import
  no_means <- options$no_means
  do_graphs <- options$graphs
  do_verbose <- options$verbose
  do_month_running <- options$`month-running`
  do_total_pace <- options$`total-pace`
}

db_summaries <- "summaries.RData"
db_myruns <- "myruns.RData"
mytcxpath = "../kristian/filer/tcx"

my_dbs_save <- function(db_summaries, db_myruns, summaries, myruns) {
  save(myruns, file = db_myruns)
  save(summaries, file = db_summaries)
}

my_dbs_load <- function(db_summaries, db_myruns) {
  if ( file.exists(db_summaries) ) {
    load(db_summaries)
  } else {
    summaries <- data.frame()
  }
  if ( file.exists(db_myruns) ) {
    load(db_myruns)
  } else {
    myruns <- list()
  }
  
  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
  return(my_templist)
}

get_my_files <- function(mytcxpath) {
  files <- list.files(path=mytcxpath,
                      recursive = TRUE,
                      pattern="*.tcx",
                      ignore.case = TRUE,
                      full.names=TRUE)
  return(files)
}

add_my_columns <- function(summarydata) {
  summarydata %>%
    mutate(avgStrideMoving = (
      60 * avgSpeedMoving) / (avgCadenceRunningMoving * 2)) %>%
      mutate(avgStride= (
        60 * avgSpeed) / (avgCadenceRunning* 2)) -> summarydata
  return(summarydata)
}

fix_zero_moving <- function(summarydata) {
  summarydata %>%
    mutate(
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

get_new_workouts <- function(files, summaries, myruns) {
  for ( i in 1:length(files) ) {
    thefile <- files[[i]]
    if ( thefile %in% summaries$file ) {
      if (do_verbose) {
        cat("Har redan last in ", thefile, "\n", sep = "")
      }
    } else {
      if (do_verbose) {
        cat("\nLaser in ", files[[i]], "...", sep = "")
      }
      myruns[[i]] <- read_container(files[[i]])
      if (do_verbose) {
        cat("\n")
        cat("Skapar summering ...\n")
      }
      run_summary <- summary(myruns[[i]])
      # run_summary <- fix_zero_moving(run_summary)
      run_summary <- add_my_columns(run_summary)
      if (do_verbose) {
        cat("Binder ihop\n")
      }
      summaries <- rbind(summaries, run_summary,
                         deparse.level = 0,
                         make.row.names = FALSE
      )
    }
  }
  my_templist <- list()
  my_templist[["summaries"]] <- summaries
  my_templist[["myruns"]] <- myruns
  return(my_templist)
}

report_mostrecent <- function(summaries) {
  tot_distance <- round(sum(summaries$distance) / 1000, digits = 2)
  avg_distance <- round(mean(summaries$distance) / 1000, digits = 2)
  avg_duration <- round(
    mean(as.numeric(
      summaries$durationMoving), na.rm = TRUE), digits = 0)
  cat(summaries_lengthdiff, " workouts imported.\n", sep = "")
  cat("Distance: ", tot_distance, 
      "km total; ", avg_distance, "km on average.\n", sep = "")
  cat("Average duration: ", avg_duration, " minutes.\n", sep = "")
}

# load previously read workouts
my_templist <- my_dbs_load(db_summaries, db_myruns)
summaries <- my_templist[["summaries"]]
myruns <- my_templist[["myruns"]]
rm(my_templist)
  
if (do_import) {
  # read new workouts if such have been added
  files <- get_my_files(mytcxpath)
  summaries_oldlength <- count(summaries)
  my_templist <- get_new_workouts(files, summaries, myruns)
  summaries <- my_templist[["summaries"]]
  myruns <- my_templist[["myruns"]]
  rm(my_templist)
  summaries_newlength <- count(summaries)
  summaries_lengthdiff <- as.numeric(summaries_newlength - summaries_oldlength)
  
  # save database if workouts were added
  if ( summaries_oldlength != summaries_newlength ) {
    #cat("New data: ",
    #    summaries_lengthdiff, " workouts.\n", sep = "")
    #cat("Database should be saved.\n")
    my_dbs_save(db_summaries, db_myruns, summaries, myruns)
    summaries_mostrecent <- tail(summaries, n = summaries_lengthdiff)
    report_mostrecent(summaries_mostrecent)
  }
}

report_monthstatus <- function(summaries) {
  my_year <- as.numeric(format(Sys.time(), "%Y"))
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))

  summaries %>%
    mutate(month = as.numeric(
      format(sessionStart, "%m"))) %>%
    filter(month == my_month) -> month_summaries
  
  month_dist_avg <- round(
    mean(month_summaries$distance) / 1000, digits = 2)
  
  summaries %>%
    mutate(
           month = as.numeric(format(sessionStart, "%m")),
           year = as.numeric(format(sessionStart, "%Y"))) %>%
    filter(month == my_month) %>%
    group_by(year) %>%
    summarise(
      dist_max = max(distance),
      dist_sum = sum(distance),
      dist_avg = mean(distance),
      .groups = "keep"
      ) -> month_yearlies
  
  month_yearlies %>%
    filter(year != my_year) %>%
    arrange(desc(dist_sum)) -> month_yearlies_top_dist
  
  best_year_dist_year <- month_yearlies_top_dist$year[[1]]
  best_year_dist_km <- round(
    month_yearlies_top_dist$dist_sum[[1]] / 1000, digits = 2)
  last_row <- nrow(month_yearlies_top_dist)
  worst_year_dist_year <- month_yearlies_top_dist$year[[last_row]]
  worst_year_dist_km <- round(
    month_yearlies_top_dist$dist_sum[[last_row]] / 1000,
    digits = 2)
  
  month_summaries %>%
    mutate(
      day = as.numeric(format(sessionStart, "%d")),
      year = as.numeric(format(sessionStart, "%Y"))
      ) %>%
    filter(day <= my_day) %>%
    select(year, distance, avgPaceMoving, avgHeartRateMoving) %>%
    group_by(year) %>%
    summarise(
      dist_max = max(distance) / 1000,
      dist_sum = sum(distance) / 1000,
      dist_avg = mean(distance) / 1000,
      d_avg_dy = (mean(distance) / 1000) / my_day,
      pace_avg = mean(avgPaceMoving),
      pace_min = min(avgPaceMoving),
      hrat_avg = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      .groups = "keep") %>%
    arrange(d_avg_dy) -> month_summaries_til_day
  
  return(month_summaries_til_day)
}

fetch.plot.monthly.dist <- function(month_summaries_til_day) {
  my_month <- format(Sys.time(), "%B")
  my_title <- stringr::str_glue("Distans och tempo för löpande månad ({my_month})")
  
  month_summaries_til_day %>%
    ggplot(aes(x = as.integer(year))) +
    # geom_point() +
    # geom_smooth(method = 'loess', formula = 'y ~ x') +
    geom_col(
      aes(
        y = dist_avg,
        fill = "Dist., medel"
      )) +
    geom_col(aes(
      y = d_avg_dy,
      fill = "Dist. per dag, medel.")) +
    geom_line(aes(
      y = pace_avg,
      colour = 'Tempo, medel')) +
    scale_colour_manual("", values=c(
      "Tempo, medel" = "red"
    )) +
    scale_fill_manual(" ", values=c(
      "Dist., medel" = "darkblue",
      "Dist. per dag, medel." = "lightblue"
    )) +
    theme(legend.key=element_blank(),
          legend.title=element_blank()) +
    ggtitle(my_title) +
    labs(x = "År", y = "Kilometer") -> p1
  return(p1)
}

if ( do_month_running ) {
  month_summaries_til_day <- report_monthstatus(summaries)
  if ( ! isRStudio ) {
    print(month_summaries_til_day)
  } else {
    plot.monthly.dist <- fetch.plot.monthly.dist(month_summaries_til_day)
  }
}

# oddrun <- read_container("../kristian/filer/tcx/20200202-115430.tcx")

# plot_route(run, maptype = "watercolor")
# plot_route(run, maptype = "terrain")

# runs <- read_directory(mytcxpath)

# plot_route(runs, session = NULL)

# strides <- lapply(my_run, function(x) (60 * x$speed) / (x$cadence_running))

# plot(strides[[1]])

# run_sum <- summary(run)



# summaries %>%
#  mutate(avgStrideMoving = (
#    60 * avgSpeedMoving) / (avgCadenceRunningMoving * 2)) %>%
#  mutate(avgStride= (
#    60 * avgSpeed) / (avgCadenceRunning* 2)) -> summaries

# summaries %>%
#  filter(file == 0)

fetch.my.mean.pace <- function(summaries) {
  mean.pace <- summaries %>%
    filter(str_detect(sport, 'running')) %>%
    mutate(
           #month = format(sessionStart, "%m"),
           year = format(sessionStart, "%Y")
           ) %>%
    group_by(year) %>%
    summarise(totDuration = sum(durationMoving), 
              meanPace = mean(avgPaceMoving, na.rm = TRUE),
              minPace = min(avgPaceMoving, na.rm = TRUE),
              .groups = "keep"
              )
  return(mean.pace)
}

fetch.plot.mean.pace <- function(mean.pace) {
  mean.pace %>%
    ggplot(aes(x = as.integer(year), y = meanPace)) +
      geom_point() +
      geom_smooth(method = 'loess', formula = 'y ~ x') +
      ggtitle("Tempo över år") +
      labs(x = "År", y = "Medeltempo (min/km)") -> p1
  return(p1)
}

if (do_total_pace) {
  mean.pace <- fetch.my.mean.pace(summaries)
  if ( ! isRStudio ) {
    print(mean.pace)
  } else {
    plot.mean.pace <- fetch.plot.mean.pace(mean.pace)
  }
}

# ta bort rader som matchar
# summaries2 <- summaries[!(summaries$avgPaceMoving == 0),]

#summaries %>%
#  filter(str_detect(file, '../kristian/filer/tcx/20200202-115430.tcx'))

# files %>%
#   .[!grepl("fit/0000", .)] -> files


# vim: ts=2 sw=2 et
