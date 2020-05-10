#!/usr/local/bin/R

# library(cycleRtools)
library(fitdc)

afile <- "../kristian/filer/fit/2015/2015-01-26_08-54-50-80-12991.fit"

# intervaldata <- read_ride(afile, format = TRUE)
data_mesgs <- read_fit(afile)

is_record <- function(mesg) mesg$name == "record"
records <- Filter(is_record, data_mesgs)

format_record <- function(record) {
  out <- record$fields
  names(out) <- paste(names(out), record$units, sep = ".")
  out
}

records <- lapply(records, format_record)

## Some records have missing fields:

colnames_full <- names(records[[which.max(lengths(records))]])
empty <- setNames(
  as.list(rep(NA, length(colnames_full))),
  colnames_full)

merge_lists <- function(ls_part, ls_full) {
  extra <- setdiff(names(ls_full), names(ls_part))
  append(ls_part, ls_full[extra])[names(ls_full)]  # order as well
}

records <- lapply(records, merge_lists, empty)
records <- data.frame(
  do.call(rbind, records))


head(records)  # voila

my_last_entry <- length(records$distance.m)
my_distance <- records$distance.m[[my_last_entry]]
my_hr_mean <- mean(as.numeric(records$heart_rate.bpm), na.rm = TRUE)
my_hr_max <- max(as.numeric(records$heart_rate.bpm))

my_sp_mean.ms <- mean(as.numeric(records$speed.m.s), na.rm = TRUE)
my_sp_mean.kmh <- my_sp_mean.ms * 3.6
my_sp_mean.minpkm <- 16.666666666667 / my_sp_mean.ms


