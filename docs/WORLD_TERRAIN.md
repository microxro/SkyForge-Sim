# Original-world terrain (SFOriginalWorld)

Status: milestone 1. Terrain version `OriginalWorldInfo.terrainVersion = 1`.

## What it does
- `BaseField`: continent (coastline), warped ranges, plains and climate fields. Pure functions of world metres.
- `HydraulicErosion`: seeded particle erosion on a chunk window (1 km chunk, 16-cell halo).
- `Hydrology`: priority-flood lake filling, D8 routing, flow accumulation, sea, lake and river masks.
- `OriginalBiomeRules`: ordered biome rules from height, slope, moisture and temperature.
- `OriginalWorldGenerator.chunk(cx:cy:)`: deterministic chunk with a content hash and LOD decimation.

## Known limits (next milestones)
- Erosion uses each chunk's own window, so neighbouring chunks can disagree in a thin seam band.
  Fix: macro tiles with shared halos (milestone 2).
- No airport pad flattening here. The cities thread owns pad elevations.
- Not yet wired into rendering or streaming. CI is the only compile check until a Swift toolchain is available.
