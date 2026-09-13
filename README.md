# Hybrid Athlete

An iPhone app for people training for endurance and strength at the same time.
It reads everything your Suunto (or any watch) writes into Apple Health, puts
running and lifting on one comparable load scale, works out how recovered you
are, and adjusts today's session — with Claude doing the reasoning when you
turn it on, and on-device rules when you don't.

SwiftUI, iOS 17+, no third-party dependencies.

---

## Getting it running

You need a Mac with Xcode 15 or later, and an iPhone (HealthKit does not work
in the Simulator — there is no health data there).

```bash
open HybridAthlete.xcodeproj
```

1. Select the `HybridAthlete` target → Signing & Capabilities → pick your team.
2. Change the bundle identifier from `app.hybridathlete.ios` to something in
   your own namespace.
3. Confirm the **HealthKit** capability is present (the entitlements file
   already declares it).
4. Build to your iPhone. Run the tests with ⌘U.

A free Apple developer account works; the build expires after seven days and
needs re-installing.

If you prefer generating the project yourself:

```bash
brew install xcodegen && xcodegen generate    # uses project.yml
# or, with no extra tooling:
python3 Scripts/generate_xcodeproj.py
```

Re-run either after adding or removing a source file.

---

## How Suunto connects

**Through Apple Health, not through Suunto's servers.**

```
Suunto watch → Suunto app → Apple Health → Hybrid Athlete
```

In the Suunto app: Settings → Apple Health → on, and allow every category
(especially Heart Rate Variability and Sleep, which are easy to miss). The app
detects Suunto-sourced sessions, watches for a sync going stale, and walks you
through fixing it — a silent sync failure looks exactly like a rest week and
would quietly corrupt every load number downstream.

This route needs no API keys and no approval, and it works identically for an
Apple Watch, a Garmin, or anything else that writes to Health.

`SuuntoCloudClient.swift` implements Suunto's direct cloud API as a second
source, but it is **off by default and not recommended**: Suunto gates that API
behind a partner-program agreement, so most individuals cannot get credentials,
and the Health route carries the same workout data anyway.

---

## What it actually computes

**One load number for every kind of session.** An hour at lactate-threshold
heart rate is defined as 100, for running, cycling and lifting alike.

- Endurance sessions use Banister TRIMP from average heart rate, rescaled to
  that anchor.
- Strength sessions use session-RPE (your 1–10 rating × duration). Heart rate
  badly under-reports the cost of heavy triples, so **logging RPE on lifting
  days is what keeps the whole model honest**.
- Anything with neither falls back to a conservative per-modality hourly rate.

**Fitness, fatigue, form.** Exponentially weighted averages of daily load —
42-day (fitness/CTL), 7-day (fatigue/ATL), and the gap between them (form/TSB).
Plus acute:chronic workload ratio, Foster monotony and strain.

**Readiness, 0–100.** HRV (log-transformed SDNN), resting heart rate and sleep,
each z-scored against *your own* rolling 60-day baseline rather than population
norms, blended with current form. It reports a confidence alongside the score
and says plainly when the baseline is too short to conclude anything — roughly
the first two weeks.

**Adjustment.** Readiness, form and acute:chronic ratio decide whether today's
session runs as written, gets scaled, gets downgraded in intensity, or becomes
rest. Hard sessions are downgraded rather than merely shortened, because half a
VO2max session still costs what a VO2max session costs. Concurrent-training
interference — heavy lower-body work within ~6 hours of hard endurance — is
flagged explicitly.

---

## Where Claude fits

Off by default. When enabled, a coaching pass sends a compact JSON snapshot
(profile, 60 days of daily metrics, 21 days of sessions, current load picture,
this week's plan) to the Anthropic Messages API and gets back a schema-validated
adjustment with its reasoning. There's also a chat tab for follow-up questions
answered against your real numbers.

Three things make this safe rather than decorative:

1. **The rule engine always runs first.** Its answer is what applies if Claude
   is unavailable, declines, or errors. No key and no network still gives you a
   working app.
2. **Everything Claude proposes is sanitised.** Load is capped at +25% of plan,
   duration at +30%, and an intensity upgrade is refused unless readiness is
   genuinely high. A suggestion never reaches your plan unchecked.
3. **The output is schema-constrained**, so there is no prose-parsing step to
   go wrong.

Model: `claude-opus-5` with adaptive thinking. The system prompt is byte-stable
and cached, so repeat passes are cheap — a daily pass costs single-digit cents.

---

## Security and privacy

- Your health data stays on the device unless you switch Claude coaching on.
  With it on, each pass sends the snapshot described above to Anthropic.
- The API key lives in the iOS Keychain (`WhenUnlockedThisDeviceOnly`), never
  in source or `UserDefaults`.
- **A key on the device is still a key on the device.** That is fine for a
  personal build. If you ever hand this app to anyone else, move the key behind
  a small proxy server you control and point `ClaudeClient.endpoint` at it.
- The app requests read-only Health access and never writes to Health.
- Settings → Export dumps everything as JSON.

---

## Layout

| Path | What lives there |
| --- | --- |
| `HybridAthlete/Models` | Core value types: sessions, daily metrics, plan, profile |
| `HybridAthlete/Health` | HealthKit reads, Suunto sync diagnostics, optional cloud client |
| `HybridAthlete/Engine` | Load maths, readiness, the rule-based adapter, plan generator |
| `HybridAthlete/Coach` | Anthropic client, prompt + snapshot builder, response schema |
| `HybridAthlete/Store` | App state and JSON persistence |
| `HybridAthlete/Views` | SwiftUI screens |
| `Tests` | Load, readiness, adaptation, Claude-contract and sync tests |

---

## Known limits

- Readiness needs ~14 days of overnight data before the z-scores mean much, and
  ~60 for full confidence. The app tells you this rather than hiding it.
- Threshold heart rate is entered manually and anchors the entire load scale.
  Get it roughly right: the average heart rate from a hard 30-minute effort is
  a reasonable starting estimate.
- Strength load depends on you logging an RPE. Without it, lifting is
  systematically under-counted.
- No watch app. Sessions are recorded on the watch as normal and read back
  through Health.
- HealthKit background delivery isn't wired up; data refreshes when you open
  the app or pull to refresh.

---

Training guidance only, not medical advice. Stop and see a clinician for chest
pain, dizziness, a joint that keeps getting worse, or anything that doesn't fit
a hard training week.
