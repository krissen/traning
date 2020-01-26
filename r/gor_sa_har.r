# Garmin CSV till plots
#   från: https://www.r-bloggers.com/garmonbozia-using-r-to-look-at-garmin-csv-data/
#
require(ggplot2)
require(dplyr)
require(hms)
file_name <- file.choose()
df1 <- read.csv(file_name, header = TRUE, stringsAsFactors = FALSE)


# format Date column to POSIXct
df1$Datum <- as.POSIXct(strptime(df1$Datum, format = "%Y-%m-%d %H:%M:%S"))
# format Avg.Pace to POSIXct
df1$Medeltempo <- as.POSIXct(strptime(df1$Medeltempo, format = "%M:%S"))
# make groups of different distances using ifelse
df1$Type <- ifelse(df1$Sträcka < 7, "< 7 km", ifelse(df1$Sträcka < 12, "7-12 km", ifelse(df1$Sträcka < 22, "12-22 km", ifelse(df1$Sträcka < 32, "22-32 km", ifelse(df1$Sträcka < 43, "32-43 km", "> 43 km")))))
# make factors for these so that they're in the right order when we make the plot
df1$Type_f = factor(df1$Type, levels=c("< 7 km","7-12 km","12-22 km","22-32 km","32-43 km","> 43 km"))

# plot out average pace over time
p1 <- ggplot( data = df1, aes(x = Datum,y = Medeltempo, color = Sträcka)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth(color = "orange") +
  labs(x = "Datum", y = "Medeltempo (min/km)")


# plot out same data grouped by distance
p2 <- ggplot( data = df1, aes(x = Datum,y = Medeltempo, group = Type_f, color = Type_f)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth() +
  labs(x = "Datum", y = "Medeltempo (min/km)", colour = NULL) +
  facet_grid(~Type_f)

# now look at stride length. first remove zeros
df1[df1 == 0] <- NA
# now find earliest valid date
date_v <- df1$Datum
# change dates to NA where there is no avg stride data
date_v <- as.Date.POSIXct(ifelse(df1$Medelsteglängd > 0, df1$Datum, NA))
# find min and max for x-axis
earliest_date <- min(date_v, na.rm = TRUE)
latest_date <- max(date_v, na.rm = TRUE)
# make the plot
p3 <- ggplot(data = df1, aes(x = Datum,y = Medelsteglängd, group = Type_f, color = Type_f)) +
  geom_point() +
  ylim(0, NA) + xlim(as.POSIXct(earliest_date), as.POSIXct(latest_date)) +
  geom_smooth() +
  theme(axis.text.x=element_text(angle=90,hjust=1)) +
  labs(x = "Datum", y = "Medelsteglängd (m)", colour = NULL) +
  facet_grid(~Type_f)


# HEARTRATE
df1$Medelpuls <- as.numeric(as.character(df1$Medelpuls))

p4 <- ggplot(data = df1, aes(x = Datum,y = Medelpuls, group = Type_f, color = Type_f)) +
  geom_point() +
  ylim(0, NA) + xlim(as.POSIXct(earliest_date), as.POSIXct(latest_date)) +
  geom_smooth() +
  theme(axis.text.x=element_text(angle=90,hjust=1)) +
  labs(x = "Datum", y = "Medelpuls (bpm)", colour = NULL) +
  facet_grid(~Type_f)

# plot out average pace per distance coloured by year
p5 <- ggplot( data = df1, aes(x = Sträcka,y = Medeltempo, color = Datum)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth(color = "orange") +
  labs(x = "Sträcka (km)", y = "Medeltempo (min/km)")


# make a date factor for year to group the plots
df1$År <- format(as.Date(df1$Datum, format="%d/%m/%Y"),"%Y")
p6 <- ggplot( data = df1, aes(x = Sträcka,y = Medeltempo, group = År, color = År)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth() +
  theme(axis.text.x=element_text(angle=90,hjust=1)) +
  labs(x = "Sträcka", y = "Medeltempo (min/km)") +
  facet_grid(~År)

# Cumulative sum over years
df1 <- df1[order(as.Date(df1$Datum)),]
df1 <- df1 %>% group_by(År) %>% mutate(cumsum = cumsum(Sträcka))
p7 <- ggplot( data = df1, aes(x = Datum,y = cumsum, group = År, color = År)) +
  geom_line() +
  labs(x = "Datum", y = "Kumulativ sträcka (km)")

# Plot these cumulative sums overlaid
# Find New Year's Day for each and then work out how many days have elapsed since
df1$nyd <- paste(df1$År,"-01-01",sep = "")
df1$Dagar <- as.Date(df1$Datum, format="%Y-%m-%d") - as.Date(as.character(df1$nyd), format="%Y-%m-%d")
# Make the plot
p8 <- ggplot( data = df1, aes(x = Dagar,y = cumsum, group = År, color = År)) +
  geom_line() +
  scale_x_continuous() +
  labs(x = "Dagar", y = "Kumulativ sträcka (km)")


# save all plots
ggsave("allPace.png", plot = p1, width = 8, height = 4, dpi = "print")
ggsave("paceByDist.png", plot = p2, width = 8, height = 4, dpi = "print")
ggsave("strideByDist.png", plot = p3, width = 8, height = 4, dpi = "print")
ggsave("HRByDist.png", plot = p4, width = 8, height = 4, dpi = "print")
ggsave("allPaceByDist.png", plot = p5, width = 8, height = 4, dpi = "print")
ggsave("paceByDistByYear.png", plot = p6, width = 8, height = 4, dpi = "print")
ggsave("cumulativeDistByYear.png", plot = p7, width = 8, height = 4, dpi = "print")
ggsave("cumulativeDistOverlay.png", plot = p8, width = 8, height = 4, dpi = "print")

