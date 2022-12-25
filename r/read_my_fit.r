#!/usr/bin/Rscript

# todo: ge info om senast tillagda traningar

# Installing Packages that are not already available in the system 
list.of.packages <- c("trackeR", "stringr",
                      "lubridate", "tidyverse",
                      "optparse")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages)

# Loading Packages
suppressWarnings(suppressMessages(invisible(lapply(list.of.packages, require, character.only = TRUE))))

# Använder men flyttat upp till automatisk installation
# suppressMessages(suppressWarnings(library(trackeR)))
# library(stringr)
# suppressMessages(suppressWarnings(library(lubridate)))
# suppressMessages(suppressWarnings(library(tidyverse)))
# library(optparse)

# Gammalt
# library(fitdc)
# remotes::install_github("trackeRproject/trackeR", ref = "develop")
# devtools::install_github("trackerproject/trackeRapp")
# library("trackeRapp")
# trackeR_app()

isRStudio <- Sys.getenv("RSTUDIO") == "1"

if ( isRStudio ) {
  no_means <- FALSE
  do_graphs <- FALSE
  do_verbose <- FALSE
  do_month_running <- TRUE
  do_year_running  <- FALSE
  do_year_top  <- FALSE
  do_month_last <- FALSE
  do_month_this <- FALSE
  do_month_top <- FALSE
  do_total_pace <- TRUE
  do_import <- FALSE
} else {
  my_options = list(
                    make_option(c("-g", "--graphs"),
                                 type = "logical",
                                 action = "store_true",
                                 default = FALSE,
                                 help = "Print graphs (default %default)"),
                    make_option(c("-v", "--verbose"),
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Verbose output"),
                    make_option(c("-n", "--no_means"),
                                type = "logical",
                                action = "store_false",
                                default = TRUE,
                                help = "Print table of means (default TRUE)"),
                    make_option("--import",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Import new workouts (and save)"),
                    make_option("--total-pace",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of pace (all-time)"),
                    make_option("--month-top",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of top 10 months"
                                ),
                    make_option("--month-this",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of runs this month"),
                    make_option("--month-last",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of last month over the years"),
                    make_option("--month-running",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of current running month"),
                    make_option("--year-top",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of top year"),
                    make_option("--year-running",
                                type = "logical",
                                action = "store_true",
                                default = FALSE,
                                help = "Print summarization of current running year")
                    );

  opt_parser <- OptionParser(option_list=my_options);
  options <- parse_args(opt_parser);

  do_import <- options$import
  no_means <- options$no_means
  do_graphs <- options$graphs
  do_verbose <- options$verbose
  do_month_top <- options$`month-top`
  do_month_last <- options$`month-last`
  do_month_this <- options$`month-this`
  do_month_running <- options$`month-running`
  do_year_running  <- options$`year-running`
  do_year_top  <- options$`year-top`
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
  avg_distance <- round(mean(summaries$distance, na.rm = TRUE) / 1000, digits = 2)
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

dec_to_mmss <- function(myint) {
 # myint <- as.integer(5.37776) 
 myint_secs <- as.integer(myint * 60, units = "seconds")
 myint_mmss <- seconds_to_period(myint_secs)
 myint_min <- minute(myint_mmss)
 myint_sec <- second(myint_mmss)
 if ( myint_sec <= 9 ) {
   myint_sec <- stringr::str_glue("0{myint_sec}")
 } else if ( nchar(as.character(myint_sec)) == 1 ) {
   myint_sec <- stringr::str_glue("{myint_sec}0")
 }
 myint_manual <- stringr::str_glue("{myint_min}:{myint_sec}")
 return(myint_manual)
}

report_monthtop <- function(summaries) {
  summaries %>%
    # mutate(month = as.numeric(
    #   format(sessionStart, "%m"))) %>%
    filter(str_detect(sport, 'running')) -> month_summaries
  
  #month_dist_avg <- round(
  #  mean(month_summaries$distance) / 1000, digits = 2)
  
  month_summaries %>%
    mutate(
      day = as.numeric(format(sessionStart, "%d")),
      # 'År' = as.numeric(format(sessionStart, "%Y")),
      'År-mån' = format(sessionStart, "%Y-%m")
      ) %>%
    # filter(day <= my_day) %>%
    select(`År-mån`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    group_by(`År-mån`) %>%
    summarise(
      # 'Km/dag, medel' = (sum(distance) / 1000) / my_day,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      # 'Km, medel' = mean(distance, na.rm = TRUE) / 1000,
      'Tempo, medel' =  dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      # 'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      # 'Puls, medel' = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      Turer = n(),
      .groups = "keep") %>%
    arrange(`Km, tot`, .by_group = FALSE) %>%
    tail(n = 10) -> month_top
  # month_top

  return(month_top)
}

report_runs_year_month <- function(summaries,
                                   do_year = format(Sys.time(), "%Y"),
                                   do_month = format(Sys.time(), "%m")
                                                  ) {

  summaries %>%
    mutate(month = as.numeric(
      format(sessionStart, "%m")),
      year = as.numeric(format(sessionStart, "%Y"))) %>%
    filter(month == do_month,
           year == do_year,
           str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
    mutate(
      'År' = as.numeric(format(sessionStart, "%Y")),
      'Mån' = as.numeric(format(sessionStart, "%m")),
      'Dag' = as.numeric(format(sessionStart, "%d")),
      'Km' = distance / 1000,
      'Pace' = avgPaceMoving,
      'HR' = avgHeartRateMoving
      ) %>%
    select(`År`, `Mån`, `Dag`, Km, Pace, HR) %>%
    arrange(`Dag`) -> runs_year_month
  # month_summaries_last
  
  return(runs_year_month)
}

report_monthlast <- function(summaries) {
  my_year <- as.numeric(format(Sys.time(), "%Y"))
  my_month <- as.numeric(format(Sys.time(), "%m"))
  do_month <- my_month - 1
  my_day <- as.numeric(format(Sys.time(), "%d"))

  summaries %>%
    mutate(month = as.numeric(
      format(sessionStart, "%m"))) %>%
    filter(month == do_month,
	   str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
    mutate(
      'År' = as.numeric(format(sessionStart, "%Y"))
      ) %>%
    select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    group_by(`År`) %>%
    summarise(
      'Km/dag' = (sum(distance) / 1000) / my_day,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      # 'Km, medel' = mean(distance, na.rm = TRUE) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      # 'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      # 'Puls, medel' = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      Turer = n(),
      .groups = "keep") %>%
    arrange(`Km/dag`, .by_group = FALSE) > month_summaries_last
  # month_summaries_last
  
  return(month_summaries_last)
}

report_yearstop <- function(summaries) {
  my_year <- as.numeric(format(Sys.time(), "%Y"))
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))
  my_dayyear <- as.numeric(format(Sys.time(), "%-j"))

  summaries %>%
    mutate(
      day = as.numeric(format(sessionStart, "%d")),
      dayyear = as.numeric(format(sessionStart, "%-j")),
      'År' = as.numeric(format(sessionStart, "%Y"))
      ) %>%
    filter(str_detect(sport, 'running')) %>%
    select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    group_by(`År`) %>%
    summarise(
      'Km/dag' = (sum(distance) / 1000) / my_dayyear,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      # 'Km, medel' = mean(distance, na.rm = TRUE) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      # 'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      # 'Puls, medel' = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      Turer = n(),
      .groups = "keep") %>%
    arrange(`Km/dag`, .by_group = FALSE) -> year_summaries_til_day

  return(year_summaries_til_day)
}

report_yearstatus <- function(summaries) {
  my_year <- as.numeric(format(Sys.time(), "%Y"))
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))
  my_dayyear <- as.numeric(format(Sys.time(), "%-j"))

  summaries %>%
    mutate(
      day = as.numeric(format(sessionStart, "%d")),
      dayyear = as.numeric(format(sessionStart, "%-j")),
      'År' = as.numeric(format(sessionStart, "%Y"))
      ) %>%
    filter(dayyear <= my_dayyear,
	   str_detect(sport, 'running')) %>%
    select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    group_by(`År`) %>%
    summarise(
      'Km/dag' = (sum(distance) / 1000) / my_dayyear,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      # 'Km, medel' = mean(distance, na.rm = TRUE) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      # 'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      # 'Puls, medel' = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      Turer = n(),
      .groups = "keep") %>%
    arrange(`Km/dag`, .by_group = FALSE) -> year_summaries_til_day

  return(year_summaries_til_day)
}

report_monthstatus <- function(summaries) {
  my_year <- as.numeric(format(Sys.time(), "%Y"))
  my_month <- as.numeric(format(Sys.time(), "%m"))
  my_day <- as.numeric(format(Sys.time(), "%d"))

  summaries %>%
    mutate(month = as.numeric(
      format(sessionStart, "%m"))) %>%
    filter(month == my_month,
	   str_detect(sport, 'running')) -> month_summaries

  month_summaries %>%
    mutate(
      day = as.numeric(format(sessionStart, "%d")),
      'År' = as.numeric(format(sessionStart, "%Y"))
      ) %>%
    filter(day <= my_day) %>%
    select(`År`, distance, avgPaceMoving, avgHeartRateMoving) %>%
    group_by(`År`) %>%
    summarise(
      'Km/dag' = (sum(distance) / 1000) / my_day,
      'Km, tot' = sum(distance) / 1000,
      'Km, max' = max(distance) / 1000,
      # 'Km, medel' = mean(distance, na.rm = TRUE) / 1000,
      'Tempo, medel' = dec_to_mmss(mean(avgPaceMoving, na.rm = TRUE)),
      # 'Tempo, max' = dec_to_mmss(min(avgPaceMoving)),
      # 'Puls, medel' = mean(as.numeric(avgHeartRateMoving), na.rm = TRUE),
      Turer = n(),
      .groups = "keep") %>%
    arrange(`Km/dag`, .by_group = FALSE) -> month_summaries_til_day
  # month_summaries_til_day

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

if ( do_month_top ) {
  month_summaries_top <- report_monthtop(summaries)
  if ( ! isRStudio ) {
    print(month_summaries_top)
  } else {
    plot.monthly.top <- fetch.plot.monthly.top(month_summaries_til_day)
  }
}

if ( do_month_running ) {
  month_summaries_til_day <- report_monthstatus(summaries)
  if ( ! isRStudio ) {
    print(month_summaries_til_day)
  } else {
    plot.monthly.dist <- fetch.plot.monthly.dist(month_summaries_til_day)
  }
}

if ( do_month_this ) {
  my_month_word <- format(Sys.time(), "%b")
  my_month <- format(Sys.time(), "%m")
  my_year <- format(Sys.time(), "%Y")
  month_summaries_this <- report_runs_year_month(summaries)
  my_month_km <- round(sum(month_summaries_this$Km), digits = 2)
  my_month_pace <- round(mean(month_summaries_this$Pace), digits = 2)
  my_month_runs <- nrow(month_summaries_this)
  if ( ! isRStudio ) {
    print(month_summaries_this)
    print(paste("Totalt ", my_month_runs, " springturer ",
                "under ", my_month_word , " ", my_year, "; ",
                my_month_km, " km, ", my_month_pace,
                " min/km.", sep = ""))
  #} else {
  #  plot.monthly.dist <- fetch.plot.monthly.dist(month_summaries_til_day)
  }
}

if ( do_month_last ) {
  month_summaries_last <- report_monthlast(summaries)
  if ( ! isRStudio ) {
    print(month_summaries_last)
  #} else {
  #  plot.monthly.dist <- fetch.plot.monthly.dist(month_summaries_til_day)
  }
}

if (do_year_running) {
  year_summaries_til_day <- report_yearstatus(summaries)
  if ( ! isRStudio ) {
    print(year_summaries_til_day)
  } # else {
    # plot.monthly.dist <- fetch.plot.monthly.dist(month_summaries_til_day)
  # }
}
if (do_year_top) {
  year_summaries <- report_yearstop(summaries)
  if ( ! isRStudio ) {
    print(year_summaries)
  } # else {
    # plot.monthly.dist <- fetch.plot.monthly.dist(month_summaries_til_day)
  # }
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
           # month = format(sessionStart, "%m"),
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

fetch.plot.sum.dist <- function(summaries) {
  summaries %>%
    filter(str_detect(sport, 'running')) %>%
    mutate(
           year = as.numeric(format(sessionStart, "%Y"))) %>%
    group_by(year) %>%
    summarise(
      dist_max = max(distance),
      dist_sum = sum(distance) / 1000,
      dist_avg = mean(distance, na.rm = TRUE) / 1000,
      .groups = "keep"
      ) %>%
    ggplot(aes(x = as.integer(year), y = dist_sum)) +
      geom_point() +
      geom_smooth(method = 'loess', formula = 'y ~ x') +
      ggtitle("Distans över år") +
      labs(x = "År", y = "Kilometer") -> plot.sum.dist
  return(plot.sum.dist)
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
