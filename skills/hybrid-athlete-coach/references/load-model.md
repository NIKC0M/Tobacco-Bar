# Load model

Everything here exists to make one sentence true: **60 minutes at lactate
threshold heart rate scores 100, whatever the athlete was doing.** Without a
shared anchor, a hybrid athlete's week is two incomparable piles of numbers.

## Endurance sessions — Banister TRIMP

Given average heart rate for the session:

```
HRr   = (avgHR - restingHR) / (maxHR - restingHR)        clamp to 0…1.2
rawTRIMP = minutes × HRr × 0.64 × e^(b × HRr)
```

`b` is 1.92 for men, 1.67 for women. The exponential is the point: it makes an
hour at threshold worth far more than two hours of easy jogging, which matches
how recovery actually behaves.

Rescale to the shared anchor:

```
load = rawTRIMP / rawTRIMP(avgHR = thresholdHR, minutes = 60) × 100
```

Worked example — threshold 170, resting 50, max 190:

| Session | avg HR | Minutes | Load |
| --- | --- | --- | --- |
| Easy run | 130 | 60 | ~39 |
| Threshold run | 170 | 60 | 100 |
| Long easy run | 130 | 180 | ~116 |

Three easy hours outweighing one threshold hour is correct, and is the sort of
thing athletes routinely get wrong by feel.

## Strength sessions — session RPE

Heart rate is the wrong instrument for lifting. An hour of heavy triples might
average 105 bpm and leave someone wrecked for two days. Use perceived effort:

```
load = minutes × RPE × (100 / 420)
```

RPE is 1–10, rated about 30 minutes after finishing rather than mid-session.
The `100/420` factor anchors it to the same scale: an hour at RPE 7 ≈ 100.

If RPE wasn't recorded, ask for it — it's one number and it's the difference
between the model seeing their lifting or not. Failing that, estimate (heavy
strength ≈ 8, hypertrophy ≈ 7.5, power ≈ 7, hard conditioning ≈ 8.5) and say
you estimated.

## Nothing recorded

Fall back to a flat hourly rate: run/row 70, swim 60, bike/ruck 55, strength 50,
hard conditioning 80, mobility 15. Deliberately conservative — a load number
that's too low produces cautious advice, one that's too high produces advice to
rest when they didn't need to.

## Fitness, fatigue, form

Daily loads (sum of that day's sessions, zero on rest days) feed two
exponentially weighted averages:

```
alpha = 1 - e^(-1/τ)
value = value + alpha × (todayLoad - value)
```

- **Fitness (CTL)** — τ = 42 days. Slow, represents accumulated capacity.
- **Fatigue (ATL)** — τ = 7 days. Fast, represents current tiredness.
- **Form (TSB)** — yesterday's CTL minus yesterday's ATL. Read off *yesterday*
  so today's session doesn't make them look tired before they've done it.

Interpreting form: below -25 is deep fatigue, -10 to -25 is productive training,
-10 to +5 is neutral, above +10 is fresh or tapered.

**Acute:chronic ratio** = ATL / CTL.

| Ratio | Meaning |
| --- | --- |
| Below 0.8 | Under-loaded — detraining if sustained |
| 0.8 – 1.3 | The productive range |
| 1.3 – 1.5 | Ramping fast, watch it |
| Above 1.5 | Spike — injury risk climbs sharply |

**Monotony** = mean daily load ÷ standard deviation of daily load over 7 days.
Above 2.0 means every day looks the same, which is its own risk factor even at
moderate volume. **Strain** = weekly load × monotony.

## A note on short windows

These are impulse-response curves; they need history to mean anything. With
fewer than ~28 days, CTL is still climbing from zero and the acute:chronic ratio
will read artificially high — it is comparing a real week against a chronic
average that hasn't had time to build.

With a short window, report weekly totals and day-to-day distribution instead,
and say that fitness and form need more history before they're meaningful.
Presenting a ratio of 3.9 from ten days of data as a load spike is simply wrong,
and the athlete will feel that it's wrong.
