# Flight model fidelity pass

Adds to SFFlightModel (all defaults reproduce the previous behaviour for existing callers):
- `Propulsion.swift`: piston (Gagg-Farrar lapse, turbo critical altitude, prop torque, P-factor) and turbojet/afterburner engines, multi-engine layouts with per-engine failure (`ControlInputs.engineFailureMask`), windmilling drag, `EngineSpool` throttle lag.
- `MachSchedule.swift`: compressibility (lift slope, CLmax, wave drag, pitch stability, control power) and `StallBehavior` (wing drop, autorotation, nose drop, buffet margin).
- `Turbulence.swift`: seeded Dryden-style gusts (first-order shaping filters).
- Ground handling: friction circle, speed-faded nose-wheel steering, `FlightEnvironment.surfaceFriction` (wet/snow/ice), retractable gear with belly contact when retracted.
- New outputs: `mach`, `loadFactor`, `stallWarning`. New inputs: `gear`, `speedbrake`.
- Catalog (ids match SFGameplay): `.sf2Cruiser` = org.skyforge.sfc, `.sf3Twin` = org.skyforge.sf3, `.sf5Jet` = org.skyforge.sft1, `.sf9Fighter` = org.skyforge.sff1 (supersonic-capable).
- SF-1 mild stall behaviour added. The oracle flags `cnAileron` (-0.053) as likely 10x too large (c172p: -0.0053); not changed here because it shifts the instrument golden images (follow-up: change it and re-bless goldens).
- `tools/jsbsim_oracle/`: JSBSim c172p comparison (P1.1b). See its README and RESULTS.md (results are for the pre-change SF-1; re-port before trusting).

Not modelled yet: fuel burn/CG shift, dynamic-stall hysteresis, spool state inside the model, hydroplaning.
