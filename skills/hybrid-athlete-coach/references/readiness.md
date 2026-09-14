# Readiness

A single 0–100 number for "how recovered is this athlete today", plus — just as
important — how much to trust it.

## Why z-scores against their own baseline

HRV varies several-fold between individuals. Population norms tell you almost
nothing about one person. What carries information is movement relative to that
person's own recent range.

```
z = (recent - baselineMean) / baselineSD
```

Where **recent** is a 3-day average (one night is noise) and **baseline** is the
trailing 14–60 days, excluding the recent window.

## The four inputs

**HRV (SDNN)** — weight 0.35. Log-transform before averaging: HRV is
right-skewed and ln(SDNN) is much closer to normal, which is what makes the SD
meaningful. Higher is better.

**Resting heart rate** — weight 0.20. No transform. Invert the sign: an elevated
resting HR is a negative signal. A rise of 5+ bpm above baseline sustained over
days is one of the more reliable early warnings of illness or accumulated
fatigue.

**Sleep** — weight 0.25. Last night against their stated need, blended 60/40
with the 7-day average so a single short night doesn't dominate but a run of
them does.

**Form (TSB)** — weight 0.20. Divide by 30 and clamp to ±1.

Renormalise the weights over whichever signals actually exist, so a missing HRV
feed degrades the score gracefully instead of silently dragging it to the middle.

```
blended = Σ(weight × clamp(component, -1, 1)) / Σ(weights present)
score   = 50 + blended × 45
```

| Score | Band | Default posture |
| --- | --- | --- |
| 75+ | Primed | Green light; small increase possible if form allows |
| 60–74 | Ready | Train as planned |
| 40–59 | Moderate | Scale to roughly 80% |
| Below 40 | Compromised | Half load or rest |

## Confidence — the part that earns trust

```
confidence = 0.65 × min(baselineDays / 60, 1) + 0.35 × (signalsPresent / 4)
```

Below 0.5, damp every adjustment toward neutral and say the baseline is still
building. The instinct to produce a confident number from thin data is exactly
the thing that makes training apps untrustworthy. An athlete told "I have nine
days of data — your HRV is at the low end of that short range, and I can't yet
tell you whether that's unusual for you" will keep using the tool. One told
"readiness 31, skip your session" on the same evidence will not.

## What to actually say

Name the drivers, with numbers:

- "HRV averaged 38 ms over three days against a 61 ms baseline — 1.9 SD down."
- "Resting HR up 6 bpm on baseline for a third day."
- "5.5 hours last night against an 8-hour need; 6.9 average across the week."
- "Form at -28 — you're carrying real fatigue from the last block."

And when signals disagree — HRV down but sleep and resting HR fine — say so
rather than averaging the conflict away. That pattern often means one poor
night's measurement rather than genuine fatigue, and the honest response is to
train as planned and look again tomorrow.
