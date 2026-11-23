# Gameplay layer: missions, aircraft selection, military flight

Module `SFGameplay` (pure Swift, runs headless on Linux) plus `SFGameplayUI` (SwiftUI, Apple only). Nothing in
the renderer, `WorldShaders.swift`, `WorldRenderer.swift` or `SFFlightModel` was edited.

## What is in it

| Area | Files | Notes |
| --- | --- | --- |
| Aircraft | `Aircraft.swift` | Five types: SF-1 Trainer, SF-C Cruiser, SF-A Aerobat (civil) and SF-T1 Jet Trainer, SF-F1 Interceptor (military). The SF-1 and SF-A are `AircraftConfig`s built from `.sf1Trainer`. The cruiser, jet trainer and interceptor use the flight-model catalog configs (`sf2Cruiser`, `sf5Jet`, `sf9Fighter`), with automatic landing gear that travels over time through `GearActuator`. |
| Envelope | `Envelope.swift` | Load factor, Mach, a fly-by-wire pitch limiter (stick range from the quasi-static pitch response, no feedback loop) and a monitor for stall, overspeed, Mach, flap speed, g and terrain warnings. Airframe fails past 150 % of a g limit or 125 % of Vne. |
| Military | `Military.swift` | AI aircraft (straight, orbit, route, evade and dogfight), cannon with ballistic rounds, heat-seeking and radar-guided missiles, lock time and proportional navigation, flares and chaff, target cycling, formation slots. Deterministic. |
| Missions | `Mission.swift`, `MissionRuntime.swift`, `MissionCatalog.swift` | Runway-frame coordinates so missions work at any airport, including the six showcase airports. 12 missions: First Flight, Traffic Pattern, Crosswind Precision, Wingman, Quick Reaction Alert, Gunnery Range, Low-Level Navigation, Air Combat Training, Coastal Survey and Twin Bandits, plus the combat missions Radar Intercept and Two-Ship Defence. Scoring, time bonus, g penalty, medals. |
| Progress | `Progress.swift` | Best score and medal per mission, unlock rules for aircraft and missions, atomic JSON store that survives a corrupt file. |
| Session | `GameplaySession.swift`, `HUD.swift` | Fixed 120 Hz flight with mission, AI, weapons and envelope; plain-value HUD model. |
| UI | `SFGameplayUI/GameplayViews.swift` | `AircraftPickerView`, `MissionListView`, `MissionHUDView`. |

## Unlock chain

Aircraft: First Flight unlocks the SF-A Aerobat. Traffic Pattern unlocks the SF-T1 Jet Trainer. Wingman unlocks the SF-F1 Interceptor.

Missions: First Flight unlocks Traffic Pattern. Traffic Pattern unlocks Crosswind Precision, Gunnery Range and Coastal
Survey. Wingman unlocks Quick Reaction Alert and Low-Level Navigation. Quick Reaction Alert unlocks Air Combat Training,
which unlocks Twin Bandits. A test plays the whole chain to make sure nothing deadlocks.

## Combat

- Damage has three zones: airframe, engine and controls, each 0 to 1. Engine damage cuts thrust. Control damage cuts
  control authority. Airframe damage at zero ends the flight.
- The radar has four modes: off, standby, search and track. It scans a fixed forward cone. A contact in track mode
  can be locked, and the HUD shows the lock text.
- Flares pull heat-seeking missiles off the player. Chaff does the same to radar missiles. Both are limited in number.
- The radar missile guides on the locked contact and can be spoofed by chaff.
- Dogfight AI fighters turn to the player, fire guns in range and launch missiles when they have a shot.
- Nothing was compiled or run in this environment. Numbers are first guesses until the tests pass in CI.

## Honest limits

- The Aerobat and SF-1 still use the simple trainer model. The jet trainer and interceptor use the flight-model catalog
  (turbojet propulsion, Mach schedule, speed brake), so their Mach limits are set by the flight model where it models them.
- Landing gear travels over time. Automatic gear is commanded down on the ground or below 1.35x approach speed.
- Trim and speed numbers were checked against a Python port of `FlightModel.forcesAndMoments` (level trim converges for
  every aircraft at cruise and approach speed; sea-level top speeds about 71, 80, 214 and 329 m/s). Nothing was compiled
  or run in Swift here.
- AI dogfight fighters fight back with guns and missiles. The player has airframe, engine and control damage. The radar is a fixed forward scan cone with no sweep, and the flare and chaff models are simplified. There is no multiplayer.
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
5. The new combat tests in `SFGameplayTests` (Damage, Radar, Countermeasures, Dogfight, CombatWeapon, CombatSession,
   CombatMission) need to pass in CI.
6. Feel and balance: flying every mission in each allowed aircraft, with the fighter's limiter gain and the missile envelope.
