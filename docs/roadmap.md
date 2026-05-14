# tRäning — Roadmap

## Dashboard

- **Fun facts-panel.** Liten widget på Översikt eller Utveckling med
  småroliga statistik-snuttar: totalt antal pass per sport, första
  registrerade pass, längsta uppehåll mellan löpturer, hela kalender­
  månader utan ett enda pass, etc. Ska kännas som "did you know" snarare
  än som verktyg.
- **Δ-staplar mediantempo per vecka.** Per-vecka motsvarighet till
  P01a_v09-konceptet (som sparkades för år-versionen). Stapel under noll
  = veckan blev snabbare än föregående vecka. Använder det vanliga
  globala tidsfiltret. Bra för att se ryckiga upp/ned-perioder vs jämn
  träning.

## Bugs

- **Globalt tidsfilter "Allt" visar bara 1 år.** Träningsfliken (och
  möjligen fler flikar) respekterar 5 år och kortare presets korrekt,
  men "Allt" verkar tappa till senaste 1 året. Kontrollera **alla**
  figurer på **alla** sidor och säkerställ att alla följer det valda
  filtret konsistent.

## Defaults

- **Sport-mix.** Förvalt mått ska vara **TRIMP**, inte distans (som
  ligger först i nuvarande val).
- **Kronisk belastning.** Förvalda sporter ska vara cykling, gång,
  löpning, paddelsporter och styrketräning (idag annan default).

## Prestation-fliken

- **Tomt veckokilometer-fält i EF och aerob decoupling.** Båda figurerna
  har ett veckokilometer-fält som idag är tomt. Lokalisera kopplingen
  mellan plot och underliggande aggregering och fyll i fältet, eller
  ta bort det om det inte är meningsfullt här.
- **Outliers i aerob decoupling.** Med period="allt" finns en eller två
  rejäla outliers någonstans i mitten av datat som ser visuellt suspekta
  ut. Undersök: är det dåligt mätta sessioner (HR-drift utan kontroll),
  felaktiga TCX, eller äkta extremvärden? Avgör sedan om de ska filtreras
  bort, vinsoriseras, eller markeras separat.
