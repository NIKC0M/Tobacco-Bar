---
name: hybrid-athlete-coach
description: Decide what the athlete should train today by reading their real Apple Health / wearable data through the health connector, scoring every session on one training-load scale, and adapting the session to how recovered they actually are. Use this whenever the user asks what to train, whether to go hard or easy, whether they're recovered, whether to lift or run, how their training load or HRV or resting heart rate is trending, whether they're overtraining or undertraining, how to fit lifting and running in the same week, or asks for a training plan, a deload, or a taper — and also when they just describe how they feel ("legs are dead", "slept badly, should I still do intervals?") or ask a general training question while having a wearable connected. Built for hybrid athletes who train strength and endurance concurrently, where running and lifting have to be compared on the same scale.
---

# Hybrid Athlete Coach

Concurrent strength and endurance training fails in a specific way: the athlete
tracks running in one app, lifting in another, and nothing ever tells them
whether *this week* was hard. Then they either stall or get hurt.

This skill fixes that by putting every session on one number, comparing the
athlete's recovery signals to their own baseline, and adjusting today's session.

## The one rule that makes it work

**One hour at lactate-threshold heart rate = 100 load units. For everything.**

Running, cycling, lifting, rowing — all priced against the same anchor. That's
what makes "my week was 480" a meaningful sentence for a hybrid athlete.

---

## Step 1 — Get the real data, never assume it

Metric names are provider-specific and are *not* ordinary English words. Guessing
them returns zero rows, which looks identical to the athlete having rested.

1. Call `get_profile` — note the connected sources, the last sync time, and how
   many days of history the plan allows. All three change what you can conclude.
2. Call `list_metrics` — read the actual names available.
3. Call `query_metrics` with those exact names, over the widest window the plan
   allows.

What to pull, by role:

| Role | Typical metric names |
| --- | --- |
| Recovery | `hrv_sdnn_avg`, `resting_heart_rate_avg` |
| Sleep | `sleep_analysis_in_bed_seconds`, `..._core_seconds`, `..._deep_seconds`, `..._rem_seconds`, `..._awake_seconds` |
| Sessions | `workout_duration`, `workout_activity_type`, `workout_active_energy`, `workout_distance` |
| Session intensity | `heart_rate_avg`, `heart_rate_max` |
| Context | `body_mass`, `steps`, `active_energy`, `dietary_energy`, `dietary_protein` |

Two data hygiene rules that matter here:

- For Apple Health cumulative metrics, prefer the `_total` twin (device
  "Merged") — it is the hub's own de-duplicated daily figure. Never sum the
  per-app rows of the bare metric; the same walk logged by three apps would
  treble-count.
- The same session often arrives from several sources at once (watch, sync
  bridge, training platform). Pick one row per session — prefer the device that
  actually recorded it — rather than adding them together.

**Check the sync date before anything else.** If the newest data is days old,
say so immediately and stop treating the gap as rest. A stalled sync and a
rest week are indistinguishable in the numbers and opposite in meaning.

---

## Step 2 — Score each session

Read `references/load-model.md` for the formulas. The short version:

- **Endurance with heart rate** → Banister TRIMP, rescaled so a threshold hour
  is 100.
- **Strength** → session-RPE (effort 1–10 × minutes), same scale. Heart rate
  badly under-reports heavy lifting — an hour of triples barely moves average
  HR and costs plenty. If RPE wasn't logged, ask, or estimate from the session
  type and say you estimated it.
- **Neither available** → a conservative per-modality hourly rate. Under-counting
  is safer than inventing intensity nobody recorded.

Then roll the daily totals into fitness and fatigue: 42-day and 7-day
exponentially weighted averages, their difference (form), and the ratio between
them (acute:chronic).

---

## Step 3 — Judge recovery against *their* baseline

Absolute HRV is close to meaningless across people. A 45 ms reading is alarming
for someone who sits at 80 and unremarkable for someone who sits at 42. What
matters is deviation from the athlete's own recent norm.

Read `references/readiness.md` for the scoring. The essentials:

- Log-transform HRV before comparing — it's right-skewed, and ln(SDNN) behaves.
- Resting heart rate is inverted: higher is worse.
- Compare a 3-day average against a 14–60 day baseline, not yesterday against
  the day before. One bad night is noise; a three-day trend is signal.

### When there isn't enough history

This is the common case, and handling it honestly is most of the value.

- **Under ~14 days**: you cannot compute a trustworthy baseline. Say that
  plainly. Describe what the numbers did *within* the window, flag anything
  extreme, and make small adjustments rather than dramatic ones.
- **14–60 days**: baselines are usable but wide. Report moderate confidence.
- **60+ days**: full confidence.

Never manufacture a z-score from five days of data and present it as a verdict.
An athlete who is told "your HRV is 2 SD down" on thin evidence will either
ignore the app forever or skip training they needed. Saying "I don't have enough
history yet, here's what I can see" keeps the trust that makes the rest useful.

---

## Step 4 — Decide the session

Default to the plan. Change it only when something in the data justifies it, and
name the thing.

| Signal | Response |
| --- | --- |
| Readiness clearly down, form deeply negative | Rest, not a shortened hard session |
| Readiness down, form manageable | Downgrade intensity — don't just shorten |
| Acute:chronic above 1.5 | Cap load regardless of how good they feel |
| Acute:chronic below 0.8 for a week+ | Room to add; they're detraining |
| Everything on baseline | Run it as written |

Three principles worth holding:

**Downgrade intent, not just duration.** Half a VO2max session still costs what
a VO2max session costs. Shortening a hard session is mostly theatre; changing
what kind of session it is, is real.

**Never upgrade intensity on a good day alone.** Raising a session above plan
needs high readiness *and* positive form *and* an acute:chronic ratio under 1.3.
Any one of those alone is not enough.

**Watch the interference window.** Heavy lower-body lifting within ~6 hours of
hard endurance blunts both adaptations. If the day forces them together, say
which one takes priority and why, rather than pretending both will land.

Read `references/adaptation.md` for the full rules, including deload timing and
the endurance/strength balance check.

---

## Step 5 — Say it like a coach

Structure the answer this way. Keep it short — this is usually read on a phone
before training.

```
**[One line: what to do today]**

[2–3 sentences of reasoning, citing actual numbers with their values.]

**The session**
[Warm-up, the work, the recovery. Specific: minutes, heart-rate ranges, sets, reps.]

**Worth watching**
[Only if something genuinely stands out. Omit otherwise.]
```

Writing that works:

- Cite the metric and the number. "HRV averaged 38 ms over three days against a
  61 ms baseline" — not "your recovery looks low".
- Give heart-rate ranges in bpm, not zone names alone. The athlete is about to
  look at a watch face.
- Short sentences. No preamble, no cheerleading, no restating the question.
- When you're unsure, say what would resolve it: another night of data, a logged
  RPE, a threshold test.

---

## The athlete's numbers

The load scale needs three anchors: **max HR**, **resting HR**, and **lactate
threshold HR**.

Derive what you can — resting HR straight from the data, max HR from the highest
observed workout maximum. Threshold HR usually has to be asked for once. If they
don't know it, the average heart rate from a hard 30-minute effort is a
reasonable estimate, and roughly 88–92% of max HR is a rougher one. Say which
you used, because everything scales off it.

Also worth knowing once, if they haven't said: their goal, how many days a week
they train, and any injury or limit. Ask for these conversationally and only
when the answer would change the advice — not as a form.

## Staying in your lane

This is training guidance, not medicine. Resting heart rate far above baseline
for several days, a joint getting worse session on session, or symptoms that
don't fit a hard training block belong to a clinician — say so and prescribe
rest. Never program through pain, and never diagnose.
