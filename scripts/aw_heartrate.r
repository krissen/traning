library(tidyverse)
library(lubridate)
library(stringr)

# Read file
traning_data <- Sys.getenv("TRANING_DATA")
if (traning_data == "") {
  stop("TRANING_DATA is not set. Copy .Renviron.example to .Renviron and set the path.")
}
df <- read.table(file.path(traning_data, "kristian", "general_metrics", "csv",
                            "export_201120-201220.csv"),
                 header = TRUE,
                 sep = ",",
                 fill = TRUE)

df %>%
  # Choose timestamp and heart rate.
  select(Date, Heart.rate.count.min.) %>%
  filter(!is.na(Heart.rate.count.min.)) %>%
  mutate(
    # Convert timestamp to heart rate
    Date = as.POSIXct(Date, format="%Y-%m-%d %H:%M:%S"),
    # Create a timestamp rounded to 10 minutes
    tenmin = round_date(Date, "10 minutes")) -> hr


# Calculate median heart rate, total
total_aggregate <- aggregate(hr$Heart.rate.count.min., list(avg = hr$tenmin), mean)
hr_mean_total <- mean(total_aggregate$x)


# Pick a day
hr %>%
  filter(str_detect(Date, "2020-12-16")) -> day

# Calculate median heart rate, day
day_aggregate <- aggregate(day$Heart.rate.count.min., list(avg = day$tenmin), mean)
hr_mean_day <- mean(day_aggregate$x)

# 10k run
ts_run_start <- as.POSIXct("2020-12-16 06:35:00")
ts_run_end <- as.POSIXct("2020-12-16 07:30:00")

df_run <- day %>%
  filter(Date >= ts_run_start,
         Date <= ts_run_end)
hr_mean_run <- round(
  mean(df_run$Heart.rate.count.min.),
  digits = 0)

label_run <- str_glue("10k run\nHR: x̅ {hr_mean_run}")

# The Defence
ts_defence_start <- as.POSIXct("2020-12-16 10:00:00")
ts_defence_end <- as.POSIXct("2020-12-16 12:25:00")

df_defence <- day %>%
  filter(Date >= ts_defence_start,
         Date <= ts_defence_end)
hr_mean_defence <- round(
  mean(df_defence$Heart.rate.count.min.),
  digits = 0)

label_defence <- str_glue("The defence\nHR: x̅ {hr_mean_defence}")

# Social event
ts_social_start <- as.POSIXct("2020-12-16 13:40:00")
ts_social_end <- as.POSIXct("2020-12-16 15:30:00")
df_social <- day %>%
  filter(Date >= ts_social_start,
         Date <= ts_social_end)
hr_mean_social <- round(
  mean(df_social$Heart.rate.count.min.),
  digits = 0)

label_social <- str_glue("Social event\nHR: x̅ {hr_mean_social}")

# Set when plot should begin / end
day_xmin <- ymd_h("2020-12-16 05") 
day_xmax <- ymd_h("2020-12-16 18") 

hr_max_day <- max(day$Heart.rate.count.min.)
hr_max <- 180

day$hr_mean_day <- hr_mean_day
hr_mean_day_rounded <- round(hr_mean_day, digits = 0)
label_day <- str_glue("HR, day (x̅ {hr_mean_day_rounded})")
day$hr_mean_total <- hr_mean_total
hr_mean_total_rounded <- round(hr_mean_total, digits = 0)
label_month <- str_glue("HR, month (x̅ {hr_mean_total_rounded})")

hrz5 <- hr_max * 0.90 	# Maximum
hrz4 <- hr_max * 0.80 	# Hard
hrz3 <- hr_max * 0.70 	# Moderate
hrz2 <- hr_max * 0.60 	# Light
hrz1 <- hr_max * 0.50 	# Very light

#FF0000	Bad
#FFFF00	Bad-Average
#FFFF00	Average
#7FFF00	Average-Good
#00FF00	Good

# Set background colours by heart rate zones
rect_data <- data.frame(xmin = day_xmin,
                        xmax = day_xmax,
                        ymin = c(0, hrz1, hrz2, hrz3, hrz4),
                        ymax = c(hrz1, hrz2, hrz3, hrz4, hrz5),
                        col=c("#00FF00", "#7FFF00", "#FFFF00",
                              "#FFA500", "#FF0000"))

# 100% — FF
# 95% — F2
# 90% — E6
# 85% — D9
# 80% — CC
# 75% — BF
# 70% — B3
# 65% — A6
# 60% — 99
# 55% — 8C
# 50% — 80
# 45% — 73
# 40% — 66
# 35% — 59
# 30% — 4D
# 25% — 40
# 20% — 33
# 15% — 26
# 10% — 1A
# 5% — 0D
# 0% — 00

# startplot
ggplot(data=day, aes(ymin=0)) +
  theme_bw() +
  # theme(panel.border = element_blank()) +
  theme(panel.border = element_blank(), panel.grid.major = element_blank(),
        panel.grid.minor = element_blank(),
        axis.line = element_line(colour = "black")) +
  scale_x_datetime(
    date_breaks="2 hours",
    date_labels = "%H:%M",
    limits = as.POSIXct(c("2020-12-16 06:00", "2020-12-16 19:00"))) +
  geom_line(aes(x=Date, y=Heart.rate.count.min.), colour="black",
            size = 1.15) +
  # alpha = 0.75) +
  # HR mean, month
  geom_line(aes(x=Date, y=hr_mean_total),colour="blue", alpha = 0.3) +
  annotate("text", x=as.POSIXct("2020-12-16 07:30:00"), y=62,
           label= label_month,
           colour = "#0000ff80",
           family="Helvetica", size = 3) +
  # HR mean for day
  geom_line(aes(x=Date, y=hr_mean_day),colour="purple", alpha = 0.3) +
  annotate("text", x=as.POSIXct("2020-12-16 18:11:00"), y=77,
           label= label_day,
           colour = "#6A0DAD80",
           family="Helvetica", size = 3) +
  geom_rect(data=rect_data, aes(xmin=xmin,xmax=xmax,
                                ymin=ymin,ymax=ymax,
                                fill=col),alpha=0.05) +
  scale_fill_identity() + 
  geom_vline(xintercept = ts_run_start,
             size = 0.5, colour = "#00000033",
             linetype = "dashed") +
  geom_label(aes(x = as.POSIXct("2020-12-16 06:40:00"),
                 y = 10, label = label_run), 
             hjust = 0, vjust = 0.5, 
             colour = "#555555", fill = "#FFFFFFCC", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  geom_vline(xintercept = ts_run_end,
             size = 0.5, colour = "#00000033", linetype = "dashed") +
  # The defence
  geom_vline(xintercept = ts_defence_start,
             size = 0.5, colour = "#FF000066", linetype = "dashed") +
  geom_label(aes(x = as.POSIXct("2020-12-16 10:05:00"),
                 y = 10, label = label_defence), 
             hjust = 0, vjust = 0.5, 
             colour = "#555555", fill = "#FFFFFF4D", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  geom_vline(xintercept = ts_defence_end,
             size = 0.5, colour = "#FF00004D", linetype = "dashed") +
  # Discussion starts.
  geom_curve(aes(x = as.POSIXct("2020-12-16 15:59:00"), y = 150,
                 xend = as.POSIXct("2020-12-16 10:42:00"), yend = 95), 
             colour = "#555555", 
             size=0.5, 
             curvature = 0.35,
             arrow = arrow(length = unit(0.01, "npc"))) +
  geom_label(aes(x = as.POSIXct("2020-12-16 16:00:00"),
                 y = 150, label = "Discussion proper begins"), 
             hjust = 0, vjust = 0.4, 
             colour = "#555555",
             # fill = "#FFFFFF4D", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  # Grading committee returns
  geom_curve(aes(x = as.POSIXct("2020-12-16 15:59:00"), y = 139,
                 xend = as.POSIXct("2020-12-16 13:23:00"), yend = 95), 
             colour = "#555555", 
             size=0.5, 
             curvature = 0.3,
             arrow = arrow(length = unit(0.01, "npc"))) +
  geom_label(aes(x = as.POSIXct("2020-12-16 16:00:00"),
                 y = 139, label = "Decision announced"), 
             hjust = 0, vjust = 0.4, 
             colour = "#555555",
             # fill = "#FFFFFF4D", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  # Social event
  geom_vline(xintercept = ts_social_start,
             size = 0.5, colour = "#00000033",
             linetype = "dashed") +
  geom_label(aes(x = as.POSIXct("2020-12-16 13:43:00"),
                 y = 10, label = label_social), 
             hjust = 0, vjust = 0.5, 
             colour = "#555555", fill = "#FFFFFFCC", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  geom_vline(xintercept = ts_social_end,
             size = 0.5, colour = "#00000033", linetype = "dashed") +
  # Carrying stuff
  geom_label(aes(x = as.POSIXct("2020-12-16 16:02:00"),
                 y = 128, label = "Carrying stuff"), 
             hjust = 0, vjust = 0.4, 
             colour = "#555555",
             # fill = "#FFFFFF4D", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  geom_curve(aes(x = as.POSIXct("2020-12-16 15:59:00"), y = 130,
                 xend = as.POSIXct("2020-12-16 15:25:00"), yend = 95), 
             colour = "#555555", 
             size=0.5, 
             curvature = 0.5,
             arrow = arrow(length = unit(0.01, "npc"))) +
  geom_curve(aes(x = as.POSIXct("2020-12-16 15:59:00"), y = 130,
                 xend = as.POSIXct("2020-12-16 16:20:00"), yend = 95), 
             colour = "#555555", 
             size=0.5, 
             curvature = 0.55,
             arrow = arrow(length = unit(0.01, "npc"))) +
  labs(title = "Day of dissertation defence",
       x = NULL,
       y = "Heartrate") -> hrplot
# endplot

ggsave("hr_Dissertation_defence.png", plot = hrplot, 
       width = 8, height = 4, dpi = "print")

# endplot

# vim: ts=2 sw=2 et
