# Round 5: water

New files only:
- `Sources/SFRender/Shaders/OceanShaders.swift` (`OceanShaders.source`, MSL, all functions prefixed `ow`, no entry points; passes `check_msl.py`)
- `Sources/SFRender/Ocean/OceanWaves.swift` (CPU twin: `OceanParams`, `OceanWake`, `OceanTier`, `OceanWaves`)
- `Tests/SFRenderTests/OceanWaveTests.swift`

Features: 8-octave Gerstner (analytic slope, crest/pinch measure, footprint fade), capillary ripple normals, Schlick Fresnel,
Beer-Lambert depth colour, crest subsurface scattering, Beckmann sun glitter driven by slope variance, whitecaps, shoreline
swash foam, Kelvin-style wake foam with ripple slope for up to 8 sources.

## Integration

1. Library order in WorldRenderer: add `OceanShaders.source` after `WorldShaders.source` (strip the duplicate `#include`/`using` is harmless).
   Old: `let src = WorldShaders.source`  (find where the library source is concatenated)
   New: `let src = WorldShaders.source + "\n" + OceanShaders.source`
2. Uniforms: `OWParams` (32 B) at a new fragment buffer index, and an `OWWake[8]` array (32 B each) at the next one.
   `var o = OceanParams(); o.time = t; o.windSpeed = weather.wind; o.tier = tier`;
   `setFragmentBytes(o.packed(wakeCount: n), length: OceanParams.byteSize, index: K)`; wakes: concatenate `OceanWake.packed`.
   Always bind the wake buffer (a 256-byte zero buffer when none).
3. Fragment: add `constant OWParams& ow [[buffer(K)]], constant OWWake* wakes [[buffer(K+1)]]` to the world fragment function.
   In the `m == 1.0` branch replace the hand-built wave/Fresnel block after `float3 wn = ...`:
   ```
   float3 nW = owWaveNormal(fieldW, ow, fieldFp, h_, c_, sv_);   // h_,c_,sv_ are local floats
   float3 rr = reflect(dir, nW); rr.z = abs(rr.z);
   OWOut o = owShade(fieldW, dir, toSun, ow, wakes, fieldFp, depthM, shoreDistM, float3(0.35,0.30,0.22),
                     skyEnv(u, rr), u.sunColour.rgb, ambient, vis);
   col = o.colour;
   ```
   `depthM`: 200 for open ocean; for imagery lakes `mix(0.3, 12.0, smoothstep(0.6, 1.0, shoreWm))`.
   `shoreDistM`: `(1 - smoothstep(0.6, 0.97, shoreWm)) * 6.0` for lakes, 1e3 for ocean. Keep existing `imageryWater` tweaks if desired.
4. Aircraft on water: each frame build `OceanWake.aircraft(position: aircraft.xy, heading:, speed: groundSpeed, wingspan:)` when the gear is in water; keep a short ring of recent positions (with decaying `ageFade`) for a longer trail.
5. Tier: `OceanParams.tier` = quality tier (low skips ripples on the host side by ignoring them is not needed; octaves/maxWakes already scale).

## Caveats
- Shader checked with the syntax shim only; Metal compile happens in CI. Wave time is `Float` seconds: wrap to a ~1e4 s period on the host.
- The surface mesh is flat; Gerstner is applied as a normal map only (no vertex displacement), which keeps horizon water cheap.
