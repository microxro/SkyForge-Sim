# Flight model fidelity pass

Adds to SFFlightModel (all defaults reproduce the previous behaviour for existing callers):
- `Propulsion.swift`: piston (Gagg-Farrar lapse, turbo critical altitude, prop torque, P-factor) and turbojet/afterburner engines, multi-engine layouts with per-engine failure (`ControlInputs.engineFailureMask`), windmilling drag, `EngineSpool` throttle lag.
- `MachSchedule.swift`: compressibility (lift slope, CLmax, wave drag, pitch stability, control power) and `StallBehavior` (wing drop, autorotation, nose drop, buffet margin).
- `Turbulence.swift`: seeded Dryden-style gusts (first-order shaping filters).
- Ground handling: friction circle, speed-faded nose-wheel steering, `FlightEnvironment.surfaceFriction` (wet/snow/ice), retractable gear with belly contact when retracted.
- New outputs: `mach`, `loadFactor`, `stallWarning`. New inputs: `gear`, `speedbrake`.
- Catalog: `AircraftConfig.sf2Cruiser`, `.sf3Twin`, `.sf5Jet`, `.sf9Fighter`, `.catalog`.
- SF-1 `cnAileron` corrected from -0.053 to -0.0053 (oracle found a 10x slip); mild stall behaviour added.
- `tools/jsbsim_oracle/`: JSBSim c172p comparison (P1.1b). See its README and RESULTS.md (results are for the pre-change SF-1; re-port before trusting).

Not modelled yet: fuel burn/CG shift, dynamic-stall hysteresis, spool state inside the model, hydroplaning.
