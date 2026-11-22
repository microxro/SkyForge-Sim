# Round 1: airport surface overhaul (final-approach target 8.2+)

Language: Metal Shading Language, because the renderer's shaders are MSL strings in Swift (`SFRender/Shaders`).
Data tool: Python (`tools/`), as for the other data fetchers. No C++ is involved.

## Files
- `Packages/SkyforgeKit/Sources/SFRender/Shaders/AirportSurfaceShaders.swift`: static MSL functions
  `airportClasses`, `airportSurface` (returns `AirportSurface`: albedo, metallic, roughness, normal tilt, cover,
  infield) and `airportInfield`. No entry points. Syntax-checked with clang against an MSL shim, not compiled by
  Metal (no Apple toolchain in the session).
- `tools/fetch_airport_surfaces.py`: writes `airport.sfa` (`SFA1`) and, with `--png`, the rasterised mask.

## What the material does
- Pavement fully replaces the photo (`cover` = 1); only the photo's 64 m mean tone picks concrete or asphalt.
- Aggregate: 5 mm and 2 cm grain via triplanar noise (`apTriNoise`), 35 cm patches, all LOD-faded by pixel footprint
  (`fp`), so nothing aliases at distance.
- Joints and cracks: concrete 5 m slabs with sealed 1.2 cm grooves and per-slab tone; asphalt transverse cracks every
  ~18 m, wandering; hairline micro-cracks from noise iso-lines. The same height function gives the normal tilt.
- Touchdown rubber (`apRubber`): stretched streaks in wheel-track bands (±3.2 m, ±6 m), peaks near 300 m and 450 m
  (plus a weak 150 m term), scaled by a `traffic` input.
- Oil and fuel on aprons: two-scale Voronoi blotches with organic edges, dark cores, roughness drops to 0.65.
- Output PBR: metallic 0.0 concrete / 0.05 asphalt, roughness clamped to 0.65-0.85, tilt on the fly.
- Infield (inside the boundary, off pavement): `airportInfield` mown turf instead of the photo.

## Mask (`texture2d<float> airportMask [[texture(9)]]`, rg8Unorm)
Covers the airport's own rectangle (bounding box of the SFA1 features + 60 m, square) at 1 m per texel (coarser only
above 4096 texels per side); `u.airportRect` = centre x, y, half extent (region m), 1 when bound. Row 0 is north.
- R: pavement coverage 0…1 with an antialiased edge (sampled bilinearly, `tbl`).
- G: class, sampled nearest (`apNearest`) so a runway beside a taxiway never blends into a third class:
  0 none, 0.10 infield (inside the boundary), 0.33 apron, 0.66 taxiway/other, 1.0 runway. Pavement classes are
  dilated one texel in G so the bilinear R edge always has a pavement class under it.
- `airportClasses(R, G)` turns that into weights (apron, taxiway, runway, infield); infield weight is `1 - R` inside the airport.
- Runway lines take their width from the primary runway (`runwayWidthMetres`) when parallel to it and within 25 m;
  otherwise from the OSM `width` tag when present, else 30 m (taxiway 15 m).
- Holes in apron/boundary polygons are not kept (the pack stores outer rings only).

## Integration (done in this tree)
- `SFQuickFlight/AirportPack.swift`: `SFA1` reader (`AirportPack.parse`, `Showcase.airportData(for:)`).
- `SFQuickFlight/AirportMask.swift`: `AirportSurfaces.rasterise` and `RealWorldRegion.airportMask()` (rg8 raster).
- `RealWorldRegion.airport` is loaded next to the roads; `RealWorldRenderData.airportMask` carries the raster.
- `WorldRenderer`: rg8Unorm texture bound at fragment texture 9 (`dummy2D` reads 0, so no mask means no change);
  `WorldUniforms.airportRect` appended (Swift and MSL structs both).
- `WorldShaders`: `\(AirportSurfaceShaders.source)` spliced above `world_fragment`; in the `m == 8` branch the airport pass
  runs right after `albedo = photoAlbedo(c)`: pavement albedo replaces the photo, infield turf replaces it off-pavement.
  In the existing runway block the photo-toned asphalt is replaced by the procedural albedo (`asphalt = mix(asphalt,
  albedo, apCover)`), so the painted markings now go on top of the new pavement and the old `albedo = mix(albedo,
  surface, rwCover)` no longer overwrites it. `rwCover` is raised to the airport cover so the later photo passes skip it.
- Normal tilt is applied beside `groundTilt`; PBR is consumed in the ground lighting: a GGX sun lobe with `apRough`
  and f0 0.04 (+ the 0.05 metallic on asphalt) plus a Fresnel sky/ground reflection, weighted by the pavement cover.
- `tools/msl_check/check_msl.py` now resolves `\(Enum.source)` interpolation, so the spliced shader is checked.

## Result of the tool run (KMRY, ±3 km, OSM only)
45 features: 35 taxiway lines, 4 runway lines, 5 apron polygons, 1 boundary polygon; 3.5 KB; 0 non-OSM records dropped.
The rasterised mask shows both runways, taxiway network, aprons and the airfield boundary.
