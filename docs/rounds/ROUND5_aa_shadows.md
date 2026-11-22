# Round 5: aa_shadows integration notes

New files (no existing file edited):
- `Packages/SkyforgeKit/Sources/SFRender/AAShadowMath.swift`: `AAShadowTier`, `TAAJitter`, `TAAMath`, `AAMat4`, `TAAReprojection`, `CascadeMath`.
- `Packages/SkyforgeKit/Sources/SFRender/Shaders/AAShadowShaders.swift`: `AAShadowShaders.source` (taa_resolve_fragment, smaa_lite_fragment, cascadedShadowVisibility).
- `Packages/SkyforgeKit/Tests/SFRenderTests/AAShadowMathTests.swift` (pure Swift, runs on Linux).

Library order (needs `PostVarying` and `shadowCmp`): `CloudShaders.common + WorldShaders.source + PostShaders.source + AAShadowShaders.source`. Checked with `check_msl.py PostShaders.swift AAShadowShaders.swift`.

## TAA (medium/high/ultra)
1. Per frame: `let j = TAAJitter.pixelJitter(frame: n, length: tier.jitterLength)`; `let o = TAAJitter.ndcOffset(pixelJitter: j, width: w, height: h)`; add `o.x`, `o.y` to the projection's column-2 x/y entries (`proj[2][0] += o.x; proj[2][1] += o.y`) for the scene pass only. Keep the shadow passes and the reprojection matrices jitter-free.
2. Render the scene into `sceneTarget` (current), keep a second same-format `historyTarget`; scene depth must be sampleable (`depth2d`, `.shaderRead`).
3. Resolve pass `taa_resolve_fragment` with `TAAParams{invViewProj, prevViewProj, p=(0.1, 1.25, firstFrame ? 1 : 0, 0)}` at buffer(0); textures 0 current, 1 history, 2 depth. Both matrices are camera-relative; build `prevViewProj` from the previous frame's rotation/projection with its translation re-expressed relative to the current camera origin (previous eye minus current eye, subtract it in world before view). Swap current/history after resolve; set `firstFrame` on resize, teleport, or cut.
4. Resolve output feeds bloom/tonemap/FXAA path. Disable FXAA when TAA is on. Depth convention: the closest-depth search takes max depth (forward-Z 0..1 maps nearer to smaller, so if the renderer uses forward Z change `d > dz` to `d < dz`; reversed-Z keep as is).

## Low tier
Replace `fxaa_fragment` with `smaa_lite_fragment` (one texture, same `post_vertex`) or keep FXAA; both are single-pass. No jitter.

## 4-cascade shadows (high/ultra; medium uses 3)
- `CascadeMath.splits(count: 4, near:, far:)` gives view-space far edges; per cascade take `sliceRadius` for a rotation-invariant sphere, centre it on the slice, build the orthographic light matrix with half extent = radius, and snap the light-space centre per axis with `CascadeMath.snap(absoluteWorldCoord, texel: texelSize)` (Double, absolute coordinates, as `ShadowCascades.matrix` already does; note `snap` floors, `rounded()` there is equivalent for stability).
- Pack `CascadeShadowParams{vp[4], splits, texel, depthRange, q}` with `q = (tier.blendFraction, tier.pcfTaps, tier.usesPCSS ? 1 : 0, tan(0.0093/2))`. Shadow map is a 4-layer `depth2d_array` of `tier.shadowMapSize`.
- Fragment: replace `shadowVisibility(...)` in WorldShaders with `cascadedShadowVisibility(cp, sm, rel, n, dist, ndl, in.position.xy)` (keep the hero cascade min() afterwards). Pixel position drives the noise rotation; TAA resolves it, so keep the same tap count when TAA is on (no extra blur needed).
- Old edit shape in `WorldShaders.shadowVisibility`: `int c = dist < u.cascadeSplits.x ? 1 : ...` is superseded by the 0-based cascade select above; cascades 0..3 map to layers 0..3, so move the hero cascade to a fifth layer or a separate texture.

## Tier table
| tier | AA | cascades | map | PCF taps | PCSS |
|---|---|---|---|---|---|
| low | SMAA-lite/FXAA | 2 | 1024 | 4 | no |
| medium | TAA x8 | 3 | 2048 | 9 | no |
| high | TAA x16 | 4 | 2048 | 16 | yes |
| ultra | TAA x16 | 4 | 4096 | 24 | yes |

Not verified by a compiler: no Swift toolchain here; MSL passed only the shim syntax check.
