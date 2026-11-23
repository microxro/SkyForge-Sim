# Fly anywhere on Earth: state and milestone plan

Goal: the player can pick any airport, or any point on Earth, and fly there. Scenery streams ahead of the aircraft with no seams, pop-in or blank areas. Where data is missing, a procedural fallback fills in. Data stays free and open, with no licence changes. Building footprints stay OpenStreetMap-only (`docs/DECISIONS.md`).

## Current state (audited 2026-11-23, main 39c1661)

| Layer | What exists | Gap for "anywhere" |
|---|---|---|
| Start point | `RealWorldRegion` is built around one OurAirports airport (any airport in the bundled 49k-row snapshot). Showcase packs: KMRY, KASE, KBFI, LSZS, NZQN, KCOI. | No free lat/lon picker. Points with no airport have no region. |
| Region extent | Fixed squares around the airfield: near 3.0–3.2 km, mid 12 km, far 40 km (`RealWorldDetail`). | Flying past about 40 km leaves the data. Nothing re-centres the region as the aircraft moves. |
| Elevation | Terrarium tiles streamed (z14 near, z12 mid, z10 far) through `HeightMosaic` and `TerrainStreamer`. Bundled `global_dem.sfdem` at z4 (~10 km per sample) as the offline baseline. | Offline, anywhere beyond the showcase areas is only ~10 km terrain. CDLOD morphing on real DEM is still open (A5). |
| Imagery | USGS (US only, z≤16, sharp detail layer) and Sentinel-2 cloudless 2016 (worldwide, z≤14, 10 m). Imagery is streamed through `ImageryStreamer`. | Outside the US, the best detail is 10 m. Sharp detail is re-streamed only around the start view. |
| Water and land cover | Colour-derived water. ESA WorldCover (CC BY 4.0) bundled for showcase airports only. | No global land-cover fallback on demand. |
| Buildings and roads | OSM via Overture filter, bundled for six showcase airports only. Runtime Overpass client (`OSMService`) exists, but OSM is unreachable from the build environment (ADR-0016). Procedural houses fill gaps. | Most of the world has no buildings except procedural ones. |
| Fallback | Where a region cannot load, the app falls back to SkyWorld (procedural). | Not seamless. The aircraft changes world type. |

Known dormant pieces: `SFPerf/StreamingPlanner`, `ResidencyCache` and `QualityGovernor` have no callers, so none of them manage region streaming yet.

## Acceptance for "anywhere"

1. Any OurAirports airport and any lat/lon can be chosen as a start.
2. Flying 150 km from the start, in any direction, never shows an empty horizon or a world switch.
3. Terrain and imagery hand over between tiles with no visible seam at 1 km and 10 km.
4. Offline, the app still shows a complete world, at lower detail.
5. Each milestone ships as one PR with CI frames for review.

## Milestones

- **M0 (this PR): audit and plan.** Doc only. No code.
- **M1: region follow.** When the aircraft is within about 25 km of the region edge, build the next region centred ahead of it in the background, then hand over. Needs an agreed hand-off with the GPU perf thread (`WorldRenderer` owner). Tests: a scripted 150 km flight with no gap in height samples.
- **M2: global base layer.** Raise the bundled DEM from z4 to a tile set that covers the world at ~1 km, within the app size budget, or stream it on first launch. Keeps offline flight useful everywhere. Terrain LOD thread owns the CDLOD side.
- **M3: any-point start.** A lat/lon picker (map search by ICAO, city or coordinates). Points with no airport start at a nearby synthetic runway-free spot, with a visible note.
- **M4: procedural fallback instead of SkyWorld.** Use WorldCover land cover, streamed per tile, to drive trees, water and fields where imagery or OSM is missing. Replaces the world switch.
- **M5: stream soak.** A 30-minute scripted flight across region boundaries and at least two continents. Memory bounded, no NaN, no stalls.

## Coordination

- GPU perf thread: structural `WorldRenderer` edits (M1 hand-off).
- Terrain LOD thread: DEM resolution and CDLOD (M2).
- Scenery, ground textures, buildings, roads and rivers, and living-world threads: their own layers. Each hooks into the region, not the streamer.

## Data rules

- Keep to the sources in `docs/DATA_SOURCES.md`. Add any new host there first.
- No Bing, Apple, Google or Mapbox imagery. No OSM tile servers.
- Attribution shown in the app for every layer added.
