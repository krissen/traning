# Garmin CSV till plots
#   från: https://www.r-bloggers.com/garmonbozia-using-r-to-look-at-garmin-csv-data/
#
require(ggplot2)
require(dplyr)
require(hms)
require(directlabels)
require(GGally)
require(gplots)
#file_name <- file.choose()
traning_data <- Sys.getenv("TRANING_DATA")
if (traning_data == "") {
  stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
}
file_name <- file.path(traning_data, "kristian", "filer", "csv", "070102-191231.csv")
df1 <- read.csv(file_name, header = TRUE, stringsAsFactors = FALSE)


# format Date column to POSIXct
df1$Datum <- as.POSIXct(strptime(df1$Datum, format = "%Y-%m-%d %H:%M:%S"))
# format Avg.Pace to POSIXct
df1$MedeltempoPosix <- as.POSIXct(strptime(df1$Medeltempo, format = "%M:%S"))
# make groups of different distances using ifelse
df1$Type <- ifelse(df1$Sträcka < 7, "< 7 km", ifelse(df1$Sträcka < 12, "7-12 km", ifelse(df1$Sträcka < 22, "12-22 km", ifelse(df1$Sträcka < 32, "22-32 km", ifelse(df1$Sträcka < 43, "32-43 km", "> 43 km")))))
# make factors for these so that they're in the right order when we make the plot
df1$Type_f = factor(df1$Type, levels=c("< 7 km","7-12 km","12-22 km","22-32 km","32-43 km","> 43 km"))

# plot out average pace over time
p1 <- ggplot( data = df1, aes(x = Datum,y = MedeltempoPosix, color = Sträcka)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth(color = "orange") +
  ggtitle("Medeltempo över distans och tid") + 
  labs(x = "Datum", y = "Medeltempo (min/km)")

# plot out same data grouped by distance
p2 <- ggplot( data = df1, aes(x = Datum,y = MedeltempoPosix, group = Type_f, color = Type_f)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth() +
  theme(legend.position = "none") +
  ggtitle("Medeltempo över tid grupperat efter distans") + 
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
  theme(axis.text.x=element_text(angle=90,hjust=1), legend.position = "none") +
  ggtitle("Medelsteglängd över tid, grupperat efter distans") +
  labs(x = "Datum", y = "Medelsteglängd (m)", colour = NULL) +
  facet_grid(~Type_f)

p9 <- ggplot(data = df1, aes(x = Datum,y = Medelsteglängd, group = Type_f, color = Type_f)) +
  geom_point() +
  ylim(0, NA) + xlim(as.POSIXct(earliest_date), as.POSIXct(latest_date)) +
  geom_smooth() +
  ggtitle("Medelsteglängd över tid") +
  labs(x = "Datum", y = "Medelsteglängd (m)", colour = NULL)

# HEARTRATE
df1$Medelpuls <- as.numeric(as.character(df1$Medelpuls))

p4 <- ggplot(data = df1, aes(x = Datum,y = Medelpuls, group = Type_f, color = Type_f)) +
  geom_point() +
  ylim(0, NA) + xlim(as.POSIXct(earliest_date), as.POSIXct(latest_date)) +
  geom_smooth() +
  theme(axis.text.x=element_text(angle=90,hjust=1), legend.position = "none") +
  ggtitle("Medelpuls över tid, grupperat efter distans") +
  labs(x = "Datum", y = "Medelpuls (bpm)", colour = NULL) +
  facet_grid(~Type_f)

# plot out average pace per distance coloured by year
p5 <- ggplot( data = df1, aes(x = Sträcka,y = MedeltempoPosix, color = Datum)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth(color = "orange") +
  ggtitle("Medeltempo över sträcka") +
  labs(x = "Sträcka (km)", y = "Medeltempo (min/km)")

# plot stride per tempo
p10 <- ggplot( data = df1, aes(x = MedeltempoPosix,y = Medelsteglängd, color = Type_f)) +
  geom_point() +
  scale_x_datetime(date_labels = "%M:%S") +
  geom_smooth(color = "orange") +
  ggtitle("Medeltempo över medelsteglängd") +
  labs(y = "Medeltempo (min/km)", x = "Medelsteglängd (m)", colour = "Distans")

# make a date factor for year to group the plots
df1$År <- format(as.Date(df1$Datum, format="%d/%m/%Y"),"%Y")
p6 <- ggplot( data = df1, aes(x = Sträcka,y = MedeltempoPosix, group = År, color = År)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth() +
  theme(axis.text.x=element_text(angle=90,hjust=1), legend.position = "none") +
  ggtitle("Sträcka över medeltempo, grupperat efter år") +
  labs(x = "Sträcka", y = "Medeltempo (min/km)") +
  facet_grid(~År)

df1$Månad <- as.numeric(format(as.Date(df1$Datum, format="%d/%m/%Y"),"%m"))
df1$Kvartal <- ifelse(df1$Månad < 4, "jan-mar", ifelse(df1$Månad < 7, "apr-jun", ifelse(df1$Månad < 10, "jul-sep", "okt-dec")))
df1$Kvartal_n <- ifelse(df1$Månad < 4, 1, ifelse(df1$Månad < 7, 2, ifelse(df1$Månad < 10, 3, 4)))
df1$Kvartal_f = factor(df1$Kvartal, levels=c("jan-mar","apr-jun","jul-sep","okt-dec"))

p11 <- ggplot( data = df1, aes(x = Datum, y = MedeltempoPosix, group = Kvartal_f, color = Kvartal_f)) +
  geom_point() +
  scale_y_datetime(date_labels = "%M:%S") +
  geom_smooth() +
  ggtitle("Medeltempo över tid grupperat efter kvartal") +
  theme(legend.position = "none") +
  labs(x = "Datum", y = "Medeltempo (min/km)", group = "Kvartal", colour = NULL) +
  facet_grid(~Kvartal_f)

# räkna med tempo
idag <- as.POSIXct(strptime("00:00", format = "%M:%S"))
df1$MedeltempoSec <- as.numeric(df1$MedeltempoPosix - idag)

# räkna ut tempo i medeltal per typ
# tempoTypeMean <- df1 %>%
#   + group <- by(Type <- f) %>%
#   + summarize(mean(MedeltempoSec, na.rm=T))

# myAverages = df1 %>%
#   group <- by(Type <- f) %>%
#   mutate(myAvg=round(mean(MedeltempoSec),2))
# p <- ggplot(myAverages, aes(df1$Datum, df1$MedeltempoSec)) +
#     geom <- point() + facet <- grid(. ~ df1$Type <- f) +
#     geom <- text(aes(df1$Datum, df1$MedeltempoSec,label = myAvg), size = 200, x = 5, y = 5)

# pTTmeans <- plotmeans(MedeltempoSec ~ Type_f, data = df1, frame = F, mean.labels = T)

# tempo över kvartal:
# format(median(df1$MedeltempoPosix[df1$Kvartal == "jan-mar"], na.rm=T), "%M:%S")
cp1 <- ggcorr(cbind("tempo"=df1$MedeltempoSec, "steg"=df1$Medelsteglängd, "kvartal"=df1$Kvartal_n, "år"=as.numeric(df1$År), "sträcka"=df1$Sträcka, "stigning"=as.numeric(df1$Stigning)), method = c("pairwise.complete.obs", "pearson"), label = TRUE, label_round = 3)

# Cumulative sum over years
df1 <- df1[order(as.Date(df1$Datum)),]
df1 <- df1 %>% group_by(År) %>% mutate(cumsum = cumsum(Sträcka))
p7 <- ggplot( data = df1, aes(x = Datum,y = cumsum, group = År, color = År)) +
  geom_line() +
  ggtitle("Kumulativ sträcka per år") +
  labs(x="Dagar",y="Sträcka (km)",colour="År")

# Plot these cumulative sums overlaid
# Find New Year's Day for each and then work out how many days have elapsed since
df1$nyd <- paste(df1$År,"-01-01",sep = "")
df1$Dagar <- as.Date(df1$Datum, format="%Y-%m-%d") - as.Date(as.character(df1$nyd), format="%Y-%m-%d")
# Make the plot
p8 <- ggplot( data = df1, aes(x = Dagar,y = cumsum, group = År, color = År)) +
  geom_line() +
  scale_colour_discrete(guide = 'none') +
  # geom_dl(aes(label = År), method = list(dl.trans(x = x + 0.2), "last.points", cex = 0.8)) +
  geom_dl(aes(label = År), method = list(hjust= -.7,vjust = -.7, "last.points", cex = 0.8)) +
  ggtitle("Kumulativ sträcka under åren") +
  # margin : top right bottom left
  # theme(plot.margin=unit(c(1,1.5,1.5,1),"cm")) +
  labs(x="Dagar",y="Sträcka (km)",colour=NULL)


# save all plots
ggsave("tempoOverStracka.png", plot = p1, width = 8, height = 4, dpi = "print")
ggsave("tempo-grpDistans.png", plot = p2, width = 8, height = 4, dpi = "print")
# ggsave("tempo-grpDistans-means.png", plot = pTTmeans, width = 8, height = 4, dpi = "print")
ggsave("steglangdOverTid-grpDistans.png", plot = p3, width = 8, height = 4, dpi = "print")
ggsave("steglangdOverTid.png", plot = p9, width = 8, height = 4, dpi = "print")
ggsave("stegOverTempo.png", plot = p10, width = 8, height = 4, dpi = "print")
ggsave("pulsOverTid-grpDistans.png", plot = p4, width = 8, height = 4, dpi = "print")
ggsave("tempoPerDistans.png", plot = p5, width = 8, height = 4, dpi = "print")
ggsave("tempoPerStracka-grpAr.png", plot = p6, width = 8, height = 4, dpi = "print")
ggsave("kumulativDistansOverAr.png", plot = p7, width = 8, height = 4, dpi = "print")
ggsave("kumulativDistansUnderAren.png", plot = p8, width = 8, height = 6, dpi = "print")
ggsave("medeltempoOverTid-grpKvartal.png", plot = p11, width = 8, height = 4, dpi = "print")
ggsave("corrplot.png", plot = cp1, width = 8, height = 8, dpi = "print")
