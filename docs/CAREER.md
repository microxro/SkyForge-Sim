# Career layer (SFCareer)

Pure-Swift, Linux-testable module that turns flights into long-term progression. Apache-2.0, no third-party assets.

## What it does
- **Progression**: XP, levels 1–75, eight ranks (Student → Legend). Level-ups pay credits.
- **Economy**: credits, aircraft catalog (rent by level or buy), deterministic daily job board (passenger, cargo, ferry, medevac, survey), settlement with on-time, smooth-landing and passenger-comfort modifiers.
- **Challenges**: landing, time trial, aerobatics and combat scoring with bronze–platinum medals. Only improvements over the best medal pay out, so challenges cannot be farmed.
- **Daily challenge**: same challenge for everyone per UTC day (seeded), with a streak counter.
- **Achievements**: 20 achievements, pure functions of lifetime stats.
- **Saves**: versioned JSON, atomic write, rolling `.bak`, falls back to the backup if the main file is corrupt, and throws rather than overwrite when both are unreadable or the save is from a newer app.

## Integration contract
The sim/gameplay/UI layers build a `FlightReport` when a flight ends and call:

```swift
var career = try SaveStore(url: saveURL).load()
let outcome = CareerEngine.apply(report, to: &career, challenge: activeChallenge)
try SaveStore(url: saveURL).save(career)
```

`FlightReport.sanitized()` clamps every number, so one NaN frame can never corrupt a save. Aircraft and missions are referenced by string id (`org.skyforge.sfc`, mission ids from SFGameplay), so SFCareer has no dependency on the flight model.

## Still to wire (needs a Mac build)
1. Fill `FlightReport` from the sim at touchdown/shutdown (sink rate, offset, g, bank, fuel).
2. Career hub screens in SFUI: profile, hangar, job board, challenge list, achievements.
3. Feed `AirportRef` from SFNavData and gameplay mission results into `.mission(id)`.
