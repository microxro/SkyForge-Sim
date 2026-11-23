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

## Traffic at each field

Every field that Quick Flight starts from gets traffic. `TrafficProfile` sets the traffic from the runway, so
the field's runway length decides how busy it is:

| Field class | Runway length | Arrival and departure means | Most aircraft | Types |
|---|---|---|---|---|
| Busy | 2,400 m and longer | 110 s and 160 s | 8 | all four civil types |
| Medium | 1,200 m to 2,400 m | 150 s and 210 s | 6 | all four civil types |
| Quiet | under 1,200 m | 240 s and 320 s | 3 | SF-1 and SF-C only |

Each field has its own seed, taken from the threshold position, so two fields do not repeat the same
movements. The same runway always gives the same traffic. `TowerSession` builds the traffic from the profile,
so the game and Quick Flight use the same rules at every field.

## Approach, departure and handoffs

Each aircraft is with one controller at a time, the `TrafficFacility`:

- **Approach** has an arrival from spawn until it reaches the pattern entry (the downwind leg). A new arrival is
  given "approach, radar contact" and then "report downwind".
- **Tower** has everything on the runway and the pattern: holds, takeoff rolls, the legs, landing and rollout.
  An arrival that reaches the downwind leg is handed to the tower with "contact tower".
- **Departure** has a departure once it is 3 km along the runway ("contact departure"). The same 3 km is where
  ownship's climb out ends. When ownship flies back inbound it stays with departure until it reaches the
  pattern, then goes back to the tower with "contact tower".

`TrafficSystem.facility(current:phase:alongRunway:)` is the rule, and each aircraft and ownship keep their own
facility from tick to tick. `ATCController` announces a change once. Handoffs have no clearance and need no
readback; they are advisories, like the phase calls.

The tower does not sequence arrivals by vectors or hold them at an approach fix yet. Spacing still happens at
base, as before.

## How the tower decides

The tower is a state machine of fixed rules, not a model:

1. **Advisories** on every phase change: "report downwind", "report final", "extend downwind for spacing",
   "vacate the runway when able", "airborne, climb straight out".
   **Handoffs** when the controller changes: "approach, radar contact" for a new arrival, "contact tower" when
   an arrival reaches the pattern or ownship rejoins the pattern, and "contact departure" when a departure
   passes 3 km. Each handoff is said once. See "Approach, departure and handoffs" below.
2. **Landing clearance** goes to the first base-leg arrival, when no takeoff is rolling and spacing allows.
   Spacing is 75 s, or 120 s after a heavy aircraft when the next one is light (wake turbulence). A light
   aircraft that follows a heavy within 150 s also gets "caution, wake turbulence".
3. **Takeoff clearance** goes to the first departure holding short, when no arrival is on final or
   landing, nothing else is cleared to land, and 60 s have passed since the last takeoff.
4. An arrival without a clearance at the base-to-final turn is sent around the pattern ("extend downwind").

Words come from `ATCPhrase` templates (digits spoken one by one, as pilots say them). The same traffic
always gets the same words.

## Approach control

Approach control works on arrivals that are with approach (not yet on the pattern). It is a set of fixed rules,
the same kind as the tower's:

- **Vector.** An arrival more than 4 km along the runway is turned onto a heading toward the approach fix (the
  downwind entry, 1.2 km along and 1 km to the right of the runway). The aircraft flies that heading until it is
  sent direct.
- **Direct.** Within 4 km along the runway, the vectored arrival is sent direct to the fix.
- **Hold.** An arrival within 1.5 km of the fix is held there while the landing slot is taken: another arrival is
  on base or final, or landing spacing has not passed. A held arrival orbits the fix at 1.2 km radius.
- **Release.** When the slot is free, the arrival is released and flies on to the downwind leg. The tower then
  has it and sequences it as before.

Only AI arrivals are vectored and held. Ownship gets the advisories ("approach, radar contact", "contact tower")
and no vectors or holds, because the pilot has no control of that kind yet.

`TrafficSystem.apply(_:to:)` carries out the instructions (`TrafficControl`: vector, direct, hold, release).
`TowerSession` applies them to AI traffic after each decision tick.

## Traffic in missions

A mission turns traffic on with `MissionDefinition.traffic`. Its flight then gets a tower with the field's
traffic and readback prompts, shown on the same overlay as Quick Flight. The landing missions (pattern landing and
crosswind precision) set it. Missions read the tower through `GameplaySession.atc` and
`ATCController.ownshipStatus`. Nothing scores on the tower yet.

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
- Quick Flight draws the AI aircraft, in missions that set `traffic` too. Renderer
  edits go through the renderer thread.
- Fields are the ones Quick Flight can start from. The six showcase fields ship with tile packs. Other
  fields come from the bundled OurAirports data and stream on first use. Adding a showcase pack needs
  `sfpreview pack-airport`, which runs on a Mac. The traffic profile applies to any field with runway data.
- Taxi is not modelled. A flight that starts on the runway begins at the hold short line.
- Ownship phases are read from position and ground contact, not from the pilot's controls. A go-around is
  flown as a departure.
- Ownship is never vectored or held. It only gets advisories.

## Tests

`Tests/SFTrafficTests` and `Tests/SFATCTests` cover performance, pattern geometry, the arrival and departure
state machines, determinism, wake shedding, phrase templates, clearance rules, wake spacing, ownship phases,
readback prompts, the ownship counts, the facility rule and its handoffs, the field profiles, approach control
(vectors, direct, holds and releases, and that ownship is never held), and the approach fix itself. The profile
tests check that every field, from a 800 m strip to a 3 km runway, gets arrivals and departures.
