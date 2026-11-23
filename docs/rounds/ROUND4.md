# Round 4: cockpit PBR materials, canopy glass and contact shadows

Target: cockpit 7.25 → 8.0+. Everything here is **new files**; no existing file was edited. The integration
below is four small edits in `WorldRenderer.swift` and `WorldShaders.swift`.

Language: Metal Shading Language inside Swift string constants, like the rest of `SFRender/Shaders`
(the renderer is Swift 6 + Metal; there is no C++ or GLSL in the engine, so none was added).

## What was added

| File | Contents |
|---|---|
| `Packages/SkyforgeKit/Sources/SFRender/Shaders/CockpitMaterialShaders.swift` | Part 1: anisotropic GGX (Burley D, Heitz height-correlated Smith G), brushing-direction logic, brushed-metal shading, two-surface canopy glass with dust and scratches. Part 2: glue to `WorldUniforms`/`WorldVarying` (`ck_cockpitMetal`, `canopy_glass_fragment`). |
| `Packages/SkyforgeKit/Sources/SFRender/CockpitContactPass.swift` | `CockpitContactShaders` (MSL) and `CockpitContactPass` (Swift host): a full-screen multiply pass with a 16-step contact-shadow march toward the sun through the depth buffer and a 12-tap centimetre-scale AO. |
| `tools/cockpit_check/` | `run.sh`: syntax-checks the MSL with clang++ through a small shim and runs numeric checks (D normalisation, energy bound, groove orientation, glass sanity). |

### Why these choices (fitted to the real cockpit)

* **Which meshes are "metal".** `Cockpit.swift` marks gauge bezel rings, PFD bezel tubes, screws, the vent
  ring, knobs, rocker switches, the throttle and mixture levers, the yoke shafts and grips, pedals and
  seat rails with `Material.metal` (id 12). The cabin pass already routes id 12 to a single chrome lobe in
  `world_fragment`. `ck_cockpitMetal` replaces that branch **only when `u.quality.y > 0`** (the cabin pass), so
  the outside airframe's id-12 parts are unchanged.
* **No tangents in the vertex format.** The 20-byte `WorldVertex` carries none, so the brushing direction is
  derived in the fragment shader:
  * gauge bezel rings: circular (spun) brushing about the nearest gauge centre. Centres are mirrored from
    `Cockpit.swift` in `CK_GAUGES` (**keep in sync** if the gauge layout moves);
  * tubes (yoke shaft, levers, switch caps): the axis is the direction in the tangent plane along which the
    smooth normal does not change, from `dfdx/dfdy` of position and normal (`ck_axisFromCurvature`);
  * flat plates: body y axis.
* **Dark `.metal` parts** (black throttle knob, switch caps) are blended to the dielectric lobe by albedo
  (`metalness = smoothstep(0.08, 0.30, luminance)`), so they are not black mirrors.
* **Canopy glass.** In the cockpit view the main pass discards back faces, so the windscreen is open air.
  The glass pass draws the *inner* faces of the id-10 fuselage glazing (`fuselageSkin(...).glass`) with
  premultiplied blending. It models: inner-surface Fresnel mirroring the cabin (dark glare shield, light
  headliner); the outer surface's second reflection as a **ghost image shifted by 2 × the lateral plate
  shift** (this is where the thickness is visible: a parallel plate does not turn rays, so a far scene is
  not displaced); a dust film (haze, ~1.2 mm speckle, heavier low on the screen); hairline scratches in two
  cell scales plus wiper-arc micro-scratches; Henyey–Greenstein forward scattering (g 0.62 dust, 0.85
  scratches) with a 1/cos incidence factor so a low sun at a grazing angle, or a banking turn that swings
  the sun toward the line of sight, flares the screen.
* **Contact shadows.** The scene's SSAO uses a 2.5 m radius, so it cannot ground a switch on the panel. The new
  pass is only applied to pixels nearer than `cabinDepth` (1.8 m, smooth fade to 2.3 m), so the outside world
  is untouched. It multiplies the HDR scene, so it needs no read-write texture.

## Integration steps

### 1. Compile the new MSL into the world library
`WorldRenderer.swift`, `init`, the line
```swift
do { lib = try device.makeLibrary(source: CloudShaders.common + WorldShaders.source, options: nil) }
```
becomes
```swift
do { lib = try device.makeLibrary(source: CloudShaders.common + WorldShaders.source + CockpitMaterialShaders.source, options: nil) }
```
Part 2 must come after `WorldShaders.source` (it uses `WorldUniforms`, `WorldVarying`, `Skin`,
`fuselageSkin`, `shadowVisibility`, `skyEnv`, `pbrDielectric`).

### 2. Route cabin metal through the new shader (`WorldShaders.swift`)
a) In `world_fragment` (line ~1008; the string `float3 n = normalize(in.normal);` also occurs in a later fragment function near line 2052, so use the first one), immediately after it and **before** the first
`discard_fragment()` (derivatives need uniform control flow), add:
```metal
        float3 ckDpx = dfdx(in.rel), ckDpy = dfdy(in.rel);
        float3 ckN0 = normalize(in.normal);
        float3 ckDnx = dfdx(ckN0), ckDny = dfdy(ckN0);
```
b) In the `m == 10.0 || m == 11.0 || m == 12.0` branch, replace
```metal
            if (m == 12.0) {
                float F = 0.75 + 0.25 * pow(1.0 - nv, 5.0);
                col = albedo * (env * F + u.sunColour.rgb * ggxLobe(n, v, toSun, 0.28, 0.9) * vis) + albedo * ambient * 0.12;
            } else {
```
with
```metal
            if (m == 12.0 && u.quality.y > 0.0) {
                col = ck_cockpitMetal(u, in, n, dir, albedo, ambient, vis, cloudShade, toSun, localFp, ckDpx, ckDpy, ckDnx, ckDny);
            } else if (m == 12.0) {
                float F = 0.75 + 0.25 * pow(1.0 - nv, 5.0);
                col = albedo * (env * F + u.sunColour.rgb * ggxLobe(n, v, toSun, 0.28, 0.9) * vis) + albedo * ambient * 0.12;
            } else {
```
(`localFp`, `ambient`, `vis`, `cloudShade`, `dir`, `toSun` are all defined above that branch. The cabin pass overwrites `vis` to be nonzero only on the glare shield, so `ck_cockpitMetal` derives its sun from `toSun.z` and `cloudShade` instead.)

### 3. Canopy glass pipeline and draw (`WorldRenderer.swift`)
Properties:
```swift
private let canopyGlassPipeline: MTLRenderPipelineState
/// Dust film and scratch amount on the canopy, 0…1 (0 = a clean screen), and the glass thickness in metres.
public var canopyDust: Float = 0.35, canopyScratches: Float = 0.45, canopyThickness: Float = 0.005
public var canopyGlass = true
```
In `init`, directly after `propDepthState = pdss` and **before** the `do {` that builds `PostShaders` (so a missing function surfaces as `shaderCompile`, not as the `.pipeline` error that `do`/`catch` rewraps everything into):
```swift
guard let gv = lib.makeFunction(name: "world_vertex"), let gf = lib.makeFunction(name: "canopy_glass_fragment") else {
    throw RendererError.shaderCompile("missing canopy glass functions")
}
let gd = MTLRenderPipelineDescriptor()
gd.label = "CanopyGlass"
gd.vertexFunction = gv; gd.fragmentFunction = gf
let ga = gd.colorAttachments[0]!
ga.pixelFormat = .rgba16Float
ga.isBlendingEnabled = true
ga.sourceRGBBlendFactor = .one; ga.destinationRGBBlendFactor = .oneMinusSourceAlpha     // premultiplied
ga.sourceAlphaBlendFactor = .one; ga.destinationAlphaBlendFactor = .oneMinusSourceAlpha
gd.depthAttachmentPixelFormat = .depth32Float
do { canopyGlassPipeline = try device.makeRenderPipelineState(descriptor: gd) }
catch { throw RendererError.pipeline(String(describing: error)) }
```
The glass must be drawn **after the cloud composite**, otherwise cloud transmittance dims its reflection and
sun flare. At the very end of `encodeScene`, after the `if cloudsOn { ... }` block (the cloud pass reads `depth` and
does not write it), add a short encoder:
```swift
if cockpitView, canopyGlass, cockpit != nil, let a = aircraft, let p = aircraftPosition, let m = aircraftBodyToENU {
    let gpass = MTLRenderPassDescriptor()
    gpass.colorAttachments[0].texture = colour
    gpass.colorAttachments[0].loadAction = .load; gpass.colorAttachments[0].storeAction = .store
    gpass.depthAttachment.texture = depth
    gpass.depthAttachment.loadAction = .load; gpass.depthAttachment.storeAction = .store
    guard let ge = cmd.makeRenderCommandEncoder(descriptor: gpass) else { throw RendererError.commandQueue }
    ge.label = "CanopyGlass"
    ge.setRenderPipelineState(canopyGlassPipeline)
    ge.setDepthStencilState(propDepthState)             // reversed-Z test, no depth write
    ge.setCullMode(.none)
    ge.setFragmentTexture(sm, index: 2)                 // shadow cascades
    var u = uniforms(model: Self.modelMatrix(m, p - c.position))
    u.cameraPos.w = 0                                   // keep the inner faces
    u.quality.y = 1
    var gp = SIMD4<Float>(canopyDust, canopyScratches, canopyThickness, 0)
    ge.setVertexBuffer(a.buffer, offset: 0, index: 0)
    ge.setVertexBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
    ge.setFragmentBytes(&u, length: MemoryLayout<WorldUniforms>.stride, index: 1)
    ge.setFragmentBytes(&gp, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
    ge.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: a.count)
    ge.endEncoding()
}
```
Check on the Mac that `uniforms(model:)`, `sm` and `aircraft` are in scope at that point of `encodeScene` (they are
used earlier in the same function; `sm` is the shadow-map texture set at index 2 for the main pass). The depth
attachment is loaded, never cleared. The glass shader reads only `texture(2)`.

### 4. Contact-shadow pass (`WorldRenderer.swift`)
Property: `private var cockpitContact: CockpitContactPass?` and `public var cockpitContactShadows = true`.
In `encode(...)`, directly after
```swift
try encodeScene(cmd: cmd, colour: scene, depth: sceneDepth, camera: c, aircraftPosition: ..., aircraftBodyToENU: ...)
```
and before the `// Bloom chain` comment, add:
```swift
if cockpitView, cockpitContactShadows {
    if cockpitContact == nil { cockpitContact = try CockpitContactPass(device: device, colorFormat: .rgba16Float) }
    let fwdD = simd_normalize(c.target - c.position)
    let sun = simd_normalize(lighting.toSun)
    // Direct share of the cabin light: ~0.55 in clear midday sun, 0 with the sun down. `cloudShadeEstimate` is
    // 0…1 (e.g. `clouds.coverage` scaled to taste; 0 when the weather layer has none). Do not leave direct at
    // 0.55 under overcast, or the contact shadows stay hard when the sun is hidden.
    let direct: Float = 0.55 * min(1, max(0, sun.z * 3)) * (1 - cloudShadeEstimate)   // same window-sun term as ck_cockpitMetal
    try cockpitContact?.encode(cmd: cmd, scene: scene, depth: sceneDepth, near: Float(c.near),
                               fovY: Float(c.verticalFOVDeg) * .pi / 180, aspect: Float(sw) / Float(sh),
                               forward: SIMD3<Float>(Float(fwdD.x), Float(fwdD.y), Float(fwdD.z)),
                               up: SIMD3<Float>(Float(c.up.x), Float(c.up.y), Float(c.up.z)),
                               toSun: sun, directShare: direct)
}
```
Checked against the source: `lighting.toSun` is `SIMD3<Float>`; `c.near`, `c.verticalFOVDeg` are `Double`
(hence the `Float(...)` casts), `c.position/target/up` are `SIMD3<Double>`; `sw`/`sh` are `Int` locals of
`encode(...)`, equal to `scene`'s size and to `sceneDepth`'s (scaled depth is rebuilt on mismatch), so the
aspect and the depth read agree. `sceneDepth` has `.shaderRead` (made by `makeDepth`, `.renderTarget + .shaderRead`)
and is read in a separate pass with no depth attachment, exactly as SSAO does, so sampling `depth32Float` is legal.
Clouds are composited inside `encodeScene`, before this pass; they are far beyond `cabinDepth` and untouched.

## Verification done here (no Metal toolchain on this Linux box)

* `tools/cockpit_check/run.sh`: clang++ syntax check of the MSL against stubs that copy the real
  `WorldShaders` signatures, then numeric checks of the *same MSL source* compiled on the host:
  * ∫ D(h)(n·h) dω = 1 within 2e-5 for roughness 0.3–0.7 and anisotropy 0–0.95;
  * directional albedo with F = 1 stays below 1 (0.81–0.91) for three view angles and two tangent rotations;
  * grooves along t stretch the lobe along b; anisotropy 0 equals isotropic GGX;
  * glass: finite, non-negative, alpha ≈ 0.096 at normal incidence (two surfaces + 1.5 % absorption), dust
    flare 6× brighter looking into the sun than 64° off axis.
* The contact-shadow MSL passes the same syntax check (`contact.cpp` variant in the shim); it was not run.

**Not verified:** the Swift files and the Metal compiler itself (no Swift or Metal on this machine), and no
frame was rendered, so there is no visual score. Run the usual CI frames (`metal_cockpit` camera, KMRY and
KBFI) before judging.

## Tuning knobs (first things to move after the first frames)

| Knob | Where | Default |
|---|---|---|
| Bezel roughness / anisotropy | `ck_cockpitMetal`: `rough` 0.30 ± 0.10, `aniso` 0.80 rings, 0.65 other | |
| Brushing grain | `ck_brush` frequencies (2200 and 5200 per m across, 70 and 140 along) | fades at 0.6 mm footprint |
| Dust, scratches | `WorldRenderer.canopyDust/canopyScratches` | 0.35 / 0.45 |
| Dust flare strength | `dustLit`/`scrLit` constants in `ck_canopyGlass` (1.9, 3.2) | |
| Wiper pivot | `float2(0.0, -0.40)` in `ck_canopyGlass` (body y, z) | a guess; set from the real wiper geometry |
| Contact shadow | `CockpitContactPass.shadowReach/aoRadius/shadowStrength/aoStrength` | 0.16 m / 0.06 m / 0.85 / 0.9 |
| Cabin depth mask | `CockpitContactPass.cabinDepth` | 1.8 m |

### 5. Scene SSAO over the cabin
The scene SSAO (strength 0.7) also runs over the cabin and stacks with the contact pass. In `encode(...)`, change
`if ssaoStrength > 0 {` (the `// SSAO from the scene depth` block) so the strength it passes is
`cockpitView && cockpitContactShadows ? min(ssaoStrength, 0.35) : ssaoStrength`; the SSAO's 2.5 m radius still
grounds the cabin against the outside world while the new pass handles centimetre scale.

## Known limits

* `CK_GAUGES` duplicates gauge positions from `Cockpit.swift`; a per-vertex tangent in the vertex format
  would remove that, at the cost of a vertex-layout change.
* The curvature-derived tube axis needs the smooth per-vertex normals that `tube()` writes; a flat-shaded
  metal part falls back to brushing along body y.
* The ghost reflection assumes the reflected cabin is ~0.9 m away.
* The contact pass multiplies everything nearer than `cabinDepth`, including the emissive PFD screen and the
  glass pass's reflections, which it darkens slightly where AO/shadow fire; mask them out if that shows.
* The pass derives its normal from depth differences (not `dfdx/dfdy`, which would be undefined after the
  early return for far pixels).
* The contact pass assumes the sun term is a fixed share of cabin light (`directShare`); it darkens ambient and
  direct together rather than only the direct part.
* Glass refraction is lateral shift only (physically right for a flat plate). A distorted-windscreen
  look would need a scene copy and an angular offset, which is not included.
