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
unit. At an ethanol energy density of about 7.1 kcal/g [source pending],
10 g gives 71 kcal, which matches the observed 70.4 within rounding.

The energy DrinkControl writes is therefore **ethanol energy, not total
beverage energy**. A 50 cl beer at 5.2 % holds about 20.5 g of ethanol,
so 2.05 WHO units, and carries roughly 215 kcal in total, which is about
105 kcal per unit [source pending]. The observed 70.4 sits well below
that and matches ethanol alone.

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

HealthKit's alcohol record is a bare count. There is **no drink type, no
volume and no alcohol percentage**, and DrinkControl exports none of
them even though it holds them internally. This constrains the design
more than anything else and is the reason for decision 2.

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
`count × 10 g × 7.1 kcal/g`, that is 71 kcal per drink. Output must mark
this as calculated rather than recorded.

### 2. Estimated total beverage energy is dropped

The original sketch had a second energy level: an estimate of the whole
drink's energy including residual carbohydrate in beer, sugar in wine
and cider, and mixers in cocktails, derived from templates per drink
type.

This is dropped because the inputs do not exist. Type, volume and
strength are not exported by any source available to us, so a template
estimate would have to assume the drink category, and the assumption
would be the entire content of the answer. The spread from spirits taken
neat to cider is roughly 1× to 1.6× the ethanol energy [source pending],
which is wider than the precision such a number would be printed with.
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
kcal         = units × 10 × 7.1                     (fallback, marked)
```

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

The percentage form is deliberately not used for HRV. RMSSD is strongly
right-skewed and close to log-normal [source pending], so a percentage
on the raw scale is asymmetric and misleads: a fall of 20 % and a rise
of 20 % are not events of equal magnitude. A percentage also answers how
far down without answering whether that is unusual for this person,
which is the question actually being asked. The z-score answers both but
does not read as prose, so it decides whether the sentence appears while
the sentence itself states milliseconds, beats and minutes.

### Templates

Daily, alcohol logged, no recovery signal beyond threshold:

```
I går: 6 glas (5 svenska standardglas). Energi från alkoholen: 423 kcal.
Det motsvarar 14 procent av din genomsnittliga dygnsförbrukning.
```

Daily, alcohol plus a recovery signal that clears the gate:

```
I går: 4 glas, 282 kcal från alkoholen.
I dag: HRV 38 ms mot 52 i snitt på alkoholfria nätter, vilopuls 4 slag
högre, sömn 42 minuter kortare.
```

Daily, alcohol logged and nothing moved — the honest null:

```
I går: 3 glas, 212 kcal från alkoholen.
I dag: HRV och vilopuls ligger på dina normala nivåer.
```

Weekly:

```
Alkohol stod för 1 240 kcal den här veckan, fördelat på tre kvällar.
Det motsvarar 6 procent av veckans energiförbrukning. Fyra alkoholfria
dagar.
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

- **R API:** `compute_alcohol_summary()` and a sibling
  `render_alcohol_prose()` in `R/advanced_metrics.R`, following the
  pattern of the existing compute/render pairs.
- **Notification:** the alcohol line is composed by this feature and
  attached to the daily push alongside the readiness verdict. It is not
  routed through the generic tier-based delta machinery, which is why
  the metric sits in tier 3.
- **MCP:** `get_alcohol_summary(after, before)` in
  `python/traning_cli/mcp/tools.py`. Add metadata and Swedish and
  English aliases so natural-language metric resolution finds it.
- **Shiny:** deferred. The daily notification is the surface that
  matters for this feature, and a panel can follow once there is more
  than a few weeks of history.

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
| 1 | HRV, as z-score of ln RMSSD | Largest and most reliable effect [source pending] |
| 2 | Resting heart rate deviation from baseline | Robust, low day-to-day noise |
| 3 | Deep plus REM as a fraction of total sleep | Mechanism: REM suppression and second-half fragmentation [source pending] |
| 4 | Respiratory rate deviation | Sensitive, currently underused |
| 5 | Total sleep duration | Expect little effect [source pending] |

Outcome 5 acts as a check on the design. Alcohol shortens sleep latency
and degrades quality more than it shortens duration, so if total
duration moves as much as HRV does, the analysis is picking up bedtime
rather than alcohol and should be treated as failed.

### Dose bands

0, 1 to 2, 3 to 4, 5 or more, in DrinkControl units.

Bands rather than a continuous dose because self-reported counts have
poor precision, and the precision degrades as the count rises. A
continuous slope claims a resolution the input does not have. Bands are
also what the runner can act on. The dose-response relationship over
this range is reported as roughly monotonic [source pending].

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

The threshold reflects the within-person day-to-day variability of ln
RMSSD, which is large relative to plausible effects at low doses [source
pending]. This rule is written down now, before the counts are known,
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

Claims marked `[source pending]` above await verified references:

- Energy density of ethanol, and the WHO 10 g unit against the Swedish
  12 g standardglas.
- Total beverage energy per unit of ethanol by drink category,
  supporting the 1× to 1.6× range.
- Log-normality of RMSSD, and why a percentage change on the raw scale
  misleads.
- Alcohol's effect on next-morning HRV, and on resting heart rate in
  absolute beats per minute for calibrating the gate threshold.
- REM suppression and second-half sleep fragmentation as the mechanism.
- Limited effect on total sleep duration relative to sleep quality.
- Dose-response monotonicity over 1 to 5 or more units.
- Within-person day-to-day variability of ln RMSSD, for the stop rule.

No figure in this document is supported by a citation yet. None should
be published with a reference attached until one has been supplied and
verified.
