# Swift emitter spec (oracle JSON)

Purpose: run the **real** `FlightModel` through the same scenarios as the Python mirror and JSBSim, so the
comparison no longer depends on `sf1_mirror.py` being a faithful port.

* Proposed test source: `OracleExportTests.swift` (copy to
  `Packages/SkyforgeKit/Tests/SFFlightModelTests/OracleExportTests.swift`; it was written without a Swift
  toolchain and is not compiled yet). Swift Testing (`import Testing`), `@testable import SFFlightModel`.
* Enabled only when `SF_ORACLE_OUT` is set (`@Test(.enabled(if:))`), so normal `swift test` runs skip it.
* Output path: the value of `SF_ORACLE_OUT`.

```
SF_ORACLE_OUT=/tmp/sf1_swift.json swift test --filter OracleExportTests
python3 tools/jsbsim_oracle/check_mirror.py /tmp/sf1_swift.json tools/jsbsim_oracle/sf1_results.json   # mirror == Swift?
python3 tools/jsbsim_oracle/compare.py --sf1 /tmp/sf1_swift.json                                        # vs JSBSim
```

`check_mirror.py` must report 0 differences (tolerance 1e-4 relative); any difference is a mirror bug
(or a Swift change the mirror has not followed yet).

## What the Swift side must implement

Everything in `scenarios.py` except the curve fits. The test re-implements, line for line:

| Python (`scenarios.py`) | Swift (`OracleExportTests`) |
|---|---|
| Plant interface (`trim`, `init_flight`, `init_ground`, `set_controls`, `step`, `obs`) | `Plant` class |
| `PitchHold` (Kth 1.0, Kq 0.4), `WingsLevel` (Kphi 0.8, Kp 0.35) | `pitchHold`, `wingsLevel` |
| `run_trim`, `_run_stall`, `run_aileron_step`, `run_rudder_step`, `run_takeoff` | `runTrim`, `runStall`, `runAileronStep`, `runRudderStep`, `runTakeoff` |
| `run_short_period`, `run_phugoid` | `runShortPeriod`, `runPhugoid` (emit raw `series`) |

Fixed conditions: 120 Hz (`dt = 1/120`), ISA, no wind, flat terrain at 0 m, mass 1000 kg (the SF-1 default),
`FlightEnvironment()` defaults. Simulation time is relative to the start of each scenario (after trim).
Whenever a constant in `scenarios.py` (`SCENARIOS`, gains, thresholds) changes, change the Swift test too;
`check_mirror.py` will flag the drift.

## JSON schema (version 1)

```jsonc
{
  "meta": { "source": "swift", "model": "SF-1 Trainer", "mass_kg": 1000, "schema_version": 1 },
  "scenarios": {
    "trim":         { "converged": true, "alpha_deg": 1.07, "elevator_deg_up": -0.15, "throttle": 0.727,
                      "power_kw": 79.1, "climb_fpm": 0.0, "cas_kt": 95.7, "cl": 0.407 },
    "stall_clean":  { "cl_max", "v_clmax_kcas", "v_clmax_ktas", "alpha_clmax_deg", "decel_kt_per_s",
                      "cl_ratio_4s_after_peak", "alpha_max_deg", "t_peak_s", "theta_peak_deg", "vz_at_peak_fpm" },
    "stall_flaps":  { /* same keys as stall_clean */ },
    "short_period": { "series": { "t": [..], "q_dps": [..] } },          // every step, 12 s; metrics are fitted by compare.py
    "aileron_step": { "p_ss_dps", "tau_roll_s", "ail_defl_deg", "p_per_deg_ail", "phi_end_deg" },
    "phugoid":      { "series": { "t": [..], "tas_kt": [..], "alt_ft": [..] } },   // every 0.25 s, 150 s
    "rudder_step":  { "beta_ss_deg", "beta_peak_deg", "beta_ss_per_deg_rudder", "r_ss_dps",
                      "phi_max_abs_deg", "rudder_defl_deg" },
    "takeoff":      { "completed": true, "ground_roll_ft", "liftoff_kcas", "t_liftoff_s", "dist_to_55ft_ft",
                      "t_to_55ft_s", "cas_at_55ft_kt", "heading_dev_max_deg" }
                    // if not completed: { "completed": false, "t_end_s", "dist_end_ft", "cas_end_kt", "h_gain_end_ft" }
  }
}
```

Units and conventions

* Speeds in knots (KCAS/KTAS), altitudes and distances in feet, angles in degrees, rates in deg/s, power in kW,
  time in seconds. Conversion constants: 1 kt = 0.514444 m/s, 1 ft = 0.3048 m.
* `elevator_deg_up`: trailing-edge-up positive (= `elevator * elevatorMax`, stick back positive).
  Stick right and right pedal are positive. `alpha`/`beta` are the aerodynamic angles of `FlightOutputs`.
* `cl` is `FlightOutputs.liftCoefficient` (total, including tail and pitch-rate terms).
* A metric that cannot be computed must be `null` (JSON has no NaN); `compare.py` then reports `MISSING`.
* Extra keys are ignored. Missing keys are `MISSING` rows, never silently skipped.
* `python3 run_sf1.py --series` writes the same optional `series` blocks next to the metrics (used to test the fit path).
