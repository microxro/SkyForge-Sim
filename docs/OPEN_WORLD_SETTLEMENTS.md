# Original-world settlements and airports

Status: P-OW1. `SFWorldGen` gains a deterministic planner for cities, towns, villages, streets, building
lots, landmarks and airports. It is pure Swift with no Apple frameworks, so Linux tests cover it.

## Inputs
- `OpenWorldTerrain`: `height(x, y)` in metres and `isWater(x, y)`, local ENU, origin at the world centre.
  The terrain thread's `OriginalWorldGenerator.baseHeight` is the intended sampler.
- `OpenWorldPlanner(seed:terrain:extent:cellSize:)`.
- Fixed anchors: `HaldenReachAnchors` copies `docs/worlds/halden-reach/world.json`. Anchored cities and
  airports keep their positions. Procedural sites within 2.5 km of an anchored city are dropped.

## Outputs
- `OpenWorldPlan.settlements`: streets (`Road`), `LotPlan` footprints, `Landmark`s, name, content hash.
- `OpenWorldPlan.airports`: `AirportLayout` with runways (`RunwaySpec`), taxiway, apron and
  `AirportBuilding` footprints, a water lane for seaplane bases, and `padElevation`.
  The terrain recipe must flatten each airport footprint to `padElevation`.

## Rules
- Deterministic: same seed, terrain and extent give the same content hash.
- Nothing is built on water. Lots keep clear of roads and of each other.
- Anchored airports take their elevation from the data, not from the terrain.

## Not yet
- Mission and career hooks (follow-up PR).
- Terrain flattening of pads (terrain thread).
- Rendering colours (renderer picks from the region palette).
