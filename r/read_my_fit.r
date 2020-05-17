#!/usr/local/bin/R

# todo: ge info om senast tillagda träningar

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

get_new_workouts <- function(files, summaries, myruns) {
  for ( i in 1:length(files) ) {
    thefile <- files[[i]]
    if ( thefile %in% summaries$file ) {
      cat("Har redan läst in ", thefile, "\n", sep = "")
    } else {
      cat("\nLäser in ", files[[i]], "...", sep = "")
      myruns[[i]] <- read_container(files[[i]])
      cat("\n")
      cat("Skapar summering ...\n")
      run_summary <- summary(myruns[[i]])
      run_summary <- add_my_columns(run_summary)
      cat("Binder ihop\n")
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

# load previously read workouts
my_templist <- my_dbs_load(db_summaries, db_myruns)
summaries <- my_templist[["summaries"]]
myruns <- my_templist[["myruns"]]
rm(my_templist)

# read new workouts if such have been added
files <- get_my_files(mytcxpath)
summaries_oldlength <- count(summaries)
my_templist <- get_new_workouts(files, summaries, myruns)
summaries <- my_templist[["summaries"]]
myruns <- my_templist[["myruns"]]
rm(my_templist)
summaries_newlength <- count(summaries)
summaries_lengthdiff <- as.numeric(summaries_newlength - summaries_oldlength)

# save if workouts were added
if ( summaries_oldlength != summaries_newlength ) {
  cat("New data: ",
      summaries_lengthdiff, " workouts.\n", sep = "")
  cat("Database should be saved.\n")
  #my_dbs_save(db_summaries, db_myruns, summaries, myruns)
}

# oddrun <- read_container("../kristian/filer/tcx/20200202-115430.tcx")

# plot_route(run, maptype = "watercolor")
# plot_route(run, maptype = "terrain")

# runs <- read_directory(mytcxpath)

# plot_route(runs, session = NULL)

# strides <- lapply(my_run, function(x) (60 * x$speed) / (x$cadence_running))

# plot(strides[[1]])

# run_sum <- summary(run)



summaries %>%
  mutate(avgStrideMoving = (
    60 * avgSpeedMoving) / (avgCadenceRunningMoving * 2)) %>%
  mutate(avgStride= (
    60 * avgSpeed) / (avgCadenceRunning* 2)) -> summaries

summaries %>%
  filter(file == 0)

summaries %>%
  filter(str_detect(sport, 'running')) %>%
  mutate(
         #month = format(sessionStart, "%m"),
         year = format(sessionStart, "%Y")
         ) %>%
  group_by(year) %>%
  summarise(totDuration = sum(durationMoving), 
            meanPace = mean(avgPaceMoving),
            minPace = min(avgPaceMoving)
            )

# ta bort rader som matchar
# summaries2 <- summaries[!(summaries$avgPaceMoving == 0),]

#summaries %>%
#  filter(str_detect(file, '../kristian/filer/tcx/20200202-115430.tcx'))




# files %>%
#   .[!grepl("fit/0000", .)] -> files


# vim: ts=2 sw=2 et
