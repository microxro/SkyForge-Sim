# Round 5: atmosphere_night (integration notes)

All new files, no existing file edited. Apache-2.0, fully procedural (0 bytes of assets).

| File | Purpose |
|---|---|
| `Sources/SFRender/NightSky.swift` | `NightTier`, `Astro` (sun/moon ephemeris, phase, sidereal time, equatorial->ENU), `StarField` (deterministic catalogue, B-V tint, Milky Way density), `NightModel` (limiting magnitude, twilight grade, moonlight lux, van Rhijn airglow), `NightSkyState(unix:latDeg:lonDeg:)` |
| `Sources/SFRender/NightLights.swift` | `LightKind` (ICAO colours), `LightSprite` (flicker-free sizing, beam gain, strobe), `PAPI`, `AirportLighting`, `CityLights`, `ConeLight`, `AircraftLights`, `NightLight.packed()` |
| `Sources/SFRender/NightUniforms.swift` | `NightSkyUniforms` (16 x float4, mirrors `NTUniforms`), `NightConeUniform` (4 x float4, mirrors `NTCone`) |
| `Sources/SFRender/Shaders/NightShaders.swift` | MSL `NightShaders.source`: `nt_star_vertex/fragment`, `nt_sky_fragment`, `nt_light_vertex/fragment`, `nt_cone_light()` |
| `Tests/SFRenderTests/NightTests.swift` | 17 tests (ephemeris, stars, twilight, PAPI, colours, sprite continuity, runway/city layout, cone, struct layout) |

Check: `python3 tools/msl_check/check_msl.py NightShaders.swift` passes (shim only; not compiled on Metal).

## Frame flow

1. Once per frame (CPU): `let st = NightSkyState(unix: simUnix, latDeg:, lonDeg:)`. `st.sunElevationDeg` / `st.darkness` also give the LUT sky its twilight tuning inputs (`st.twilight.exposureBoost` for auto-exposure).
2. `var u = NightSkyUniforms(state: st, tier: tier, right:, up:, forward:, verticalFOV:, viewport:, time:)`; camera basis is in the local ENU frame (x east, y north, z up). If the world frame differs, rotate the basis, `sunENU`, `moonENU` and the three `eq*` rows into it first.
3. Build the pipeline library as `WorldShaders.source + NightShaders.source` (concatenate like the other shader strings; names are `nt_` prefixed, no collisions).
4. Star buffer once per tier: `StarField.pack(StarField.generate(tier: tier))` -> `MTLBuffer` of float4 pairs.
5. Passes, all after the Hillaire sky and before terrain/objects, depth test off, additive blend (`.one`, `.one`):
   - `nt_sky_fragment` with `nt_full_vertex`, 3 vertices (moon with phase and earthshine, Milky Way, airglow, twilight warm/belt-of-Venus tint). Buffer 0 = `u`.
   - Stars: `nt_star_vertex` (`drawPrimitives(.point, vertexCount: stars.count)`), buffer 0 = stars, buffer 1 = `u`; fragment `nt_star_fragment`.
6. Lights (after opaque geometry, depth test on / write off, additive): per-frame list of `NightLight`, positions made camera-relative on the CPU (subtract camera position in Double first, then Float) to avoid jitter; `packed()` -> `NTLight[]` buffer; `drawPrimitives(.triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)` with `nt_light_vertex`/`nt_light_fragment`, buffers 0 = lights, 1 = `u`. Cap n at `tier.maxLightSprites`.
7. Landing/taxi cones: `NightConeUniform(ConeLight.landing(position:forward:))` bound as `constant NTCone&` in the world fragment shader; add `nt_cone_light(cone, worldPos, normal)` to the lit colour (needs `#include`-ordering: put `NightShaders.source` before `WorldShaders.source`, or copy the 15-line function).

## Light content sources

- Airports: `AirportLighting.runway(centre:headingRad:length:width:)` + `.papi(...)` from `SFNavData` runway records (glide angle from the record, default 3.0). PAPI lamps are narrow (7.5 deg half beam) so they flip white/red with approach angle by geometry alone; `PAPI.whiteCount` is the oracle for tests/HUD.
- Cities: `CityLights.visibleCells(camera:tier:)` -> `CityLights.lights(cell:density:)`, with `density = CityLights.density(landUse:buildingCoverage:)` from SFQuickFlight land cover/OSM building coverage. Cells are independent and deterministic; cache by cell key and evict outside the visible set.
- Aircraft: `AircraftLights.navigation(...)` (strobes use the shared 2-flash pattern, driven by `u.view.w`).

## Design notes

- No flicker: sprites keep a minimum pixel footprint and lose energy by area below it (`LightSprite.metrics`, same maths in the vertex shader); distance fade is a smoothstep over the last 25% of range; beam gain is a smoothstep, never a hard cone; stars have no twinkle and a fixed minimum size. Strobes are the only time-varying lights and are deterministic in time.
- Stars fade by magnitude using `limitingMagnitude(sunElevation)` (civil -6 deg: mag 1.5, nautical -12: 4.5, astronomical -18: 6.5), lowered when a bright moon washes the sky.
- Moon: low-precision series (about 0.3 deg), phase from elongation; `moonlightLux` follows the full-moon 0.267 lux reference and phase law; moon surface maria only on high/ultra.
- Tier knobs: `NightTier.starCount`, `starLimitMagnitude`, `maxLightSprites`, `cityCellBudget`, `milkyWay`, `moonSurfaceDetail`, `minSpritePixels`.
- Bloom: the sprite glow and tail already provide per-light bloom; for screen-space bloom feed the HDR target to the existing bloom pass (`PostShaders`), the sprite intensities are authored in the same linear scene units (street lamp = 2.5).

## Caveats

Written without a Swift toolchain; CI is the first compile. Most likely friction: Swift 6 strict-concurrency warnings on static lets (all are value types, `Sendable`), and `point_size`/`point_coord` use in `nt_star_*` (standard MSL). Moon/halo and Milky Way gains in `nt_sky_fragment` are eyeballed constants (`0.006`, `0.0025`, `*40`) and expect tuning against the actual exposure curve.
