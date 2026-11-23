# JSBSim oracle comparison (offline dev tool)

Compares the SF-1 Trainer flight model (`Packages/SkyforgeKit/Sources/SFFlightModel`) against JSBSim's Cessna 172P
as an independent sanity reference: trim, stall speeds, short period, roll, phugoid, sideslip and takeoff.
The c172p is a different aircraft, so the bands in `compare.py` are sanity bands. A WARN or FAIL means
"explain it or fix it", not automatically "the SF-1 is wrong".

**Licensing:** JSBSim (LGPL code, aircraft data under its own licences, MIT/LGPL mix) is used only as an offline
development tool on a developer machine. Nothing from JSBSim or its data is shipped in the app, copied into the Swift
sources or vendored in this repo; only numbers it produced are written to `jsbsim_results.json` and `RESULTS.md`.
`pip install jsbsim` is not a dependency of the app or of CI.

## Requirements

Python 3.10+, `pip install jsbsim numpy` (tested with jsbsim 1.3.3, numpy 2.x). No Swift needed for the mirror path.

## Usage

```
./run_all.sh                    # everything: JSBSim, mirror, sensitivity checks, comparison -> RESULTS.md
python3 run_jsbsim.py [-o jsbsim_results.json] [--only trim,takeoff] [--selfcheck]
python3 run_sf1.py    [-o sf1_results.json]    [--only ...] [--series]
python3 whatif.py                                # one-coefficient-at-a-time checks on the mirror
python3 compare.py [--sf1 X.json] [--jsbsim Y.json] [--strict]    # table, RESULTS.md, oracle_results.json
python3 check_mirror.py swift.json sf1_results.json              # Swift emitter output == mirror?
```

`--selfcheck` verifies the c172p control sign conventions and the CL definition against the live model.
`--strict` makes `compare.py` exit 1 on any FAIL or missing metric (suitable for a manual gate, not CI: the c172p
differs from the SF-1 by design in places).

## Files

| File | Role |
|---|---|
| `scenarios.py` | Scenario definitions, control laws, metric extraction. Shared by every side. |
| `sf1_mirror.py` | Line-by-line Python port of `FlightModel` for the SF-1. **Must match the Swift source.** |
| `run_sf1.py` / `run_jsbsim.py` | Plant adapters (mirror / JSBSim c172p at 1000 kg) that drive `scenarios.py`. |
| `compare.py` | Bands, table, `RESULTS.md`, `oracle_results.json`. |
| `whatif.py` | Single-coefficient sensitivity checks to confirm suspected causes. |
| `check_mirror.py` | Diffs Swift-emitted JSON against the mirror. |
| `SWIFT_EMITTER.md`, `OracleExportTests.swift` | Spec and proposed Swift test that emits the same JSON from the real model. |
| `RESULTS.md`, `oracle_results.json`, `*_results.json` | Latest generated results. |

## Keeping the mirror honest

`sf1_mirror.py` currently mirrors `SFFlightModel` as of git HEAD (FlightDynamics.swift 389 lines, AircraftConfig.swift 101 lines). Uncommitted
working-tree changes (Mach schedule, engine model, stall behaviour, speed brakes, surface friction) are not ported yet.

1. Whenever `AircraftConfig.swift` or `FlightDynamics.swift` change, update `sf1_mirror.py` the same way.
2. Once the Swift test exists, run it and `check_mirror.py`; fix the mirror until there are 0 differences.
3. Eventually `compare.py --sf1` can read the Swift output directly and the mirror can be retired.

## Scenario summary (`scenarios.py`)

1000 kg, ISA, no wind, 120 Hz. Trim 100 KTAS / 3000 ft. Stalls: power off from 80 KTAS (clean) or 65 KTAS (full flaps),
wings level, pitch attitude ramped at 1 deg/s through a pitch-hold loop; speed read at the CL peak. Short period: +/-2.5 deg
elevator doublet (0.5 s halves), damped-sinusoid fit of pitch rate. Aileron: 50% stick step, steady roll rate. Phugoid: +8 kt
speed offset from trim, 150 s, wings held level, fit of airspeed. Rudder: 50% pedal step with wings held level, sideslip
after 12 s. Takeoff: full power, rotate at 55 KCAS to 9 deg pitch, ground roll to liftoff and distance to 55 ft height gain.
