# Incidentrapport: Vilopuls saknades i kvällsnotisen 5–7 augusti 2026

**Status:** Backfylld t.o.m. 10 aug; fönstermekanismen experimentellt bekräftad 10 aug; inväntar en reproduktion innan HAE-issue postas (utkast klart)
**Uppdaterad:** 2026-08-10
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

## Uppdatering 2026-08-10: mekanismen bekräftad, backfill klar

Fortsatt utredning 10 aug fastställde följande:

- **Inget namnbyte.** Nyckeln är `resting_heart_rate` i all data och all
  extern konsumentkod 2024–2026; inga okända vilopulsliknande nycklar i
  någon push sedan 20 juli. Metriken utelämnas helt ur automatiska pushar.
- **Bortfallet fortsatte 8–10 aug.** Filerna för 8–9 aug kom via manuell
  export 9 aug 20:23; automatiken levererade noll vilopuls även 10 aug.
- **Diagnostiskt experiment 10 aug (bekräftar fönsterhypotesen):**
  automationens period byttes tillfälligt från "Sedan senaste
  synkronisering" till "Idag". Kontrollpar: automatisk push 19:48 (gamla
  inställningen) utan vilopuls; "Idag"-exporten 19:59 levererade den
  (fil `canonical/resting_heart_rate/2026-08-10.json`). Värdet fanns
  alltså i HealthKit och exporteras felfritt med fast fönster — det är
  inkrementalfönstret som aldrig plockar upp det. Perioden återställd
  till "Sedan senaste synkronisering" efteråt för att invänta en
  reproduktion.
- **Trolig utlösare:** HAE 9.0.15 släpptes 3 aug med release-noten
  "Fixes for automations"; bortfallet började första hela dygnet efter.
- **Ingen befintlig HAE-issue** täcker detta (samtliga 54 issues + 5
  discussions i `Lybron/health-auto-export` genomgångna 10 aug).
  Närmaste prejudikat: #51 (automation tappar sömnsegment; dold flagga)
  och #56 ("Since Last Sync" missar backdaterade samples).
- **Komplett backfill 1 juli–10 aug** via HAE:s MCP-server (HTTP, Bearer-
  token från appens Server-skärm), commit `42404abe8` i datarepot.
  Luckorna var tio (utöver de fem kända även 3/7, 4/7, 8/7, 9/7, 11/7);
  alla fyllda. 28/7 saknar Apple Watch-mätning helt (endast Garmin
  Connect 125 bpm som fallback) — äkta lucka i klockdatan.
- **Datakvalitetsfynd vid backfillen:** HAE:s `aggregate=true` (default,
  hårdkodad i `fetch_tcp`) medelvärdesbildar Apple Watch med Garmin
  Connect till källblandade dygnsvärden som `.connect_contaminated_metrics`
  inte kan rensa; hämtningen gjordes om med `aggregate=false`. Se roadmap.
- **Bifyndet `weight_body_mass`** avskrivet: användaren har inte vägt sig
  sedan 8 juli — ingen bugg.

## Uppföljningsåtgärder

1. **Invänta en reproduktion** (11 aug: automatiska pushar utan
   `resting_heart_rate` trots värde i Hälsa-appen), verifiera på kailash,
   och **posta därefter HAE-issuen** — färdigt språktvättat utkast i
   `tmp/hae_issue_draft.md` (kompletteras först med experimentresultatet
   19:48/19:59-paret); postas till `Lybron/health-auto-export` via `gh`
   efter produktägarens OK. Länka issuen här när den finns.
2. **Tills fixen:** manuell HAE-export med några dagars mellanrum täpper
   gluggen (mottagaren kanoniserar allt; dedup per metrik/dag).
3. **Roadmap-spår** (tillagda 10 aug, se `docs/roadmap.md`):
   HTTP/MCP-läge i hämtningsklienten, `aggregate=false` som default +
   audit av historiskt källblandade värden, per-metrik-staleness-larm i
   `traning doctor`.
