# Round 5: aa_shadows integration notes

New files (no existing file edited):
- `Packages/SkyforgeKit/Sources/SFRender/AAShadowMath.swift`: `AAShadowTier`, `TAAJitter`, `TAAMath`, `AAMat4`, `TAAReprojection`, `CascadeMath`.
- `Packages/SkyforgeKit/Sources/SFRender/Shaders/AAShadowShaders.swift`: `AAShadowShaders.source` (taa_resolve_fragment, smaa_lite_fragment, cascadedShadowVisibility).
- `Packages/SkyforgeKit/Tests/SFRenderTests/AAShadowMathTests.swift` (pure Swift, runs on Linux).

Library order (needs `PostVarying` and `shadowCmp`): `CloudShaders.common + WorldShaders.source + PostShaders.source + AAShadowShaders.source`. Checked with `check_msl.py PostShaders.swift AAShadowShaders.swift`.

## TAA (medium/high/ultra)
1. Per frame: `let j = TAAJitter.pixelJitter(frame: n, length: tier.jitterLength)`; `let o = TAAJitter.ndcOffset(pixelJitter: j, width: w, height: h)`; add `o.x`, `o.y` to the projection's column-2 x/y entries (`proj[2][0] += o.x; proj[2][1] += o.y`) for the scene pass only. Keep the shadow passes and the reprojection matrices jitter-free.
2. Render the scene into `sceneTarget` (current), keep a second same-format `historyTarget`; scene depth must be sampleable (`depth2d`, `.shaderRead`).
3. Resolve pass `taa_resolve_fragment` with `TAAParams{invViewProj, prevViewProj, p=(0.1, 1.25, firstFrame ? 1 : 0, 0)}` at buffer(0); textures 0 current, 1 history, 2 depth. Both matrices are camera-relative; build `prevViewProj` from the previous frame's rotation/projection with its translation re-expressed relative to the current camera origin (previous eye minus current eye, subtract it in world before view). Swap current/history after resolve. Own validity with `TAAHistoryState.beginFrame(width:height:eye:cameraCut:tierChanged:)`: a non-nil result (firstFrame, resize, cameraCut, teleport > `teleportDistance`, tierChange) means set `p.z = 1` for that frame (shader returns the current frame, history is rewritten). Call `invalidate()` when history textures are recreated (device loss, depth-convention change).

**Limits: no motion vectors.** Reprojection uses depth plus camera matrices only, so it is exact for static geometry and wrong for anything that moves on its own (other aircraft, vehicles, water, animated foliage, rotors). Those pixels are handled only by YCoCg variance clipping and the clip-driven blend weight (up to 0.5 current), so expect mild ghosting or softening on fast movers. If it matters, render a velocity target for dynamic objects and use it in place of `puv` for those pixels.
4. Resolve output feeds bloom/tonemap/FXAA path. Disable FXAA when TAA is on. Depth convention: the closest-depth search takes max depth (forward-Z 0..1 maps nearer to smaller, so if the renderer uses forward Z change `d > dz` to `d < dz`; reversed-Z keep as is).

## Low tier
Replace `fxaa_fragment` with `smaa_lite_fragment` (one texture, same `post_vertex`) or keep FXAA; both are single-pass. No jitter.

## Cascaded shadows (runtime cascade count: low 2, medium 3, high/ultra 4)
- `CascadeMath.splits(count: 4, near:, far:)` gives view-space far edges; per cascade take `sliceRadius` for a rotation-invariant sphere, centre it on the slice, build the orthographic light matrix with half extent = radius, and snap the light-space centre per axis with `CascadeMath.snap(absoluteWorldCoord, texel: texelSize)` (Double, absolute coordinates, as `ShadowCascades.matrix` already does; note `snap` floors, `rounded()` there is equivalent for stability).
- Pack `CascadeShadowParams{vp[4], splits, texel, depthRange, q, fwd}` with `q = (tier.blendFraction, tier.pcfTaps, tier.usesPCSS ? 1 : 0, tan(0.0093/2))` and `fwd = (camera forward unit vector, Float(tier.cascadeCount))`. The arrays are always sized 4 but the shader only reads `count = clamp(fwd.w, 1, 4)` entries, so low/medium never index unset slots; fill unused `splits` with the far plane. Shadow map is a `tier.cascadeCount`-layer `depth2d_array` of `tier.shadowMapSize`, depth format `.depth16Unorm` on ultra (`tier.shadowDepthBytes`), `.depth32Float` otherwise. Cascades are selected by view-space depth (`dot(rel, fwd)`, `CascadeMath.viewDepth`), not radial distance.
- Fragment: replace `shadowVisibility(...)` in WorldShaders with `cascadedShadowVisibility(cp, sm, rel, n, ndl, in.position.xy)` (keep the hero cascade min() afterwards). Pixel position drives the noise rotation; TAA resolves it, so keep the same tap count when TAA is on (no extra blur needed).
- Old edit shape in `WorldShaders.shadowVisibility`: `int c = dist < u.cascadeSplits.x ? 1 : ...` is superseded by the 0-based cascade select above; cascades 0..3 map to layers 0..3, so move the hero cascade to a fifth layer or a separate texture.

## Tier table
| tier | AA | cascades | map | PCF taps | PCSS |
|---|---|---|---|---|---|
| low | SMAA-lite/FXAA | 2 | 1024 | 4 | no |
| medium | TAA x8 | 3 | 2048 | 9 | no |
| high | TAA x16 | 4 | 2048 | 16 | yes |
| ultra | TAA x16 | 4 | 4096 (depth16) | 24 | yes |

Shadow memory (cascades x size^2 x bytes): low 8 MiB, medium 48 MiB, high 64 MiB, ultra 128 MiB (4096^2 x 4 layers x 16-bit; 32-bit would be 256 MiB). Budget is 128 MiB, enforced by `shadowMemoryBytes` in tests. PCF/PCSS tap counts are clamped to at least 1 on CPU and in `casPCF` (0 taps previously gave 0/0 = NaN).

Not verified by a compiler: no Swift toolchain here; MSL passed only the shim syntax check.
