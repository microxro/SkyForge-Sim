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

## Aircraft maintenance (`Maintenance.swift`)
Extends the existing career. It adds no module and no second wallet: servicing spends `CareerState.credits`, and sales refund into them.
- **State**: `CareerState.maintenance`, keyed by owned aircraft id. Each entry holds six components (engine, propeller, brakes, tires, airframe, avionics) with wear (0 to 1), hours since service and a defect flag, plus a capped history. Saves that predate it load with an empty map.
- **Wear**: `CareerEngine.apply` calls `FlightWear.apply` for owned aircraft. Wear comes from flight hours, landings (not crashes), and hard landings (sink above 600 fpm, airframe). A crash adds airframe wear and a defect.
- **Failures**: above 0.8 wear, each flight hour risks a failure, capped at 5%. Rolls are seeded from the flight's `endedAt` and aircraft id, so the same flight always rolls the same way. Failures appear in `FlightOutcome.maintenanceFailures`.
- **Service**: inspection (resets interval, 8% of overhaul), repair (clears defect, -0.25 wear, 50%), overhaul (full reset, 100%). Costs are a share of the component's overhaul fraction of the reference price (catalogue price, or 30,000 for the starter).
- **Dispatch**: `CareerState.dispatchStatus(for:)` returns serviceable, warning or grounded. It is advisory. Flights are not blocked yet. The job-accept and free-flight UI should check it before dispatch.
- **Sales**: `CareerState.sell(aircraftID:)` refunds resale value (reference price, less hours, wear and defects). The starter cannot be sold.

Not yet built: hangar or tie-down rent, fuel, the dispatch gate in the UI, and wiring SFGameplay engine failures to component wear.
