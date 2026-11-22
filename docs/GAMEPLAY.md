# Gameplay layer: missions, aircraft selection, military flight

Module `SFGameplay` (pure Swift, runs headless on Linux) plus `SFGameplayUI` (SwiftUI, Apple only). Nothing in
the renderer, `WorldShaders.swift`, `WorldRenderer.swift` or `SFFlightModel` was edited.

## What is in it

| Area | Files | Notes |
| --- | --- | --- |
| Aircraft | `Aircraft.swift` | Five types: SF-1 Trainer, SF-C Cruiser, SF-A Aerobat (civil) and SF-T1 Jet Trainer, SF-F1 Interceptor (military). Each is an `AircraftConfig` built from `.sf1Trainer`, so the existing 6-DOF model flies all of them. |
| Envelope | `Envelope.swift` | Load factor, Mach, a fly-by-wire pitch limiter (stick range from the quasi-static pitch response, no feedback loop) and a monitor for stall, overspeed, Mach, flap speed, g and terrain warnings. Airframe fails past 150 % of a g limit or 125 % of Vne. |
| Military | `Military.swift` | AI aircraft (straight, orbit, route, evade), cannon with ballistic rounds, heat-seeking missile with seeker cone, lock time and proportional navigation, target cycling, formation slots. Deterministic. |
| Missions | `Mission.swift`, `MissionRuntime.swift`, `MissionCatalog.swift` | Runway-frame coordinates so missions work at any airport. 8 missions: First Flight, Traffic Pattern, Crosswind Precision, Wingman, Quick Reaction Alert, Gunnery Range, Low-Level Navigation, Air Combat Training. Scoring, time bonus, g penalty, medals. |
| Progress | `Progress.swift` | Best score and medal per mission, unlock rules for aircraft and missions, atomic JSON store that survives a corrupt file. |
| Session | `GameplaySession.swift`, `HUD.swift` | Fixed 120 Hz flight with mission, AI, weapons and envelope; plain-value HUD model. |
| UI | `SFGameplayUI/GameplayViews.swift` | `AircraftPickerView`, `MissionListView`, `MissionHUDView`. |

## Unlock chain

First Flight unlocks SF-A Aerobat and Traffic Pattern. Traffic Pattern unlocks the SF-T1 Jet Trainer, Crosswind Precision
and Gunnery Range. Wingman (jet) unlocks the SF-F1 Interceptor, Quick Reaction Alert and Low-Level Navigation. Quick
Reaction Alert unlocks Air Combat Training. A test plays the chain to make sure nothing deadlocks.

## Honest limits

- Jets reuse the model's power-based thrust law. Thrust is flat up to a knee speed (220 and 300 m/s) and then falls as
  1/V. There is no afterburner, no compressibility drag and no fuel burn. The Mach limit and g limit are enforced by the
  control law and monitor, not by the aerodynamics. The flight-model thread's compressibility work should replace the
  stand-in; the builders in `Aircraft.swift` are the one place to switch.
- Trim and speed numbers were checked against a Python port of `FlightModel.forcesAndMoments` (level trim converges for
  every aircraft at cruise and approach speed; sea-level top speeds about 71, 80, 214 and 329 m/s). Nothing was compiled
  or run in Swift here.
- Weapons fire at AI drones only. There is no multiplayer, no damage to the player, and no radar or countermeasures.
- Rendering other aircraft types needs mesh work in the renderer. `QuickFlightWorld.aircraftMesh` still draws the SF-1,
  so the app needs a per-type mesh before the picker changes what the player sees.
- The session is not wired into the app shell yet: `QuickFlightSession` still owns the live flight.

## Needs a Mac (or Linux with Swift 6.2) run

1. `swift build` in `Packages/SkyforgeKit`: nothing here was compiled. Expect small fixes.
2. `swift test --filter SFGameplayTests`. Tests worth watching: `scriptedTakeoffGetsAirborne`,
   `fighterLimiterKeepsTheAirframeIntactUnderFullBackStick`, `missileNeedsLockThenKillsCrossingTarget`,
   `speedsAreOrderedAndTrimConverges`, `freeFlightSitsOnTheRunwayAndStaysFinite`. They exercise the real flight model.
   A failure there is a tuning issue (gear stiffness, limiter margin), not necessarily a logic bug.
3. Xcode build of the app on macOS and iOS Simulator to compile `SFGameplayUI` (SwiftUI, not compiled on Linux).
4. Wire `GameplaySession` into the app: aircraft picker, mission list, HUD overlay, input mapping to `PilotControls`.
5. Feel and balance: flying every mission in each allowed aircraft, with the fighter's limiter gain and the missile envelope.
