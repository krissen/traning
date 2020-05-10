#!/usr/local/bin/R

library(cycleRtools)

afile <- "../kristian/filer/fit/2015/2015-01-26_08-54-50-80-12991.fit"

intervaldata <- read_ride(afile, format = TRUE)
