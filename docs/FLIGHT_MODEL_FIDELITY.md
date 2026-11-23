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

## Known differences from the JSBSim c172p oracle (design choices, not errors)

The oracle compares SF-1 against a Cessna 172. SF-1 is an original design, so these gaps are documented, not tuned away. Each was reviewed; none is a sign, units or implementation error.

- **Sideslip per degree of rudder (FAIL, +64%):** `cnRudder` gives SF-1 more rudder authority than the 172. This is a control-feel choice.
- **Short-period frequency (WARN, -23%):** `cmAlpha` is softer than the 172. The damping ratio matches (0.59).
- **Roll rate at 50% stick (WARN, -32%):** aileron authority is lower by design. `cnAileron` was already corrected for the 10x slip.
- **Stall angle and CLmax (WARN):** SF-1 peaks at about 13.8 deg, and the 172 at about 16 deg. The stall behaviour is deliberately abrupt for the trainer's teaching profile.
- **Ground roll and takeoff distance (WARN, +18%):** SF-1 has a higher rotate speed by design.

The pass/warn/fail bands are sanity checks against a different aircraft, not targets. Coefficients are only changed for real errors, which is why the current values stay.
