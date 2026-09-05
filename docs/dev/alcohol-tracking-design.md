# Alcohol tracking and next-morning recovery — design

## Goal

Make the energy in alcohol visible, and show what it coincides with the
next morning, without false precision and without moralising. Alcohol
energy is close to invisible in the consumption experience: it satiates
poorly, does not look like food, and is booked mentally as "a drink".

Two things ship in this phase:

- A daily and weekly **energy account** — how many drinks, how much
  energy from the alcohol, and what share of energy expenditure that is.
- A **next-morning comparison** against an alcohol-free baseline, added
  to the daily line only when a recovery metric has actually moved.

A third thing is specified but deliberately not built: a personal
dose-response statement. See "Future: dose-response".

## Data source

### The metric

Health Auto Export publishes HealthKit's alcohol record as
`alcohol_consumption`, in units of `count`. The writing app is
**DrinkControl**, which logs drinks on the phone and writes them to
Health.

DrinkControl writes a second record at the same timestamp:
`dietary_energy`, in kJ. Observed on 2026-09-05, the first exported day:

| Record | Value | Time | Source |
|---|---|---|---|
| `alcohol_consumption` | 5.9999 count | 18:44 | DrinkControl |
| `dietary_energy` | 1768.3 kJ | 18:44 | DrinkControl |

1768.3 kJ is 422.6 kcal, which over six drinks is 70.4 kcal per drink.

### DrinkControl's unit and its energy

DrinkControl is configured for **10 g of ethanol per drink**, the WHO
unit. DrinkControl's support pages (retrieved 2026-09-05) define the
standard drink per jurisdiction and give 10 g for the World Health
Organization, Australia, Ireland, Italy, Poland, Spain and Germany, 14 g
for the United States, about 8 g for the United Kingdom and 13.45 g for
Canada. Sweden is not among the options.

The energy density of ethanol is **7 kcal/g**, the conversion factor for
alcohol set in Annex XIV of Regulation (EU) No 1169/2011, which is the
binding factor for nutrition labelling in Sweden. DrinkControl uses the
same value in its own documentation: "One gram of ethyl alcohol yields
seven Calories". Ten grams therefore gives 70 kcal against the observed
70.4, a 0.6 % difference.

An earlier draft of this document used 7.1 kcal/g. That figure is a
physiological-net value with no standing in EU labelling law, and it is
not the value DrinkControl computes with. The constant is 7 throughout
this document, including in the fallback in decision 1.

The energy DrinkControl writes is **ethanol energy, not total beverage
energy**, which the app states directly: it reports alcohol calories and
excludes calories from other beverage components, on the grounds that
those vary too much between products.

The arithmetic confirms this. A 50 cl beer at 5.2 % holds about 20.5 g
of ethanol, so 2.05 WHO units. Systembolaget publishes 47 kcal per 10 cl
for a 5.6 % strong beer; of that, 31 kcal is ethanol by the EU factor,
leaving about 16 kcal per 10 cl of residual carbohydrate. Applying the
same residual to a 5.2 % beer gives roughly 225 kcal for 50 cl, about
110 kcal per WHO unit. The observed 70.4 sits well below that and
matches ethanol alone.

One caveat on the ethanol-only property: DrinkControl's per-drink-type
calorie values are user-editable, and its documentation says an edited
value feeds the figure synced to Apple Health. The property holds until
someone changes a drink type in the app's settings.

Two units are in play, and conflating them is the easiest way to get
every figure in this feature wrong:

| Unit | Grams of ethanol |
|---|---|
| DrinkControl count | 10 |
| Swedish standardglas | 12 |

Conversion: `standardglas = count × 10 / 12`, that is `count × 0.833`.
Never multiply the raw count by 12 g.

If the DrinkControl setting is ever changed, every historical figure
moves with it. The setting is therefore recorded here as a decision, not
inferred at runtime, and a change to it is a migration.

### What the source does not provide

HealthKit's alcohol record is a bare count. Apple's own definition is
qualitative: a quantity type measuring "the number of standard alcoholic
drinks that the user has consumed", where "A standard drink is one beer,
glass of wine, or mixed drink made with spirits". There is **no drink
type, no volume and no alcohol percentage** in the type, no gram-ethanol
equivalence, and DrinkControl exports none of them even though it holds
them internally. This constrains the design more than anything else and
is the reason for decision 2.

**Nor is there a drink time.** The alcohol record arrived as a single
aggregated row for the day, not one row per drink, and the timestamp on
it is the time the export ran rather than the time anything was drunk.
The 18:44 in the table above is an export clock reading. Nothing in the
current feed carries when a drink was actually taken, and it is not yet
established whether the aggregation happens inside DrinkControl or
inside Health Auto Export. Logging two drinks several hours apart and
re-exporting would settle it.

This matters because timing is one of the few things the literature
identifies as actionable. Grosicki et al. (2026) found that drinking 60
minutes earlier than usual, compared with 60 minutes later, was
associated with a 0.87 bpm lower resting heart rate and a 1.5 ms higher
HRV in females, and with a 1.2 bpm and 3.7 ms difference in 20 to 29
year olds. That lever cannot be offered from this feed.

Consequence for the data model: `alcohol_last_sample_time` records the
latest sample timestamp within the night, which under the present feed
is an export time and not a drink time. It must not be presented to the
reader as when the drinking stopped, and the noon-to-noon night boundary
must not be assumed to sort drinks correctly until per-drink timestamps
are confirmed to exist.

### Data availability

At the time of writing only 2026-09-05 has been exported, because the
export window was set to "today". Roughly two weeks sit in Health and
need a backfill from the phone before any of the aggregate surfaces
produce meaningful output.

## Decisions

### 1. Report counts in two units and energy in one

Report the drink count both in the app's unit and in Swedish
standardglas, and report exactly one energy figure: ethanol energy.

The primary source for that figure is DrinkControl's own
`dietary_energy`, filtered to the DrinkControl source and converted from
kJ. Rationale: it is the app's own arithmetic on the app's own unit
definition, so it cannot drift out of step with the count the way a
constant maintained on our side would the moment a setting changes.

Fallback, used only when the energy record is missing for a night:
`count × 10 g × 7 kcal/g`, that is 70 kcal per drink. Output must mark
this as calculated rather than recorded. The 7 kcal/g factor is from
Annex XIV of Regulation (EU) No 1169/2011.

### 2. Estimated total beverage energy is dropped

The original sketch had a second energy level: an estimate of the whole
drink's energy including residual carbohydrate in beer, sugar in wine
and cider, and mixers in cocktails, derived from templates per drink
type.

This is dropped because the inputs do not exist. Type, volume and
strength are not exported by any source available to us, so a template
estimate would have to assume the drink category, and the assumption
would be the entire content of the answer. Systembolaget's published
per-10-cl figures, set against the ethanol energy computed from the EU
factor, put the spread at roughly 1.0× for spirits and dry wine, where
essentially all the energy is ethanol, to about 1.5× for strong beer,
where residual carbohydrate adds about half again. Cider and sweet wine
are higher still, though by how much is [unverified] because no
per-item value was extracted for them. Even the verified part of that
range is wider than the precision such a number would be printed with.
Presenting a point estimate would be an assumption wearing the clothes
of a measurement, which is what this feature is explicitly meant to
avoid.

If the figure is ever wanted, the only honest form is a range rather
than a point. Even then it changes no decision, and it dilutes the one
energy figure that is solid.

### 3. Alcohol does not become a readiness component

`compute_readiness()` keeps its five components. Alcohol is attached to
the verdict as context, never scored into it.

Two reasons. First, it would double-count: the other components are
measurements of the body, and alcohol's entire physiological effect
already arrives through heart rate variability, resting heart rate,
sleep and wrist temperature. If a drink suppressed HRV, the HRV
component has already caught it.

Second, it would make the score unfalsifiable. A readiness score that
drops because a drink was logged is no longer reporting on the body's
state. On a night with two glasses followed by an HRV z-score of +0.8,
the model would still mark the day down, and it would be wrong. The
score would become partly a reprimand, and a reprimand is a strong
incentive to stop logging, which destroys the data the feature runs on.

### 4. Derive at import, not at query

Everything that needs information the daily cache has thrown away is
computed once at import. See "Data model" for what and why.

### 5. The notification is gated on the signal, not on the drinking

The energy line appears after any evening with logged alcohol. The
recovery comparison is appended **only** when at least one recovery
metric has moved beyond threshold against the alcohol-free baseline.
Otherwise the honest null is stated once. Silence at zero drinks. No
imperatives anywhere.

### 6. Grams of ethanol is the internal quantity

DrinkControl's unit cannot be set to 12 g. Sweden is not among the
jurisdictions the app offers, and the setting stays at the WHO 10 g.

So the internal quantity is **grams of ethanol**, derived from the
energy rather than from the count: `grams = kcal / 7`, with
`count × 10 g` as the fallback when the energy record is missing.
Standardglas is a display form only, `grams / 12`.

The reason for deriving from energy rather than multiplying the count by
a constant is that the count is denominated in a setting inside a
third-party app. The energy route is exact whatever that setting is, and
the ratio `grams / count` recovers the setting itself, which turns a
silent change into a detectable one. Two conditions bound it: it holds
only while DrinkControl is the sole writer of `dietary_energy`, and only
while per-drink-type calorie values are unedited. When either fails, use
the count fallback and mark the figure calculated.

### 7. Public-health limits never appear in Vayu

No risk thresholds, no weekly guideline, no drinking-limit comparison,
no goal count, no streak. The Swedish figures exist and are documented
in the research knowledge base, and they stay there.

The reference frame is the reader's own nights against the reader's own
other nights, and nothing else. This follows established practice in the
two products with published data on the question. Oura's November 2025
analysis of more than 600,000 members reports what alcohol-tagged nights
did against surrounding untagged nights and stops there. WHOOP's journal
works the same way, comparing a member to their own baseline. Neither
scores the behaviour, sets a target or grades the reader against a
population.

A training app that starts reporting a runner against public-health
drinking limits has changed genre, and it invites the reader to stop
logging. This decision is a constraint on every surface in the feature,
not a default that individual templates may override.

## Data model

### Why import-time derivation is required

Two properties of the existing pipeline force this, both of which would
silently corrupt a query-time implementation.

**Timestamps are truncated to a date.** `.parse_metric()` in
`R/health_export.R` takes `substr(s$date, 1, 10)`. The clock time
survives only in the canonical JSON on disk. A drink logged at 01:00
therefore carries the new calendar date and, at query time, is
indistinguishable from an evening drink on that new day. Only
import-time code sees enough to attribute it to the right night.

**Per-sample source survives only in canonical files.** For summed
metrics, `read_canonical_file()` returns the precomputed `daily_total`
and keeps only the first sample's source string. The daily value in the
cache is thus a sum over every source, tagged with one arbitrary source
name. Today that is harmless because DrinkControl is the only writer of
`dietary_energy`. The day a food-logging app is added, dietary energy
silently becomes food plus alcohol with no way to separate them in the
cache, and anything reading alcohol energy from it would be quietly
wrong with no error raised.

### Import-time derived values

| Value | Basis |
|---|---|
| `alcohol_units` | Daily total of `alcohol_consumption` |
| `alcohol_night_units` | Units attributed to the night, using a 12:00 to 12:00 boundary rather than midnight |
| `alcohol_standardglas` | `alcohol_night_units × 10 / 12` |
| `alcohol_kcal` | `dietary_energy` samples filtered to source DrinkControl, converted from kJ |
| `alcohol_kcal_is_calculated` | TRUE when the fallback constant was used |
| `alcohol_last_sample_time` | Latest sample timestamp within the night |
| `alcohol_logging_active` | Logical, see "Logging-active period" |

The **noon-to-noon night boundary** means a drink at 02:00 on Sunday
belongs to Saturday night and is compared against Sunday morning's
recovery, while a drink at 13:00 on Saturday also belongs to Saturday
night. Both are the intended attribution. Calendar-day grouping gets the
first case wrong, and it is not a rare case.

### Computed at query time

- The alcohol-free baselines. Window length and exclusion rules are
  analysis parameters that will be tuned, and tuning them must not
  require a full reimport.
- The energy share, since the denominator depends on a window choice.
- Everything in "Future: dose-response".

The dividing line: anything requiring information the cache has
discarded goes at import, anything that is a parameter choice goes at
query.

### Import wiring

Four changes are required, and omitting any of them fails silently
rather than loudly.

1. `inst/metric_taxonomy.json` — add `alcohol_consumption` to
   `sum_metrics`. A count must be summed across a day, not averaged.
   This file is the shared source for both the R and the Python side.
2. `.import_metrics` in `R/health_export.R` — add
   `alcohol_consumption`. Canonical files are always written to disk
   regardless, but without this entry the metric never reaches
   `health_daily.RData` and therefore reaches nothing downstream.
3. `.tier3_metrics` in `R/health_export.R` — add
   `alcohol_consumption` explicitly. An unclassified metric defaults to
   tier 1, which reports any change at all, so every single logged drink
   would fire its own push notification. The alcohol line in the daily
   notification is produced by this feature's own code, not by the
   generic delta machinery.
4. `.import_metrics` — add `basal_energy_burned`, needed only for the
   energy-share denominator. It is already in `.tier3_metrics`, so it
   introduces no notification noise.

The hardcoded `sum_metrics` expectation lists in the R and Python test
suites must be updated in the same change, or those tests fail
immediately.

## Energy accounting

Per night with logged alcohol:

```
units        = alcohol_night_units                  (DrinkControl, 10 g)
standardglas = units × 10 / 12
kcal         = dietary_energy(DrinkControl) / 4.184
kcal         = units × 10 × 7                       (fallback, marked)
grams        = kcal / 7                             (internal quantity)
```

The 7 kcal/g factor is from Annex XIV of Regulation (EU) No 1169/2011.

If the DrinkControl setting is ever found to differ from 10 g, the
grams-per-unit figure becomes a configured constant rather than a
literal, and historical output changes. That is a migration, not a
runtime branch.

Honesty constraint: if the unit definition is ever in doubt, report the
count and the app's kcal and say nothing about grams of ethanol. A gram
figure whose unit definition is unknown is false precision.

## Energy share

### Denominator

`active_energy + basal_energy_burned`, both from the Apple Watch.

`basal_energy_burned` is modelled by Apple from age, sex, height and
weight rather than measured. User-facing text must not describe the
denominator as a measurement.

### Window

Two different windows, for two different sentences.

- The **daily** line uses the 28-day mean of total expenditure, not that
  day's figure. A single day's expenditure is dominated by whether a long
  run happened, so a share against today's total would swing widely for a
  constant number of drinks, and the swing would be about the running.
- The **weekly** line uses that week's actual summed expenditure. A week
  averages out session lumpiness, and the reader is asking about that
  specific week.

Coverage floors: at least 20 of 28 days present for the monthly mean, at
least 5 of 7 for the week. Below the floor, omit the share rather than
computing it from a thin denominator.

### Pitfalls

**Garmin contamination.** `active_energy` comes from the Apple Watch. On
a day when a run is recorded by Garmin and the watch is not worn for it,
active energy undercounts, the denominator shrinks, and the share is
inflated on exactly the day the reader is most likely to look. Flag days
where a Garmin session exists but active energy sits at rest-day level,
and suppress the share on those days rather than printing an inflated
figure.

**Missing days.** No wear means no active and no basal figure. Do not
impute, do not substitute a placeholder. Omit the share.

## Alcohol-free baseline

The reference for the next-morning comparison, computed per metric over
HRV, resting heart rate and total sleep.

| Parameter | Value | Reason |
|---|---|---|
| Central measure | Median | One bad night must not move the reference |
| Window | Rolling 42 days | Compromise between stability and fitness drift |
| Minimum nights | 14 qualifying | Below this the comparison is not printed at all |
| Exclusions | Nights with `alcohol_night_units > 0`; illness-flagged days | |

Illness exclusion uses the existing readiness flags for elevated wrist
temperature and elevated respiratory rate.

This baseline is **separate from, and does not modify, the readiness
baselines**. The readiness windows, 7 days for HRV, 30 days for resting
heart rate, 14 days for wrist temperature, are unconditional
descriptions of recent state, and that is correct for their purpose. If
four nights running involved alcohol, the readiness baseline should
reflect that the athlete is in fact in a degraded state. Filtering
alcohol nights out of it would hide the very thing readiness exists to
report.

The alcohol-free baseline carries no causal claim. It supports the
descriptive sentence "this morning against a typical recent morning",
nothing more. Anything that generalises must use the matched design
below.

## Notification text

### Presentation of change

Percentages for the energy share. **Absolute units** for the recovery
deltas, with a z-score used only as a hidden gate.

The percentage form is deliberately not used for HRV. The convention in
this literature is to analyse RMSSD on the natural-log scale rather than
the raw scale: Buchheit (2014) and Stanley et al. (2013) both report Ln
rMSSD throughout, and Stanley et al. state that where multiple indices
were available they chose Ln rMSSD "because it is more reliable than
spectral indices". The stronger distributional claim, that raw RMSSD is
close to log-normal, is [unverified] here; no source in the project's
knowledge base states it, and it should not be asserted until one does.

What does not depend on that claim is the practical point: because the
working scale is logarithmic, a percentage on the raw scale is
asymmetric, and a fall of 20 % and a rise of 20 % are not events of
equal magnitude. A percentage also answers how
far down without answering whether that is unusual for this person,
which is the question actually being asked. The z-score answers both but
does not read as prose, so it decides whether the sentence appears while
the sentence itself states milliseconds, beats and minutes.

### Templates

The templates below are the strings the code emits, verified against
`.insight_alcohol_line()` and `.alcohol_weekly_line()` in `R/alcohol.R`.

Daily, alcohol plus a recovery signal that clears the gate. Deviations
are named in the order resting heart rate, HRV, sleep, which is
descending standardized effect size (Grosicki et al. 2026):

```
I går: 4 glas (3,3 standardglas), 282 kcal från alkoholen. Det motsvarar
12 procent av din genomsnittliga dygnsförbrukning. I dag: vilopuls 4
slag högre, HRV 38 ms mot 52 på alkoholfria nätter, sömn 42 minuter
kortare.
```

Daily, alcohol logged and nothing moved — the honest null:

```
I går: 3 glas (2,5 standardglas), 212 kcal från alkoholen. Det motsvarar
9 procent av din genomsnittliga dygnsförbrukning. I dag: vilopuls och
HRV ligger på dina normala nivåer.
```

The share clause is dropped when the denominator is thin or
untrustworthy, and the recovery clause when the baseline is. Either can
be absent; the drinks-and-energy clause always leads.

Where the app wrote no energy for the night, the kcal figure is computed
from the fallback constant and says so:

```
I går: 6 glas (5 standardglas), 420 kcal från alkoholen (beräknat).
```

Weekly, on Monday, covering the week that just ended:

```
Förra veckan: alkohol stod för 1 240 kcal, fördelat på 3 kvällar. Det
motsvarar 6 procent av veckans energiförbrukning. 4 alkoholfria dagar.
```

### Silence rules

In priority order.

1. **Zero drinks: silent.** No note that the day was alcohol-free. Praise
   for abstinence is moralising through the back door, it turns the
   feature into a daily verdict on the reader's drinking, and it would
   put an alcohol line in the notification every day of the year, which
   guarantees it stops being read.
2. **Outside a logging-active period: silent.** Absence of data is not
   zero.
3. **Baseline below 14 qualifying nights, or the day is illness-flagged:
   omit the recovery comparison**, keep the energy line.
4. **Never print a partial comparison.** If sleep is missing but HRV and
   resting heart rate are present, name the two that exist and omit the
   third entirely. No placeholder, no question mark, no "saknas".
5. **The recovery sentence is gated on the signal.** Mention HRV, resting
   heart rate or sleep only when at least one has moved beyond threshold.
   Otherwise use the honest-null template above. Without this gate the
   sentence reads as an accusation looking for evidence.
6. **No imperatives.** No "bör", no training prescription, no
   compensation framing. Exercise is not penance. The way to honour that
   is to remove the verb: the text reports, and stops.

## Surfaces

**R API.** Everything lives in `R/alcohol.R`, not in
`R/advanced_metrics.R` as an earlier draft of this document proposed:
the module owns an import path, a cache and a prose surface, which is
more than the compute/render pattern there covers.

```r
build_alcohol_nights(samples, energy = NULL, active_window_days = 10)
import_alcohol(save = TRUE, cache_path = NULL, canonical_dir = NULL,
               verbose = TRUE)
load_alcohol_data(cache_path = NULL)
save_alcohol_data(alcohol_nights, cache_path = NULL)

compute_alcohol_energy(alcohol, health_daily = NULL, summaries = NULL,
                       window_days = 28, min_days = 20)
compute_alcohol_week(alcohol, health_daily = NULL, summaries = NULL,
                     min_days_in_week = 5)
compute_alcohol_baseline(health_daily, alcohol, on_date = NULL,
                         window_days = 42, min_nights = 14)
compute_alcohol_deviation(health_daily, alcohol, on_date = NULL,
                          baseline = NULL, z_threshold = 1, ...)

report_alcohol(data, after = NULL, before = NULL, alcohol = NULL)
report_alcohol_weekly(data, after = NULL, before = NULL, alcohol = NULL)
```

**Notification.** The alcohol lines are composed by this feature and
attached to the daily push alongside the readiness verdict. They are not
routed through the generic tier-based delta machinery, which is why the
metric sits in tier 3.

They are **additive**, not candidates in the single-slot context chain
(`.insight_context_line()`, which emits at most one of comeback / ACWR /
HRV-downtrend). The product decision is an energy line after every
logged evening; as a candidate the line would fall silent whenever a
training-state line had something to say, which is most days. Both
alcohol lines are silent on a dry night and outside a logging-active
stretch, so being additive cannot turn them into a daily fixture.

**MCP:** `python/traning_cli/mcp/tools.py`, built on the report
functions above. Add metadata and Swedish and English aliases so
natural-language metric resolution finds it.

**Shiny:** deferred. The daily notification is the surface that matters
for this feature, and a panel can follow once there is more than a few
weeks of history.

## Future: dose-response

Specified here, not built. No code in this phase.

The goal statement is of the form "for you, evenings with 0 to 2 drinks
usually show little or no measurable effect, while 3 or more coincide
with lower HRV and higher resting heart rate the next morning". That
sentence generalises, so it needs a design that the descriptive daily
comparison does not.

### Why the naive design fails

Plotting drinks against next-morning readiness and fitting a line
produces a number, and the number measures the wrong thing.

Drinking nights are not randomly assigned. They cluster on Friday and
Saturday, and so does everything else that moves the outcome: a late
bedtime, a large late meal, a long run earlier that day or a rest day, a
lie-in the next morning. A weekend-versus-weekday contrast dressed as an
alcohol-versus-abstinence contrast absorbs all of it. The sign can even
invert, because two extra hours in bed raise the sleep component on
exactly the mornings alcohol should have hurt it.

Covariate adjustment does not rescue this at the sample sizes available.
With a few hundred nights and a weekday variable nearly collinear with
the exposure, the adjusted coefficient is unstable and its interval is
not honest.

The alcohol-free baseline specified above does not solve it either. It
removes alcohol nights from the reference but leaves the weekday
confound intact, since the alcohol-free nights are disproportionately
Monday to Thursday.

### Weekday-matched design

For each night with `alcohol_night_units > 0`, build a control set of
nights that are:

- the same weekday,
- within ±6 weeks,
- not illness-flagged,
- inside a logging-active period,
- themselves alcohol-free.

Compare the exposed night's outcome to the mean of its control set. The
estimand is the mean within-set difference, with an interval from the
distribution of set-level differences. The weekday confound is removed
by construction rather than by assumption, and the ±6 week window
removes most seasonal and fitness drift.

Report per dose band, not pooled.

A secondary ordinary-least-squares model, regressing each outcome on
dose band plus weekday, sleep onset clock time, previous-day TRIMP, CTL
and month, serves as a cross-check only. Sleep onset time must be in it,
or the model cannot distinguish alcohol from a late bedtime, and those
are different findings with different remedies. If the two designs
disagree materially, trust the matched design and say so in the output
rather than quietly reporting the friendlier number.

### Outcomes

Model the readiness components separately, never the composite. The
composite includes a training-load term that alcohol cannot plausibly
move, and it redistributes weights across whichever components are
present on a given day, so it means something slightly different each
day. Regressing on it dilutes any real effect and yields a coefficient
that is not a physiological quantity.

| Rank | Outcome | Expectation |
|---|---|---|
| 1 | Resting heart rate deviation from baseline | Largest standardized effect in the literature, and low day-to-day noise (Grosicki et al. 2026) |
| 2 | HRV, as z-score of ln RMSSD | Consistent and dose-dependent, but a smaller standardized effect than resting heart rate (Grosicki et al. 2026; Pietilä et al. 2018) |
| 3 | Total sleep duration | Expect a clear, dose-dependent shortening (Grosicki et al. 2026) |
| 4 | Deep plus REM as a fraction of total sleep | Mechanism is REM suppression and second-half fragmentation [unverified]; industry aggregate data is consistent with it (Oura 2025) |
| 5 | Respiratory rate deviation | Sensitive, currently underused, no alcohol-specific source located |

**Two changes from the earlier draft, both because the sources say
otherwise.**

First, resting heart rate and HRV are swapped. Grosicki et al. (2026)
report standardized effects of 0.61 in females and 0.52 in males for
resting heart rate against 0.30 and 0.26 for HRV, per one drink above
personal average. Resting heart rate is the larger and better-resolved
signal, not HRV. Both remain dose-dependent and both are worth modelling.

Second, the earlier draft expected little effect on total sleep duration
and used that as a check on the design. That expectation is contradicted.
Grosicki et al. (2026) state that sleep duration declined progressively
with increasing alcohol intake across both sexes and all age groups, and
Oura's aggregate data over more than 600,000 members reports 35 minutes
less total sleep on alcohol-tagged nights. A design check resting on
duration not moving would therefore fail on correct data.

Strüven et al. (2025) offer a partial counterpoint from a small
controlled study, n = 40 on a smartwatch: objective sleep architecture
was unchanged while subjective sleep quality fell. That was read at
abstract level only, and it does not outweigh two large cohorts.

A replacement design check is needed. The honest one is sleep onset
clock time, which must be in the cross-check model in any case: if the
alcohol effect disappears once onset time is included, the analysis was
measuring bedtime. Duration cannot serve the purpose because alcohol
genuinely moves it.

### Dose bands

0, 1 to 2, 3 to 4, 5 or more, in DrinkControl units.

Bands rather than a continuous dose because self-reported counts have
poor precision, and the precision degrades as the count rises. A
continuous slope claims a resolution the input does not have. Bands are
also what the runner can act on.

The dose-response relationship over this range is monotonic in both
large cohorts. Pietilä et al. (2018) report increases in heart rate of
1.4, 4.0 and 8.7 bpm and reductions in RMSSD of 2.0, 5.7 and 12.9 ms
across low, moderate and high dose groups averaging 1.1, 2.9 and 7.0
portions. Grosicki et al. (2026) fit smooth curves that rise and fall
monotonically over the observed range and show the step from three to
five drinks costing a further 5.6 ms of HRV in females and 5.1 ms in
males.

One caution on the band boundaries. Both sets of figures are in units of
roughly 12 g of ethanol in Pietilä, who defines a portion as 12 g, and
of an undefined self-reported drink in Grosicki, whose user base is
mostly American. The bands here are in DrinkControl's 10 g units, so
they are not directly comparable to either. Convert to grams before
setting a boundary against a published figure.

### Logging-active period

A night with no alcohol record is ambiguous: either no drinks, or a
forgotten log. Treating absence as zero biases the zero band toward
containing exactly the nights most likely to have been forgotten, which
inflates the apparent effect.

Rule: a logging-active period is any stretch where at least one alcohol
record exists within ±10 days. Inside it, absence means zero. Outside
it, the night's exposure is `NA` and the night is excluded from every
analysis, including as a control. The output states how many nights were
excluded on these grounds.

### Stop rule

Count qualifying nights before fitting anything. A qualifying night has
a non-`NA` exposure and complete next-morning HRV, resting heart rate
and sleep.

| Qualifying nights | What may be published |
|---|---|
| Under 30 | Descriptive figures only. No model, no estimate, no dose-response sentence |
| 30 to 60 | Matched estimate with its interval, explicitly labelled provisional |
| Over 60 | Full band-wise design |

The threshold reflects the within-person day-to-day variability of Ln
rMSSD, which is large relative to plausible effects at low doses.
Buchheit (2014) puts it at a coefficient of variation of 10 to 20 %:
"The day-to-day variations in training load entail large daily
variations in cardiac ANS activity (i.e., CV = 10-20 % for Ln rMSSD)".
Set against that, the effect at one drink above personal average is a
standardized 0.30 in females and 0.26 in males (Grosicki et al. 2026),
and 2.0 ms of RMSSD in the lowest dose band (Pietilä et al. 2018). The
signal at low doses is real but small relative to the noise, which is
what a night count has to overcome. The specific 30 and 60 night
thresholds are a judgement rather than a powered calculation
[unverified]. This rule is written down now, before the counts are known,
because deciding it after seeing the data is how a null result turns
into a published slope.

## Out of scope

- Estimated total beverage energy, per decision 2.
- Per-occasion drink type, volume and strength. The columns would be
  permanently empty, and an empty column invites a guess that becomes
  indistinguishable from a record once it is in the table.
- Writing anything back to Health. This feature reads only.
- Any alcohol term inside `compute_readiness()`, per decision 3.
- A Shiny panel, deferred until there is more history.

## Literature

Every source below was read before being cited. Text extracts are in
`research/_txt/` and the analysis primers in `research/_analys/`, in the
project knowledge base at `/Users/krisniem/dev/traning/research/`.

### Peer-reviewed

- Pietilä, J., Helander, E., Korhonen, I., Myllymäki, T., Kujala, U.M.,
  & Lindholm, H. (2018). Acute effect of alcohol intake on
  cardiovascular autonomic regulation during the first hours of sleep in
  a large real-world sample of Finnish employees: observational study.
  *JMIR Mental Health*, 5(1), e23. DOI: 10.2196/mental.9519. PMC5878366.
  Read in full. 12,411 nights from 4,098 participants, chest-worn
  beat-to-beat R-R, within-subject. Defines a portion as 12 g of ethanol.
- Grosicki, G.J., Robinson, A.T., Joyner, M.J., Carter, J.R., von
  Hippel, W., Presby, D.M., Fielding, F., Bigalke, J.A., Kim, J.,
  Chapman, C., & Holmes, K.E. (2026). Real-world effects of alcohol on
  heart rate, sleep, and physical activity by age and sex. *PLOS Digital
  Health*, 5(3), e0001284. DOI: 10.1371/journal.pdig.0001284. Read in
  full. 5,109,185 person-days from 20,968 WHOOP users. **Funded by
  WHOOP, and several authors are WHOOP employees holding stock options.**
  The paper discloses this and points to a preregistered analysis plan.
  Its findings agree with the independent Finnish cohort on direction and
  magnitude, which is why they are relied on here.
- Buchheit, M. (2014). Monitoring training status with HR measures: do
  all roads lead to Rome? *Frontiers in Physiology*, 5, 73. DOI:
  10.3389/fphys.2014.00073. Source for the 10 to 20 % day-to-day
  coefficient of variation in Ln rMSSD.
- Stanley, J., Peake, J.M., & Buchheit, M. (2013). Cardiac
  parasympathetic reactivation following exercise: implications for
  training prescription. *Sports Medicine*, 43(12), 1259-1277. DOI:
  10.1007/s40279-013-0083-4. Source for the field's use of Ln rMSSD and
  its reliability rationale.
- Strüven, A., Schlichtiger, J., Hoppe, J.M., Thiessen, I., Brunner, S.,
  & Stremmel, C. (2025). The impact of alcohol on sleep physiology.
  *Nutrients*, 17, 1470. DOI: 10.3390/nu17091470. **Abstract only.**
  Cited only as a partial counterpoint on sleep architecture.

### Not read, and therefore not cited for any figure

- Ebrahim, I.O., Shapiro, C.M., Williams, A.J., & Fenwick, P.B. (2013).
  Alcohol and sleep I: effects on normal sleep. *Alcoholism: Clinical
  and Experimental Research*, 37(4), 539-549. DOI: 10.1111/acer.12006.
  Paywalled. This is the standard reference for the REM-suppression and
  second-half-fragmentation mechanism, which is why that claim is marked
  [unverified] above. Listed in `research/to_fetch.md`.

### Official and regulatory

- Regulation (EU) No 1169/2011 on the provision of food information to
  consumers, Annex XIV, conversion factors. Alcohol (ethanol) 29 kJ/g,
  7 kcal/g. Binding for nutrition labelling in Sweden.
- Centralförbundet för alkohol- och narkotikaupplysning (CAN). *Hur
  många dricker riskabelt?* Retrieved 2026-09-05. Swedish standardglas
  is 12 g of alcohol, corresponding to about 33 cl strong beer, 12 cl
  wine or 4 cl spirits. Cited for the unit definition only, never for
  its risk thresholds, per decision 7.
- Systembolaget. *Hur många kalorier finns det i starköl, sprit och
  vin?* Retrieved 2026-09-05. Per 10 cl: strong beer 5.6 % 47 kcal, dry
  white wine 12 % 67 kcal, red wine 12 % 72 kcal, whisky 40 % 222 kcal.
- Livsmedelsverket. *Livsmedelsdatabasen*, version 2026-07-01. Named as
  the authoritative Swedish per-100-g source. Per-item values have not
  been extracted; the search interface needs the full Excel export.

### Platform and product documentation

- Apple Developer Documentation. *HKQuantityTypeIdentifier
  .numberOfAlcoholicBeverages* and *.bloodAlcoholContent*. Retrieved
  2026-09-05. Count unit, cumulative aggregation, qualitative definition
  of a standard drink, no beverage type or volume in the type.
- HealthyApps. *Health Auto Export: Supported Data and Metrics* and
  *JSON Export Format*. Retrieved 2026-09-05.
- DrinkControl. *Help & Support*, App Store description and press kit.
  Retrieved 2026-09-05. Per-jurisdiction standard-drink definitions,
  the 7 kcal/g figure, the ethanol-only calorie scope, and the fact that
  per-drink-type calorie values are user-editable.
- Oura. *Oura data reveals the true impact of alcohol on sleep.*
  Published 2025-11-04. Aggregate data from more than 600,000 members,
  January to October 2025: average heart rate up 9.6 %, lowest resting
  heart rate up 8.2 %, HRV down 10.8 ms or 15.6 %, total sleep 35
  minutes shorter, deep sleep down about 5 minutes and REM down about 15
  minutes. Industry analysis, not peer-reviewed. Cited for the sleep
  mechanism as supporting evidence only, and for the framing convention
  in decision 7.

### Claims still marked [unverified]

Three, all reformulated above rather than removed:

1. That raw RMSSD is close to log-normal. The log-scale convention is
   sourced; the distributional claim is not.
2. REM suppression and second-half fragmentation as the mechanism for
   the sleep-quality outcome. Awaits Ebrahim et al. (2013).
3. The specific 30 and 60 qualifying-night thresholds in the stop rule,
   which are a judgement rather than a powered calculation.

Cider and sweet wine sit outside the verified part of the beverage
energy range, and that is noted at the point of use.
