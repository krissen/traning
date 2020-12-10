library(tidyverse)
library(lubridate)

# Läs in fil.
df <- read.table("data/export_201110-201210.csv",
                 header = TRUE,
                 sep = ",",
                 fill = TRUE)

# Välj bara datum och puls
# Samt omvandla datum till POSIXct
df %>%
  select(Date, Heart.rate.count.min.) %>%
  filter(!is.na(Heart.rate.count.min.)) %>%
  mutate(Date = as.POSIXct(Date, format="%Y-%m-%d %H:%M:%S")) -> hr

# Välj ut en dag
hr %>%
  filter(str_detect(Date, "2020-12-09")) -> day

# Ställ in när grafen ska börja / sluta i tid
my_xmin <- ymd_h("2020-12-09 06") 
my_xmax <- ymd_h("2020-12-09 13") 

# Ställ in bakgrundsfärger
rect_data <- data.frame(xmin=my_xmin,
                        xmax=my_xmax,
                        ymin=c(50,75,max(day$Heart.rate.count.min.)/1.5),
                        ymax=c(75,max(day$Heart.rate.count.min.)/1.5,max(day$Heart.rate.count.min.)),
                        col=c("green","yellow","red"))

# Tidsstämplar som ska kommenteras
t1 <- as.POSIXct("2020-12-09 08:17:04", tz="")
t2 <- as.POSIXct("2020-12-09 11:59:44", tz="")
t3 <- as.POSIXct("2020-12-09 13:47:02", tz="")

# Kommentarer
annotation <- data.frame(
			 # Tidsstämplar
			 x = c(t1,t2),
			 # Var på y-axeln
			 y = c(100,150),

			 # Kommentarstexter
			 label = c(
				   "Backe",
				   "label 2"
			 )
)

ggplot(data=day, aes(ymin=0)) +
	scale_x_datetime(
			 date_breaks="30 mins",
			 date_labels = "%H:%M",
			 limits = ymd_h(c("2020-12-09 06", "2020-12-09 13"))) +
			 geom_line(aes(x=Date, y=Heart.rate.count.min.),colour="black") +
			 # geom_smooth(aes(x=Date, y=Heart.rate.count.min.),colour="orange",se=FALSE, span=0.1) +
			 geom_rect(data=rect_data, aes(xmin=xmin,xmax=xmax,ymin=ymin,ymax=ymax,fill=col),alpha=0.1) +
			 scale_fill_identity() + 
			 theme(axis.text.x = element_text(angle = 45)) +
			 geom_text(data=annotation, aes( x=x, y=y, label=label),                 , 
				   color=c("orange", "red"), 
				   size=3,
				   angle=90,
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
