# Worldwide scenery: tiles, land cover, roads and cities

Scope of this milestone (thread "Generate cities, roads and land cover worldwide"): the addressing and tooling that every
later world layer uses. The runtime streaming, the procedural fill and the OSM roads and cities hook in after it.
Follows `docs/WORLD_STREAMING_PLAN.md` (M4 uses these tiles). Data rules are in `docs/DATA_SOURCES.md`.

## Tile grid

- **Land cover tile:** ESA WorldCover 10 m 2021 v200, 3°×3° tiles named by south-west corner (`N36W123`). Coverage 60°S to 84°N.
- **Code:** `SFWorldGen/WorldCoverTiles.swift` (`WorldCoverTileKey`): `containing`, `covering` (bounding box, antimeridian wrap,
  sorted, unique), `name`, `objectKey`.
- **Tool:** `tools/worldcover_tiles.py` with `list` and `fetch`. `covering` uses the same rule as the Swift code; keep them in step.
- **Output:** one greyscale PNG per tile (`--size` px per side, default 2048, about 165 m per pixel), class codes unchanged,
  nearest-neighbour resampling. Ocean-only tiles are absent from the bucket and are skipped, not errors.

## Who owns what

| Layer | Source | Output | Status |
|---|---|---|---|
| Land cover, worldwide | ESA WorldCover (CC BY 4.0) | per-tile class PNG | tile grid and tool in this PR. Full fetch not run here (see below). |
| Settlements for the original world | procedural | in-app generation | owned by the "Build cities and airports for the original world" thread. It does not use this tile format. |
| Roads, rivers, cities (real world) | OSM via Overpass at runtime | cached per tile in the content store | not started. The build environment cannot reach OSM (ADR-0016). |
| Buildings (real world) | OSM only (`docs/DECISIONS.md`) | `SFB1` packs | existing pipeline, showcase airports only. |

## Limits of this milestone

- Swift code and tests are checked by CI only. There is no Swift toolchain in the authoring environment.
- The Python `fetch` mode is written but not run end to end. GDAL reads a full tile at native resolution, so a full fetch
  needs a worker with bandwidth and disk. The `list` mode was run and its tile names match the bucket convention.
- Roads and cities need OSM, which this environment cannot reach. They are the next milestone and must run where OSM is reachable.

## Next milestones

1. Run `worldcover_tiles.py fetch` for the showcase airports and check the PNGs against the existing `landcover.png`.
2. Runtime tile cache: a `WorldTileStreamer` that asks `covering` for the aircraft's tiles and loads them on demand.
3. OSM roads and cities per tile via Overpass, cached in the content store with ODbL attribution.
4. Procedural fill (M4 in `WORLD_STREAMING_PLAN.md`) for tiles where a layer is missing.
