# Gameplay layer: missions, aircraft selection, military flight

Module `SFGameplay` (pure Swift, runs headless on Linux) plus `SFGameplayUI` (SwiftUI, Apple only). Nothing in
the renderer, `WorldShaders.swift`, `WorldRenderer.swift` or `SFFlightModel` was edited.

## What is in it

| Area | Files | Notes |
| --- | --- | --- |
| Aircraft | `Aircraft.swift` | Five types: SF-1 Trainer, SF-C Cruiser, SF-A Aerobat (civil) and SF-T1 Jet Trainer, SF-F1 Interceptor (military). The SF-1 and SF-A are `AircraftConfig`s built from `.sf1Trainer`. The cruiser, jet trainer and interceptor use the flight-model catalog configs (`sf2Cruiser`, `sf5Jet`, `sf9Fighter`), with automatic landing gear that travels over time through `GearActuator`. |
| Envelope | `Envelope.swift` | Load factor, Mach, a fly-by-wire pitch limiter (stick range from the quasi-static pitch response, no feedback loop) and a monitor for stall, overspeed, Mach, flap speed, g and terrain warnings. Airframe fails past 150 % of a g limit or 125 % of Vne. |
| Military | `Military.swift` | AI aircraft (straight, orbit, route, evade), cannon with ballistic rounds, heat-seeking missile with seeker cone, lock time and proportional navigation, target cycling, formation slots. Deterministic. No player damage, radar or countermeasures yet. |
| Missions | `Mission.swift`, `MissionRuntime.swift`, `MissionCatalog.swift` | Runway-frame coordinates so missions work at any airport, including the six showcase airports. 10 missions: First Flight, Traffic Pattern, Crosswind Precision, Wingman, Quick Reaction Alert, Gunnery Range, Low-Level Navigation, Air Combat Training, Coastal Survey and Twin Bandits. Scoring, time bonus, g penalty, medals. |
| Progress | `Progress.swift` | Best score and medal per mission, unlock rules for aircraft and missions, atomic JSON store that survives a corrupt file. |
| Session | `GameplaySession.swift`, `HUD.swift` | Fixed 120 Hz flight with mission, AI, weapons and envelope; plain-value HUD model. |
| UI | `SFGameplayUI/GameplayViews.swift` | `AircraftPickerView`, `MissionListView`, `MissionHUDView`. |

## Unlock chain

Aircraft: First Flight unlocks the SF-A Aerobat. Traffic Pattern unlocks the SF-T1 Jet Trainer. Wingman unlocks the SF-F1 Interceptor.

Missions: First Flight unlocks Traffic Pattern. Traffic Pattern unlocks Crosswind Precision, Gunnery Range and Coastal
Survey. Wingman unlocks Quick Reaction Alert and Low-Level Navigation. Quick Reaction Alert unlocks Air Combat Training,
which unlocks Twin Bandits. A test plays the whole chain to make sure nothing deadlocks.

## Honest limits

- The Aerobat and SF-1 still use the simple trainer model. The jet trainer and interceptor use the flight-model catalog
  (turbojet propulsion, Mach schedule, speed brake), so their Mach limits are set by the flight model where it models them.
- Landing gear travels over time. Automatic gear is commanded down on the ground or below 1.35x approach speed.
- Trim and speed numbers were checked against a Python port of `FlightModel.forcesAndMoments` (level trim converges for
  every aircraft at cruise and approach speed; sea-level top speeds about 71, 80, 214 and 329 m/s). Nothing was compiled
  or run in Swift here.
- Weapons fire at AI drones only. There is no multiplayer, no damage to the player, no radar and no countermeasures.
- There is no AI air traffic and no air traffic control. Missions are the only other aircraft in the world.
- Per-aircraft meshes come from `AircraftVariants` (renderer side, #25). The mesh wheels and wing spans match the flight
  model. The SF-1 keeps its own mesh.
- The app shell links to the mission and aircraft menu (`GameplayMenuView`), and `QuickFlightController` runs the mission
  flight. `GameplaySession` is the headless equivalent used in tests.

## Needs a Mac (or Linux with Swift 6.2) run

1. `swift build` in `Packages/SkyforgeKit`: nothing here was compiled. Expect small fixes.
2. `swift test --filter SFGameplayTests`. Tests worth watching: `scriptedTakeoffGetsAirborne`, `retractableGearFollowsTheAirspeedRule`,
   `fighterLimiterKeepsTheAirframeIntactUnderFullBackStick`, `missileNeedsLockThenKillsCrossingTarget`,
   `speedsAreOrderedAndTrimConverges`, `freeFlightSitsOnTheRunwayAndStaysFinite`. They exercise the real flight model.
   A failure there is a tuning issue (gear stiffness, limiter margin), not necessarily a logic bug.
3. Xcode build of the app on macOS and iOS Simulator to compile `SFGameplayUI` (SwiftUI, not compiled on Linux).
4. Play each mission on a device at two or more airports, then check the HUD, the result card and the gear.
5. Feel and balance: flying every mission in each allowed aircraft, with the fighter's limiter gain and the missile envelope.
