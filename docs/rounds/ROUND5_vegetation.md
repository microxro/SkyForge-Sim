# Round 5: vegetation integration notes

New files (nothing existing edited):
- `Sources/SFWorldGen/VegetationModels.swift`: tiers, `VegVertex`, five species (birch 5, cypress 6, willow 7, acacia 8, palm 9) grown from branch skeletons with leaf cards, `detail` 0 full / 1 card LOD, `VegetationLOD` weights + dither, `ImpostorLayout`, `WindSway`, `VegetationSeason`, `GroundCover`.
- `Sources/SFRender/Shaders/VegetationShaders.swift`: `common` (helpers + `veg_keep`) and `source` (`veg_vertex`, `shadow_veg_vertex`, `veg_billboard_vertex`, `grass_vertex`).
- `Tests/SFWorldGenTests/VegetationTests.swift`.
`msl_check`: `python3 tools/msl_check/check_msl.py VegetationShaders.swift:common VegetationShaders.swift` passes (the checker places `common` after World, which hides the ordering requirement below).

## Shader integration (WorldRenderer library build)
Concatenate `VegetationShaders.common` BEFORE `WorldShaders.source`, and `VegetationShaders.source` after it.

In `world_fragment`, directly after `float dist = length(in.rel);` add:
```
if (!veg_keep(in.style, in.position.xy, in.uv, in.local)) discard_fragment();
```
(Vegetation marks itself with `style.x = -1`; buildings use `style.x` as a non-negative seed and everything else writes 0, so the gate is a no-op for them. Verify no other pass writes a negative `style.x`.)

## Pipelines (WorldRenderer init, next to `treePipeline`)
```
vegPipeline       = try pso("veg_vertex", "world_fragment", label: "Veg", colour: true)
vegBoardPipeline  = try pso("veg_billboard_vertex", "world_fragment", label: "VegBoard", colour: true)
grassPipeline     = try pso("grass_vertex", "world_fragment", label: "Grass", colour: true)
shadowVegPipeline = try pso("shadow_veg_vertex", nil, label: "ShadowVeg", colour: false)
```

## Draw calls (per species, per frame)
- Buffers: 0 = packed `VegVertex.gpuVertices(mesh)` (typed `VegVertexGPU`, 11 Floats, stride 44 = `VegVertex.gpuStride`; never upload `[VegVertex]` raw, its SIMD3 fields give a 48 B+ stride; `gpuBuffer` returns the same bytes as `[Float]`; covered by `gpuLayoutMatchesMSL`; the old `TerrainVertex` tree buffers are unchanged for species 0-4), 1 = `WorldUniforms`, 2 = existing `TreeInstanceGPU` buffer (same instances as the species' trees), 3 = `VegUniforms` (struct in the MSL; set per draw).
- Per species draw THREE times with the same instance buffer: full mesh `species=s, representation 0`, card mesh `rep 1`, billboard (6 vertices x instances, buffer 0 unused) `rep 2`. The vertex shader collapses instances whose slice at their distance is empty, so no CPU distance sorting is needed; add CPU culling beyond `tier.farCull`.
- Grass: `GroundCover.scatter` per 4 m cell inside `tier.grassRadius` around the camera, fill `GrassInstanceGPU {x, y, z (sample terrain height), height, yaw, tone}`, draw `GroundCover.bladeMesh()` (15 verts) instanced. Skip cells where `exclude` says road/building/water/non-grass land cover. Tier low: no grass.
- Shadow pass: `shadow_veg_vertex` with the same buffers (0, 2, 3) for rep 0 and 1 only.

## VegUniforms values
- `wind`: (dir.x, dir.y, speed m/s, gustiness) from the weather state. `timeFade`: (time s, `tier.cardStart`, `tier.billboardStart`, `tier.fadeWidth`).
- `season`: from `VegetationSeason.state(dayOfYear:latitude:)`: (autumn, leafDrop, spring, sway enabled = `tier.swayEnabled`).
- `species`: (index, `SpeciesKind.stiffness`, `deciduous` 0/1, representation). Species 0-4 may use `veg_vertex` too only after conversion to `VegVertex`; leave them on `tree_vertex` for now (`TreeModels` is untouched).
- `board`: (half width, half height, crown centre y, crown radius y), e.g. `ImpostorLayout.quadHalfSize(species:)` with centre ~0.62 and radius ~0.36 (birch 0.66/0.34, willow 0.58/0.40, acacia 0.80/0.16).
- `grass`: (rgb ~ (0.12, 0.2, 0.05), radius m); `grassParams`: (0.55, dryness from `VegetationSeason`, width scale 0.12, 0).
- Instance colour `TreeInstanceGPU.colour`: use `SpeciesKind.leafColour`; mean leaf albedo must stay >= 0.05 like existing tints.
- Species pick: `VegetationModels.species(x:y:climate:)` for new variants; optionally route 25 % of trees there.

## Design notes
- LOD hand-over is a per-pixel interleaved-gradient dither with complementary thresholds (exactly one representation draws each pixel), so no blending/sorting and it works in the opaque pass. TAA (if present) smooths it.
- The billboard is procedural (crown ellipse with noisy rim + trunk, spherical shading normal), so no atlas bake is needed; `ImpostorLayout` (views, bake axes) is provided for a later baked-atlas upgrade.
- Wind: `veg_sway` mirrors `WindSway.offset` (slow trunk bend ~ height^2 with gust phase per tree, fast per-vertex flutter on leaf weight); wind direction is world XY (not rotated by tree yaw; the vertex shader applies it after `treeShape`).
- Leaf drop discards whole cards by a per-card hash vs `leafDrop`; bare winter billboards darken.
- Budgets: full meshes <= ~24k verts (tier ultra), card LOD about half. Repo growth: ~30 KB.
- No Swift toolchain was available: Swift files are uncompiled; CI is the first compile. Watch for type-inference slowness on the `b.out += [...]` array literals in `build`.
