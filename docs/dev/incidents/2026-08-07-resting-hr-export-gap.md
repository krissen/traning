# Incidentrapport: Vilopuls saknades i kvällsnotisen 5–7 augusti 2026

**Status:** Åtgärdad (backfylld); grundorsak uppströms ej slutgiltigt bekräftad
**Allvarlighetsgrad:** Låg — degraderad datakvalitet, inga felaktiga värden
**Rapportdatum:** 2026-08-07

## Sammanfattning

Kvällsnotisens dagsform rapporterade 5–7 augusti att vilopuls saknades
("partial, vilopuls saknas än"). Utredningen visade att felet inte låg i
tRäning-pipelinen: Health Auto Export-appen på telefonen slutade tyst
inkludera metriken `resting_heart_rate` i sina automatiska pushar efter
natten 4→5 augusti, trots att värdena fanns i Apple Health och metriken
var vald i exporturvalet. En manuell export den 7 augusti kl 22:33
backfyllde alla tre dagarna.

## Påverkan

- Readiness-beräkningen körde med kvalitet "partial" i stället för
  "full" 5–7 aug; vilopulskomponenten (och dess avvikelsesignal)
  saknades i morgon- och kvällsnotiser.
- Inga felaktiga värden visades — systemet redovisade korrekt att
  underlaget var ofullständigt.

## Tidslinje (lokal tid)

| Tidpunkt | Händelse |
|---|---|
| 4 aug 23:51 | Sista automatiska HAE-pushen som innehöll vilopuls (52 bpm för 4 aug) |
| 5–7 aug | Automatiska pushar fortsätter normalt (4–8/dygn, ~20–35 metriker) men utan `resting_heart_rate`; övriga klockmetriker (HRV, SpO2, VO2max m.fl.) opåverkade |
| 5–7 aug 21:30 | Kvällsnotisen flaggar "vilopuls saknas än" |
| 7 aug kväll | Utredning: läsvägen (cache → readiness → notistext) verifierad frisk; kanoniska filer bekräftat saknade på kailash; Apple Health bekräftat ha värden t.o.m. 6 aug; HAE:s metrikurval bekräftat ibockat |
| 7 aug 22:33 | Manuell HAE-export (35 metriker, 18 561 samples) levererar vilopuls för 5/8 (51), 6/8 (53) och 7/8 (47 bpm); kanoniska filer skrivna och committade |
| 7 aug ~22:43 | Debounce-importen uppdaterar `health_daily.RData` |

## Grundorsak

Uppströms om tRäning, i HAE-appens automatik. Läsbehörighet och
metrikurval är uteslutna (manuell export fungerade med samma
konfiguration). Starkaste hypotesen är en bugg i automationens
inkrementella exportfönster: Apples vilopulsvärden tidsstämplas
00:01–00:05, precis i dygnsskarven, och kan falla mellan två
exportfönster. Mönstret liknar tidigare HAE-metrikbuggar
(aggregateSleep, issue #51). Ej bekräftat.

## Felsökningsnoteringar

- Serversidan friskrevs snabbt: mottagaren kanoniserar alla inkommande
  metriker utan filtrering, och ingen push 5–7 aug rörde någon
  `resting_heart_rate`-fil — metriken kom aldrig fram.
- Metriken har historiskt varit gluggig enstaka dagar (23/7, 25/7,
  28/7, 30/7, 1/8), vilket maskerade starten av bortfallet; tre dagar i
  rad var det som avvek.
- Falskt spår under utredningen: kailash låg 7 commits före GitHub,
  vilket såg ut som ett push-haveri men är designat beteende
  (`traning-push.timer` pushar en gång per dygn kl 03:00).

## Uppföljningsåtgärder

1. **Bevaka morgondagens automatiska pushar** (8 aug): saknas
   `resting_heart_rate` igen → felanmäl till HAE-utvecklaren med
   tidsstämpelhypotesen.
2. **Överväg per-metrik-staleness-larm** i `traning doctor`/
   freshness-guarden: ett bortfall av en enskild metrik i N dagar
   (medan pipelinen i övrigt är frisk) bör flaggas aktivt i stället
   för att upptäckas via notistexten.
3. **Bifynd att hantera separat:** `weight_body_mass` har inte
   uppdaterats sedan 8 juli (Withings-synken?).
