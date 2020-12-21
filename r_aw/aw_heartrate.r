if(!require(pacman))install.packages("pacman")
library(tidyverse)
library(lubridate)

pacman::p_load('dplyr', 'tidyr',
               'ggplot2',  'ggalt',
               'forcats', 'R.utils', 'png', 
               'grid', 'ggpubr', 'scales',
               'bbplot')

# Läs in fil.
df <- read.table("data/export_201120-201220.csv",
                 header = TRUE,
                 sep = ",",
                 fill = TRUE)

# Välj bara datum och puls
# Samt omvandla datum till POSIXct
df %>%
  select(Date, Heart.rate.count.min.) %>%
  filter(!is.na(Heart.rate.count.min.)) %>%
  mutate(Date = as.POSIXct(Date, format="%Y-%m-%d %H:%M:%S")) -> hr


# Medelpuls, tidsperiod totalt
hr_mean_total <- mean(hr$Heart.rate.count.min.)


# Välj ut en dag
hr %>%
  filter(str_detect(Date, "2020-12-16")) -> day

# Medelpuls, dag totalt
hr_mean_day <- mean(day$Heart.rate.count.min.)

# Ställ in när grafen ska börja / sluta i tid
day_xmin <- ymd_h("2020-12-16 05") 
day_xmax <- ymd_h("2020-12-16 18") 

hr_max_day <- max(day$Heart.rate.count.min.)
hr_max <- 180

day$hr_mean_day <- hr_mean_day
day$hr_mean_total <- hr_mean_total

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

# Ställ in bakgrundsfärger
rect_data <- data.frame(xmin = day_xmin,
                        xmax = day_xmax,
                        ymin = c(0, hrz1, hrz2, hrz3, hrz4),
                        ymax = c(hrz1, hrz2, hrz3, hrz4, hrz5),
                        col=c("#00FF00", "#7FFF00", "#FFFF00",
                              "#FFA500", "#FF0000"))

# Tidsstämplar som ska kommenteras
t1 <- as.POSIXct("2020-12-16 07:00:00", tz="")
t2 <- as.POSIXct("2020-12-16 10:00:00", tz="")
t3 <- as.POSIXct("2020-12-16 13:47:02", tz="")

# Kommentarer
annotation <- data.frame(
			 # Tidsstämplar
			 x = c(t1,t2),
			 # Var på y-axeln
			 y = c(20,20),

			 # Kommentarstexter
			 label = c(
				   "10 km run",
				   "Defence starts"
			 )
)

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


ggplot(data=day, aes(ymin=0)) +
  scale_x_datetime(
    # date_breaks="4 hours",
    date_breaks="2 hours",
    date_labels = "%H:%M",
    # limits = ymd_h(c("2020-12-16 05", "2020-12-16 18"))) +
    limits = as.POSIXct(c("2020-12-16 06:00", "2020-12-16 19:00"))) +
  geom_line(aes(x=Date, y=Heart.rate.count.min.),colour="black", alpha = 0.75) +
  geom_line(aes(x=Date, y=hr_mean_total),colour="blue", alpha = 0.2) +
  geom_line(aes(x=Date, y=hr_mean_day),colour="purple", alpha = 0.3) +
  # geom_smooth(aes(x=Date, y=Heart.rate.count.min.),colour="blue",se=FALSE, span=0.010) +
  # geom_smooth(aes(x=Date, y=Heart.rate.count.min.),colour="orange",se=FALSE, span=0.025) +
  geom_rect(data=rect_data, aes(xmin=xmin,xmax=xmax,ymin=ymin,ymax=ymax,fill=col),alpha=0.05) +
  scale_fill_identity() + 
  # bbc_style() +
  # multiple_line + 
  geom_vline(xintercept = as.POSIXct("2020-12-16 06:35:00"),
             size = 0.5, colour = "#00000033",
             linetype = "dashed") +
  geom_label(aes(x = as.POSIXct("2020-12-16 06:40:00"), y = 25, label = "10k run"), 
             hjust = 0, vjust = 0.5, 
             colour = "#555555", fill = "#FFFFFFCC", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  geom_vline(xintercept = as.POSIXct("2020-12-16 07:30:00"),
             size = 0.5, colour = "#00000033", linetype = "dashed") +
  geom_vline(xintercept = as.POSIXct("2020-12-16 10:00:00"),
             size = 0.5, colour = "#FF000066", linetype = "dashed") +
  geom_label(aes(x = as.POSIXct("2020-12-16 10:05:00"), y = 25, label = "The defence"), 
             hjust = 0, vjust = 0.5, 
             colour = "#555555", fill = "#FFFFFF4D", 
             label.size = NA, 
             family="Helvetica", size = 3) +
  geom_vline(xintercept = as.POSIXct("2020-12-16 12:30:00"),
             size = 0.5, colour = "#FF00004D", linetype = "dashed") +
  geom_curve(aes(x = as.POSIXct("2020-12-16 06:30:00"), y = 45,
                 xend = as.POSIXct("2020-12-16 07:00:00"), yend = 43), 
             colour = "#555555", 
             size=0.5, 
             curvature = -0.2,
             arrow = arrow(length = unit(0.03, "npc")))
  # theme(axis.text.x = element_text(angle = 45)) +
  geom_text(data=annotation, aes( x=x, y=y, label=label),                 , 
            color=c("black", "black"), 
            size=3,
            angle=90,
            alpha = 0.5,
            fontface="italic" )


# Test med pil och kommentar.
# Funkar men känns klumpigt.
# p + geom_curve(aes(x = t1, y = 100, xend = t2, yend = 80), 
# 		colour = "#FF0000", 
# 		size=0.5, 
# 		curvature = -0.2,
# 		arrow = arrow(length = unit(0.03, "npc"))) + 

# geom_label(aes(x = t1, y = 100, label = "Here is the\nUnicode symbol"), 
# 	    hjust = 0, 
# 	    vjust = 0.5, 
# 	    colour = "#FAAB18", 
# 	    # fill = "white", 
# 	    label.size = NA, 
# 	    family="Helvetica", 
# 	    size = 3)
