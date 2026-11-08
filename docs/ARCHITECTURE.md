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
