# Round 2: Overture conflation, batched building culling, suburban parcels

Stack note: the renderer is Swift 6 with Metal Shading Language embedded as Swift strings, so everything here is
Swift, MSL or Python. Nothing is C++. None of the Swift or MSL has been compiled or run (no Swift toolchain in the
authoring environment): the MSL was syntax-checked with `clang++ -fsyntax-only` against a small shim (not a Metal compile). The Python tools
passed `tools/test_overture_tools.py` offline (no pyarrow, no network in the review environment); the original author ran
`fetch_buildings.py` against the real bucket (release 2026-10-21.0), but the refactored tools and `fetch_landuse.py` have not been re-run against it.

## What is here

| File | What it does |
|---|---|
| `tools/overture_common.py` | Range-read Parquet client, footer index cache, WKB polygons, region box; shared by the fetchers. |
| `tools/fetch_buildings.py` (edited) | Same `SFB1` output. New `--sources` allow-list (default `OpenStreetMap`), height/levels/roof inference, `--no-infer`. |
| `tools/fetch_landuse.py` | Overture `base/land_use` polygons to `SFL1` (`landuse.sfl`). `--list-classes` prints what a region holds. |
| `SFQuickFlight/LandUsePack.swift` | `SFL1` reader (`LandUsePolygon`, `LandUseCategory`), `Showcase.landUseData(for:)`. |
| `SFQuickFlight/SuburbMask.swift` | Rasterises residential land use and frontage roads to an RGBA8 road-frame mask (layout in the file header). |
| `SFRender/BuildingBatching.swift` | Cell merging into draw batches, frustum planes, CPU reference of the cull test, GPU struct layouts. |
| `SFRender/BuildingCuller.swift` | Metal host: Hi-Z pyramid, cull dispatch, indirect draws, per-frame stats. |
| `SFRender/Shaders/BuildingCullShaders.swift` | `building_cull`, `hiz_copy`, `hiz_downsample` kernels. |
| `SFRender/Shaders/SuburbShaders.swift` | `suburbParcels(...)`: kerb, planting strip, sidewalk with joints, driveways, per-lot lawns. |
| Tests | `SFQuickFlightTests/LandUseSuburbTests.swift`, `SFRenderTests/BuildingBatchingTests.swift`, `BuildingCullRenderTests.swift` (Metal). |

## Source policy (decision needed)

`docs/DECISIONS.md` says no ML-derived footprints ship, and `DATA_SOURCES.md` documents an OSM-only filter. That is
still the default. Measured on KBFI (4 km box): 9,153 OSM buildings kept, 3,363 Esri Community Maps and 105 Microsoft ML
records dropped, so the density gap you see at KBFI is mostly Esri-sourced records. Getting it back means
`--sources OpenStreetMap,"Esri Community Maps"` (or `any`), which needs a decision about licence and attribution first
(Esri Community Maps is CC-BY-4.0 in Overture, Microsoft ML Buildings is ODbL, Google Open Buildings is CC-BY/ODbL; check
the release notes), updates to `DATA_SOURCES.md`, `THIRD_PARTY_NOTICES.md` and `BuildingPack.attribution`, and the
reversal of the DECISIONS.md line. The tool prints a warning whenever the list is not OSM-only.

## Height and roof inference

Runs in Python at pack time, so `BuildingPack` is unchanged. Flags byte of `SFB1`: bit0 height present in the source data, bit1 has parts,
bit2 height inferred, bit3 roof inferred. Inferred heights leave bit0 clear, so `BuildingPack.estimatedHeight` stays in charge on the Swift side; `fetch_buildings.py` writes the inferred height and bit2 for diagnostics. Height: storeys × 3.2 + 1 when known, else by
class and footprint area with a deterministic jitter from the first vertex (houses 5-8 m, apartments 3-5 storeys,
sheds 3 m, industrial 7-12 m). Roof: flat for anything over 650 m² or a flat-roof class over 90 m², otherwise gabled
when the minimum-area bounding box aspect is at least 1.35, hipped below that. `BuildingMeshBuilder` only pitches
`gabled`, `hipped` and `pyramidal` roofs on house-style buildings under 700 m² with 16 or fewer vertices, which matches.
On the KBFI 4 km box: 1,034 heights and 9,122 roofs inferred (gabled 4,800, hipped 3,575, flat 776).

## Instanced, batched geometry: what this is and is not

The existing mesh bakes facade UVs and style bytes per building, so geometric instancing of repeated templates does not
apply. What is delivered is the draw-call half: neighbouring 500 m cells with contiguous index ranges merge into batches
(`maxIndices` 36,000, `maxSpan` 1,200 m), the kernel culls each batch and writes one `MTLDrawIndexedPrimitivesIndirectArguments`
(`instanceCount` 0 = culled), and `encodeDraws` issues one indirect draw per batch. The CPU does no per-cell culling.
Occlusion uses last frame's depth, so a newly revealed batch can appear one frame late; `depthBias` and the
"camera inside the box" exemption keep that rare. If measured, it is worth turning the loop into an indirect command buffer.

## Integration steps (the integrator owns WorldRenderer.swift)

1. **Packs.** Re-run `fetch_buildings.py` per airport (output stays `SFB1`), run `fetch_landuse.py` into
   `Showcase/<ident>/landuse.sfl`, add the attribution line from `LandUsePack.attribution`. Resources are `.copy`, so no manifest change.
2. **Culler.** Conventions: `mvp` maps mesh-local metres to Metal clip space (z in [0, w]); for a camera-relative renderer `mvp = viewProj * translation(-cameraPosition)`, `cameraLocal` is the camera position in mesh-local metres, and `hizMvp` is built the same way from the previous frame's camera and view-projection. Reversed-Z and infinite far work because frustum planes come from the clip rows (see `BuildingBatchingTests`). In `WorldRenderer.setBuildings`, also call `culler.setCells(mesh.cells)`. In the main pass, where cells are
   drawn today, replace the CPU cell loop with `culler.encodeDraws(enc, indexBuffer: ib)`. Before the pass call
   `culler.encodeCull(cmd:, mvp: viewProj * model, hizMvp: previousFrameMvp, cameraLocal:)`; after it (depth must be resolved,
   `.depth32Float`, reversed-Z) call `culler.encodeHiZ(cmd:, depth:)` and keep this frame's `mvp` for next frame. Pass `hizMvp: nil` on the first
   frame and after a camera cut. Shadow cascades keep their CPU `boxVisible` loop (their frusta differ).
3. **Suburb mask.** After roads and land use load: `SuburbMask.build(size: 2048, centre:, halfExtent:, landUse:, roads:)` over the near
   imagery extent, upload as an `.rgba8Unorm` texture, bind at fragment texture index 9 and read it with a `filter::nearest` sampler for the G (angle) and A (class) channels, which must not be interpolated (`suburbParcels(mask, maskN, ...)` takes the bilinear sample for R/B and a nearest `read` for G/A) (and a 1×1 zero texture when absent;
   the existing bindings end at index 8).
4. **Shader.** `SuburbShaders.source` has no dependencies on `WorldShaders`; concatenate it into the library source anywhere before
   `world_fragment` (for example `CloudShaders.common + SuburbShaders.source + WorldShaders.source`, which needs `WorldShaders.source`'s own `#include` line moved up or tolerated, as MSL allows repeated includes). In `world_fragment`, inside the
   `m == 8.0` branch after `ltMean`/lawn colour are known and `dist < 2000`, add the three lines from the header of `SuburbShaders.swift`. Replace
   `albedo` and `roughness` by weight, skip the grass detail for pixels with `paved > 0.5`.
5. **Verify on a Mac.** Run `swift test --filter BuildingBatchingTests`, `LandUseSuburbTests`, `BuildingCullRenderTests`; compare
   `lastStats` and GPU frame time on KBFI ultra (131,548 buildings). Art-check KMRY and KBFI finals with debug view 1.

## Known limits

- Parcels are a road-frame model: lots run along the nearest frontage road within 60 m; back yards beyond ~38 m revert to the lot lawn tone. Cul-de-sacs and corner lots get plausible, not surveyed, layouts.
- Holes in land-use polygons are dropped; `SuburbMask` treats polygons as solid and lets parks, schools, commercial and industrial punch residential out.
- No `aeroway` airport features were found in `base/land_use` near KBFI; airport aprons and taxiways live in `base/infrastructure` and are Round 1's concern.
- The shim check proves syntax, not Metal-specific semantics (address spaces, `read` on depth textures with `access::read`).

## Integration status (wired, both paths off by default)

- `WorldRenderer.suburbParcels` (default `false`): binds the suburb mask at fragment texture 11 (a zero texture otherwise, so
  the shader's red-channel test skips it). `world_fragment` blends `suburbParcels` into the albedo after the round-3 block, within 2 km,
  off airports, water, canopy and clearings. Roughness and normal output of `SuburbSurface` are not consumed yet.
  Needs `landuse.sfl` beside `roads.sfr` (`tools/fetch_landuse.py`); no showcase pack carries one yet, so `RealWorldRegion.suburbMask()` is nil.
- `WorldRenderer.gpuBuildingCulling` (default `false`): `BuildingCuller` runs before the main pass with
  `mvp = viewProj * translation(-camera)` and last frame's Hi-Z; the building draw becomes one indirect draw per batch, and
  `encodeHiZ` runs after the pass. The CPU cell loop remains the fallback, and shadow cascades always use it.
  Call `resetBuildingCullHistory()` after a camera cut. `lastDrawnBuildingCells` counts submitted batches on this path.
- Region glue: `RealWorldRegion.landUse` and `suburbMask(size:)` (`SFQuickFlight/RegionSuburbMask.swift`), `RealWorldRenderData.suburbMask`.

## Tool hardening (PR #17 security review)

- `tools/overture_common.py` is the one place for the S3 client, WKB parsing and output writing; `fetch_airport_surfaces.py` no longer carries its own copies.
- A failed listing, an S3 error document, an empty listing or a repeated continuation token raises `FetchError`; range reads accept only a 206 of the exact length and do not retry 4xx answers.
- Every `fetch_*.py` refuses to overwrite an existing output with a zero-record result (message on stderr, exit status 2). Pass `--allow-empty` when an empty pack is really intended.
- `--half-km` must be in (0, 200] km; a box that crosses the antimeridian or a pole, or a latitude beyond 85 degrees, is rejected. `fetch_airport_surfaces.py --png-size` is limited to 64-8192.
- WKB parsing raises `ValueError` only (no `struct.error`, `IndexError` or deep recursion); EWKB and ISO Z/M geometries are read in 2D. Rows with an unusable geometry, bbox or coordinates are counted in the summary line, not fatal. Edges longer than an i16 of decimetres are subdivided, never dropped.
- Index caches are written atomically, reused only when the recorded size matches the listing, and rebuilt when corrupt.
- `python3 tools/test_overture_tools.py` covers all of this offline, including a seeded WKB mutation fuzz loop.
