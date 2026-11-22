# Round 5: aircraft exterior (integration notes)

New files (no existing file edited):
- `Sources/SFRender/AircraftExterior.swift` — CPU reference: `ExteriorTier`/`AircraftExteriorKnobs.make(tier)`, `AircraftExteriorLights` (FAA colours: red port, green starboard, white tail; white double-flash strobes 50/min; red beacon 60/min sweep), `AircraftSurfaceDetail` (rivets, exhaust stain, dirt, clearcoat Fresnel), `AircraftRain`, `PropellerBlur`, `HeatShimmer`, `ContrailModel`, `WingtipVortex`.
- `Sources/SFRender/Shaders/AircraftExteriorShaders.swift` — `AircraftExteriorShaders.source`, `ax_`-prefixed MSL (passes `check_msl.py`).
- `Tests/SFRenderTests/AircraftExteriorTests.swift`.

## Integration (WorldRenderer / WorldShaders owner)
1. Append `AircraftExteriorShaders.source` to the library sources, after `WorldShaders.source` (drop its `#include` like the others).
2. In `WorldShaders.swift` aircraft branch (`m == 6.0 || m == 5.0`), after `aircraftPanels` (about line 1939), add (paint only, `m == 6.0`, `dist < detail`):
```
// old
albedo *= 1.0 - 0.22 * aircraftPanels(in.local, localFp);
// new
albedo *= 1.0 - 0.22 * aircraftPanels(in.local, localFp);
albedo *= 1.0 - 0.55 * ax_dirt(in.local, ax.a.z, localFp);
float3 rv = ax_rivet(in.local.xy + in.local.zz * 0.37, localFp);   // use per-surface (u,v): fuselage (x,z/y), wing (x,y)
n = ax_tilt(n, rv.xy * 0.5); albedo *= 1.0 - 0.25 * rv.z;
```
3. Clearcoat: replace `rough = 0.24` paint output with `col = col * (1 - cc.w) + cc.xyz` where `float4 cc = ax_clearcoat(n, -dir, toSun, u.sunColour.rgb, vis)`; add `ax_orangePeel` tilt to `n` before.
4. Glass (`m == 5.0`): `float3 r = ax_rain(in.local.xy, cover, ang, len, t, layers)`; tilt `n` by `r.yz`, raise roughness and add `r.x` water sheen. Parameters from `AircraftRain.coverage/streakAngle/streakLength`.
5. `prop_fragment`: replace `alpha` with `ax_propOpacity(r, th, rpm, 2, 1.0/60.0, time)`.
6. Lights: build an `AXGlowIn` buffer each frame from `AircraftExteriorLights.sf1` (body pos → camera-relative via model matrix, colour × peak × `intensity(t)` × `visibilityFade`); draw 4 verts triangle strip, instanced, additive blend, no depth write (depth test on). Use `glowRadiusPixels` to size when converting to metres.
7. Heat shimmer: post-pass distortion sampling HDR scene at `uv + ax_heatShimmer(...)/res` inside a quad aft of the exhaust (exhaust at body (1.9, 0, 0.3)); high/ultra only.
8. Contrails/vortices: emit particles from engine/wingtips when `ContrailModel.formation > 0.3` or `WingtipVortex.visibility > 0.2`; opacity from `ContrailModel.opacity(age:persistence:)`.
9. Gate everything by `AircraftExteriorKnobs.make(tier)`.

Caveat: written without a Swift/Metal compiler; MSL passes only the shim syntax check.
