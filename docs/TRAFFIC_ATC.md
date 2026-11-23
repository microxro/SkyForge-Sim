# AI traffic and ATC

Free and open source, like the rest of the project. Nothing here calls a network service, needs an API key,
or bundles a licensed voice or data pack.

## Modules

| Module | What it does | Depends on |
|---|---|---|
| `SFTraffic` | AI aircraft at one runway: arrivals fly the traffic pattern, departures hold short, roll and climb out. Heavy aircraft shed wake pairs. | `SFFlightModel`, `SFAtmosphere` |
| `SFATC` | Rule-based tower: clearances, advisories and phrase templates. Optional speech through `AVSpeechSynthesizer`. | `SFTraffic` |
| `SFGameplay` | `GameplaySession` steps traffic and the tower when `trafficEnabled` is set. The HUD shows the last tower lines. | `SFTraffic`, `SFATC` |
| `SFUI` | Quick Flight (free flight only) runs traffic and the tower, shows the tower lines, and has a "Tower voice" toggle. | all of the above |

## How the aircraft fly

- Each aircraft is a point mass. Its speeds come from its own stall speed (lift equation with its CLmax), so
  a 1 t trainer and a 4.5 t jet use the same rules at different speeds. Its climb rate comes from specific
  power. Every type uses the same 600 m turn radius, and the pattern is 1,000 m out with a 305 m (1,000 ft)
  pattern altitude.
- Types come from `AircraftConfig`: the civil catalog (SF-1, SF-C, SF-3, SF-T1). Military types are not traffic.
- Arrivals: inbound, downwind, base, final, landing rollout. They are spawned 7 km out on the runway extended.
- Departures: hold short, takeoff roll, climb out on a fixed route, then leave the system.
- Heavy aircraft (2,000 kg and above) shed a `WakeVortexPair` every 4 s, which ownship's flight model feels
  through `FlightEnvironment.wakes`.

## How the tower decides

The tower is a state machine of fixed rules, not a model:

1. **Advisories** on every phase change: "report downwind", "report final", "extend downwind for spacing",
   "vacate the runway when able", "airborne, contact departure".
2. **Landing clearance** goes to the first base-leg arrival, when no takeoff is rolling and spacing allows.
   Spacing is 75 s, or 120 s after a heavy aircraft when the next one is light (wake turbulence). A light
   aircraft that follows a heavy within 150 s also gets "caution, wake turbulence".
3. **Takeoff clearance** goes to the first departure holding short, when no arrival is on final or
   landing, nothing else is cleared to land, and 60 s have passed since the last takeoff.
4. An arrival without a clearance at the base-to-final turn is sent around the pattern ("extend downwind").

Words come from `ATCPhrase` templates (digits spoken one by one, as pilots say them). The same traffic
always gets the same words.

## Voice

`ATCSpeaker` is a protocol. The default is `SilentATCSpeaker`. On Apple platforms the app uses
`AVSpeechATCSpeaker`, which calls Apple's built-in `AVSpeechSynthesizer`. That voice ships with the OS, so
the project bundles no voice files and needs no licence beyond the OS.

## Ownship

The tower sees the player's aircraft as one more entry in its picture, with the id `TrafficOwnship.id` and the
callsign "N one zero zero". `OwnshipTracker` works out its phase from the flight state:

- On the runway and not yet flown: holds short, then takes the roll as `takeoffRoll`.
- Climbing out after lift-off: `departing`, until 3 km along the runway. Then it is inbound again.
- Airborne near the field: the nearest pattern leg (`downwind`, `base`, `final`), or `inbound` when it is far
  from the pattern. After touchdown it is `landing`.

The same rules sequence ownship and AI traffic. A landing goes to the first base-leg arrival, a takeoff to the
first departure holding short, and an arrival on final holds ownship on the ground.

Clearances to ownship are read back. The tower opens a prompt with three choices: one repeats the clearance
correctly, and two are wrong. A correct choice confirms the clearance. A wrong one gets "say again", and the
prompt stays open. While a prompt is open, the tower clears nothing else. `GameplaySession.towerPrompt` and
`GameplaySession.answerTower(choice:)` expose the prompt, and Quick Flight shows the choices as buttons.

Missions read `ATCController.ownshipStatus` (through `GameplaySession.atc`): `landingCleared`, `takeoffCleared`,
`unauthorizedTakeoffs` (rolls with no takeoff readback), and `unclearedLandings` (touchdowns with no landing
readback). The tower also says so on the log when either happens. Nothing stops the aircraft. The mission decides
what the count is worth.

## Limits (for later)

- One runway per field: the one nearest the world's runway. Runway choice by wind is not done yet.
- AI altitudes are relative to the field elevation. Traffic does not avoid terrain, so mountain fields
  (for example KASE) can put traffic low over hills near the pattern.
- No collisions between aircraft, and AI aircraft are not weapon targets.
- The renderer does not draw AI aircraft yet. `GameplaySession.trafficSnapshots` and
  `TrafficSystem.snapshots` expose them for it. Renderer edits go through the renderer thread.
- Taxi is not modelled. A flight that starts on the runway begins at the hold short line.
- Ownship phases are read from position and ground contact, not from the pilot's controls. A go-around is
  flown as a departure.
- Quick Flight is the only place a prompt is answered on screen. Mission HUDs do not show the prompt yet.

## Tests

`Tests/SFTrafficTests` and `Tests/SFATCTests` cover performance, pattern geometry, the arrival and departure
state machines, determinism, wake shedding, phrase templates, clearance rules, wake spacing, ownship phases,
readback prompts and the ownship counts.
