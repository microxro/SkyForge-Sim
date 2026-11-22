# Round 3: macro-colour decoupling and cloud-shadow mitigation (KBFI lawn mottle)

Status: code, tests and host wiring written (flag `macroColourDecoupling`, default off), **not compiled with Swift or Metal** (this
host has neither; MSL was syntax-checked against a C++ shim only, `clang++ -fsyntax-only`). First real check needs a Mac: `swift test --filter MacroColourTests`, then the KBFI final frame.

## Why the last three attempts failed

Rounds 61 to 62c each added another luminance or hue pull on the photo pixel (30 m mean, 400 m mean, ±5 %, ±35 %).
The pixel's own 40 to 120 m mottle is the input to every one of them, and the lawn replacement then re-imported it
(62b: `clamp(pL, mL * 0.65, mL * 1.35)`). Round 3 stops tone-mapping the pixel. For natural ground the pixel is
replaced by `hue(macro) × luminance(clamped macro) × procedural detail`; the photo's own pixel survives only as
a `photoKeep` = 15 % residual, and fully on pavement and roofs.

## What was added

| File | Content |
|---|---|
| `SFRender/Shaders/MacroColourShaders.swift` | MSL: `mc_macroHue`, `mc_softClamp`, `mc_cloudClamp`, `mc_classify`, `mc_detail` (0.125 to 8 m octaves, strata, verge, mowing), `mc_decoupleGround`, compute kernel `macro_colour_build` |
| `SFRender/MacroColourReference.swift` | CPU mirror of all of it (Foundation only) |
| `Tests/SFRenderTests/MacroColourTests.swift` | 8 swift-testing cases: clamp, median of four, grid median vs a cloud, hue, spread collapse, detail fade and bounds, pavement |
| `tools/macro_colour_check.py` | numpy port and sanity metric on a synthetic blotchy lawn |

Cloud shadows versus real shadows: everything above outputs **albedo**. Cascaded shadow maps, the cloud-shadow
term and AO are applied to it afterwards and are untouched, so a real cloud or tree shadow still darkens the
(now clean) albedo.

## Sanity metric (`python3 tools/macro_colour_check.py`, synthetic, seed 7)

| metric | photo | 128 m only | + 400 m hold |
|---|---|---|---|
| full-image luminance cv | 0.141 | 0.079 | 0.067 |
| 40 to 120 m band cv (the cloudy mottle) | 0.051 | 0.024 | 0.020 (ratio 0.40) |
| hue (R−B) spread at 40 m | 0.160 | 0.088 | 0.044 (ratio 0.28) |

Read this honestly: the spec's 128 m median alone leaves about 55 % of the mottle, because the median window is
the same size as the mottle (the median itself carries 40 % of the band). Hence the optional `wideAlb` argument
(the existing 400 m tap, `lm4`): the median and the hue go 70 % toward it, and the clamp tightens to [0.97, 1.04].
The pass line (≤ 0.40) is met with almost no margin, on synthetic data. This is a sanity check, not an art score.

## Integration (done; flag-gated, default OFF)

Everything below is already in the tree. Nothing existing was deleted: the old tone-map stack still runs, and the new
path overrides its result only when `WorldRenderer.macroColourDecoupling = true` (`u.quality.w`). With the flag off the
fragment output is unchanged (one uniform branch). That keeps rounds 1-62's art tuning and lets one frame be rendered
both ways.

1. **Library order.** `WorldRenderer.init`: `CloudShaders.common + MacroColourShaders.source + WorldShaders.source`. The macro
   source must precede `WorldShaders` because `world_fragment` calls `mc_decoupleGround`. `tools/msl_check/check_msl.py --before MacroColourShaders.swift`
   checks that order.
2. **Macro texture.** `MacroColourPass.build` (new `SFRender/MacroColourPass.swift`) runs `macro_colour_build` once after the near
   imagery is set in `WorldRenderer.load`. Output `rgba16Float`, `size = ceil(2 * half / 64)`, `cellMetres = 2 * half / size` (the
   grid spans the imagery square exactly, no stretch). Host struct `MacroColourBuildParams` mirrors the MSL `MCBuildParams` (32 bytes).
   Bound at fragment `texture(10)` (`texture(9)` is Round 1's airport mask). Fallback is a 1x1 rgba16Float with alpha 0
   (`MacroColourPass.zeroTexture`; the shared `dummy2D` has alpha 1 and cannot be used). The shader skips the pass when alpha is 0.
3. **Fragment.** In `world_fragment`'s `m == 8` branch: `albedoPhoto` is captured before the `ltW` stack, and a flagged block after the
   `groundMat` material block computes `mc_decoupleGround(albedoPhoto, ...)` and blends it in with weight `amount * (1 - forest)`
   (`albedo = mix(albedo, mcAlb, mcW)`, same for `groundTilt`). `ltMean` and `groundMat` are untouched, so the KASE field/crop passes
   (`ltMean >= 0` at the field block) and the later normal tilt still work. Forest pixels keep the old canopy path entirely.
4. **Review findings applied** (round 3 review, items 1-7):
   * `ltMean`/`groundMat` kept (finding 1); forest never takes the pass and steep ground never takes the 400 m pull (finding 2);
   * pavement and roofs clamp against the 30 m mean (`localL = luma(ltMean)`), not the 400 m mean, so car parks and aprons keep their
     tone (finding 3); the old test accepted a nearly erased patch, the new ones pin it to ±3 %;
   * texture index 10 and an alpha-0 fallback, `cellMetres = 2*half/size`, `mq.a > 0` guard, wide tap only when the weight is > 0 (4, 5);
   * the synthetic metric is documented as weak and the check now also reports pavement retention (6); the CPU reference matches the MSL (7).
5. **Debug view 3** still shows the old stack's `dbgPatch`/`dbgNatural`; point it at `mc_detail` when the flag becomes the default.

## How to turn it on and judge it

`renderer.macroColourDecoupling = true`, render the KBFI final (x 200-1100, y 500-720) both ways, then KMRY, KASE, LSZS and NZQN
(regression check against 7.79/8.0/7.5). Not a pass until the reviewer's verdict on round 62 is known: 62c already holds green ground
to the 400 m mean, so this pass may duplicate it; compare against 62c, not against the raw photo.

## Known gaps

* No parcel-boundary vector mask exists in the render data, so "parcel boundaries" are approximated with `roadNear` (verge) and `burb` (mowing, lawn).
  A parcel mask channel would need a third texture channel in `waterTex` (`WorldRenderer.swift:574`).
* Never run on a GPU: gate on a KBFI final frame (x 200–1100, y 500–720) and re-run the VISUAL_LOG metrics before sending to the reviewer.
* Thresholds (`0.94/1.12`, `0.97/1.04`, `photoKeep`, 70 % wide pull) are first guesses tuned on a synthetic image only.
