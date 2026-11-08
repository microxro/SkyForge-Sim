# Architecture

Layers: UI (SFUI, SwiftUI) ↔ Orchestrator (SFSim) ↔ {Simulation: SFFlightModel, SFSystems, SFAtmosphere, SFWeather; World: SFTerrainCore, SFWorldGen, SFNavData; Content: SFContent; Input: SFInput; Instruments: SFInstruments (pitot-static/gyro models and a platform-neutral 2D DrawList consumed by the CPU rasterizer and SwiftUI Canvas); ATC: SFATC} ↔ Platform adapters (SFRender Metal, SFAudio, SFPlatform).

- Simulation: dedicated thread, fixed dt = 1/120 s, accumulator, max 8 substeps (`SFSim.FixedStepClock`); snapshots published through `SFSim.TripleBuffer` (Mutex-guarded); renderer interpolates with `alpha`.
- Precision: ECEF `SIMD3<Double>` (WGS84, `SFMath`), floating origin ENU re-anchored every 10 km, camera-relative float32 vertices, reverse-Z infinite far plane (`Depth32Float`, clear 0, `.greater`).
- Determinism: FDM is a pure step function; seeded PRNG (`Xoshiro256`); world is a pure function of (seed, tile, source version).
- Apple-only code sits behind `#if canImport(...)` so every target builds on Linux.

## Traceability matrix
See docs/MASTER_PROMPT.md §18; rows are updated here as features land.

| Feature | Module | Status | Test |
|---|---|---|---|
| Geodesy | SFMath | done | GeodesyTests |
| ISA atmosphere | SFAtmosphere | done | ISATests |
| Fixed-step clock | SFSim | done | ClockTests |
| Content store | SFContent | partial (no quota/LRU yet) | ContentStoreTests |
| Flight dynamics | SFFlightModel | done (P1.1) | FlightModelTests, ControlSenseTests |
| Sky render | SFRender | authored, unverified | — (macOS CI) |

## Quick Flight slice (P1.12)
- `SFQuickFlight` (pure Swift): `QuickFlightWorld` (SkyWorld airfield region, per-tier mesh budgets) and `QuickFlightSession` (FDM at a fixed 120 Hz on recipe terrain, instruments, input mapping, crash detection, chase camera). Headless tests fly it on Linux.
- `SFRender.WorldRenderer` (Metal): two-cascade sun shadow pass → physical sky pass (GPU Hillaire LUTs) → forward world pass (20-byte packed vertices, reversed-Z, aerial perspective from 3D tables built by `SFPreview.PhysicalSky`). Offscreen frames are tested in CI on the macOS runner's Metal device.
- `SFUI.QuickFlightView`: MTKView driver on the main actor; the environment mesh is built off the main thread, then uploaded.
