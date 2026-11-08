# Visual log

Every visual milestone: scene, screenshot path, metrics, art-director score (1–10: sharpness, lighting,
colour harmony, variety, depth, cleanliness), defects and fixes.

## Known differences: CPU preview vs intended GPU look
| Area | CPU preview (SFPreview) | Intended Metal look |
|---|---|---|
| Sky | gradient + sun glow | Hillaire 2020 LUTs, multiple scattering |
| Shadows | single shadow map, PCF | 3–4 stable cascades, PCSS, contact shadows |
| Clouds | none / flat | Schneider raymarched volumetrics |
| AA | 2×2 supersampling | MetalFX temporal + CAS |

## Milestones
- 2026-11-07 App icon (procedural, `sfpreview icon`): golden-hour sky, sun, three ridge layers with aerial perspective, banked aircraft silhouette. Reviewed by eye; acceptable for P0. Defect noted: silhouette is generic; revisit with the SF-1 Trainer planform in P1.

### 2026-11-07 P1.3 first CPU preview renders (seed 1, 1280x720, 2x2 SS)
Commands: `swift run -c release sfpreview --scene <name> --out ...` (15–28 s per image on 4 Linux cores).

| Scene | File | Time | Triangles | Sharp. | Light | Colour | Variety | Depth | Clean | Avg |
|---|---|---|---|---|---|---|---|---|---|---|
| (a) suburban, golden hour | docs/previews/a_suburban_golden.png | 19 s | 2.9 M | 6 | 7 | 6 | 6 | 6 | 6 | 6.2 |
| (d) forest and river, midday | docs/previews/d_forest_river.png | 21 s | 3.2 M | 6 | 6 | 6 | 6 | 6 | 5 | 5.8 |
| (e) coastline, golden hour | docs/previews/e_coastline.png | 22 s | 2.9 M | 5 | 6 | 6 | 5 | 6 | 5 | 5.5 |
| (f) mountain valley, midday | docs/previews/f_mountain_valley.png | 27 s | 3.0 M | 6 | 7 | 7 | 6 | 8 | 6 | 6.7 |

Average 6.1 (target ≥ 8): **not yet met**; P1.3 stays open for further passes.

Defects found and fixed in this pass (each by looking at the PNGs):
1. Trees far too dense, too large and rainbow-saturated; houses hidden → yard density 0.22 → 0.085, crowns smaller, restrained autumn palette.
2. Sky washed out and mauve → lower exposure, sparse cumulus, three-stop sky gradient for golden hour.
3. Suburbs beyond the instancing radius read as flat lawn → far-ring built-up mottling (roof/pavement/canopy at 25 m).
4. Blocky near-field squares from that mottling → mottling only on mid/far rings.
5. River rendered as a staircase of 8 m cells → smooth water ribbon + carved channel + soft bank colour.
6. Mustard/orange fields and orange distant forest → muted crop palette and canopy tint; alpine meadows in mountain valleys.
7. Faceted far mountains → 24 m mid ring to 8 km.
8. Crash: `riverDistance` invalid range outside the river extent (found by the far ring) → fixed, regression test added.
9. Mountain river 25 m underground (base term overrode carved floor) → carve from final surface; test `riverSurfaceAboveBed`.

Open defects (next passes): near-field ground is flat colour (needs detail texture/normal variation); conifer and broadleaf crowns are low-poly; building facades lack detail; coast cliffs show grey triangles; no aircraft in frame; water edges follow terrain triangles; field rows only in colour.

### 2026-11-07 P1.3 pass 2: aircraft in frame (scene a)
- Added the procedural SF-1 Trainer (lofted fuselage, NACA 0012 wing with dihedral, struts, tail, fixed gear) as a chase-view subject; two-sided shading so mesh winding can never darken faces.
- Scene (a) now matches the reference composition (low chase over suburbs at golden hour). Scores: sharpness 6, lighting 7, colour 6, variety 6, depth 7, cleanliness 7 → **6.5** (was 6.2).
- Open: prop disc not drawn (needs transparency); no aircraft shadow visible at 150 m AGL; horizon band still flat; no cockpit/HUD yet.

### 2026-11-07 Scene (j) airport final approach (sunrise)
- File: docs/previews/j_airport_final.png (20 s). New: runway geometry with simplified ICAO Annex 14 markings (threshold stripes, seven-segment designators, centre-line, aiming point, touchdown zone, edges), flattened airfield with 150 m embankment blend, chase aircraft on a 3° final, sunrise three-stop sky.
- Scores: sharpness 6, lighting 6, colour 6, variety 5, depth 6, cleanliness 6 → **5.8**.
- Defects: near trees are visibly low-poly at 37 m AGL; trees fill the approach corridor (real approaches are cleared); no approach/runway lights; no terminal/hangars yet.

### 2026-11-08 P1.9 instruments (k six-pack, l SF-1000 PFD)
- Files: docs/previews/k_six_pack.png (1500×1000), docs/previews/l_pfd_sf1000.png (1280×800). The panels show what the instruments read after 25 s of real FDM flight: a 20° bank climbing turn at 93 KIAS, 2,610 ft, +290 fpm, 4.0°/s turn (g·tanφ/V predicts 4.1°/s).
- Pass 1 defects fixed: ASI labels crowding the title, Kollsman window over the 3 numeral, VSI ".5"/"UP" collision and wide decimal points (narrow punctuation cells added), slashed zero on dials, visible sky banding on the PFD (14 → 64 bands), redline overspeed in RPM (propeller Cp fit retuned to 2,550 RPM).
- Scores: legibility 8, layout 8, colour 8, realism 7, cleanliness 8 → **7.8**.
- Open: altimeter hands can cover the Kollsman window (as on real dials); tape labels clip at tape edges (intended); no speed trend vector yet; no glass reflections on the PFD.

### 2026-11-08 P1.5a physically based sky (m_sky_noon, m_sky_golden, m_sky_sunset, m_sky_twilight)
- CPU Hillaire 2020 atmosphere: Rayleigh/Mie/ozone, 256×64 transmittance, 32² multiple scattering, 192×108 sky-view LUT, limb-darkened sun disc, Lambertian ground with aerial perspective; auto-exposure, ACES.
- Sun elevations 45°, 6°, 0.5°, −4°, looking toward the sun's azimuth, 300 m eye height.
- Observed: deep blue zenith and pale horizon at noon; golden aureole at 6°; red-orange horizon glow and reddened disc at 0.5°; purple-pink twilight with dark ground at −4° (the "purple light" of civil twilight). No banding.
- Scores: realism 8, colour 8, smoothness 9, depth 7 (ground is flat) → **8.0**.
- Next: use SkyModel for sky, sun colour, ambient and aerial perspective in the scene previews (P1.3 pass 3).

### 2026-11-08 P1.3 pass 3: physically based sky and aerial perspective in scene previews
- Clear-sky presets (sunrise, golden, midday, dusk) now take sky radiance, sun colour, sky ambient and aerial perspective from SFAtmosphere (Hillaire LUTs; 16×32×32 aerial table per render, turbidity 2.5–3.5). Overcast/storm/night keep their hand-tuned decks.
- Re-rendered a, d, e, f, j at 1280×720. Most visible gains: blue zenith-to-haze gradients instead of the grey-mauve band, depth haze that turns bluish with distance (f), a warm sun aureole (a, e).
- Scores (sharpness, lighting, colour, variety, depth, cleanliness): a 6/8/7/6/8/7 → **7.0** (was 6.5); f 7/8/8/7/9/7 → **7.7** (was 6.7); j 6/7/6/5/7/6 → **6.2** (was 5.8); d, e ≈ +0.5 each.
- Open: broadleaf palette reads too orange under low warm sun; ground is flat colour near field; snow slightly lilac; still below the 8.0 target for a, d, e, j.

### 2026-11-08 P1.3 pass 4: palette, approach clearing, aliasing, shadow bias
- Early-autumn canopy palette (greens dominant, muted ochres): low physical sun no longer turns forests orange.
- Approach/departure surfaces (60 m inner edge, 15 % splay, 1.8 km) are cleared of trees; scene (j) now shows a realistic cleared final instead of a forest up to the threshold (test `approachCorridorIsClearedOfTrees`).
- Removed the 4.8 m crop-row term, which aliased at vertex spacing into dark moiré bands (e, d); fields use a gentle per-parcel gradient.
- Slope-scaled shadow bias (tan θ, capped at 10 texels) removes acne at grazing sun. The remaining banding in (j) at sunrise is real micro-relief under a 6° sun (it vanishes at midday).
- Scores: a 7.2, d 7.0, e 7.0, f 7.7, j 6.8 → average **7.1** (was 6.1 at the start of the day).

### 2026-11-08 P1.3 pass 5: per-pixel ground detail
- New `Material.terrain`; the shader adds clump (1.5 m), patch (6 m) and dry/lush (40 m) albedo variation plus micro-relief normals, faded out by 1.4 km so it never aliases. Shade time 0.2 → 0.5 s at 1280×720×4.
- Near-field grass now reads as grass instead of flat paint (a, d, e, j).
- Scores: a 7.5, d 7.3, e 7.2, f 7.8, j 7.0 → average **7.4**.
- Open: river banks still step along the 8 m water grid (d); tree crowns are low-poly at close range (j); buildings lack facade detail (a).

### 2026-11-08 Metal frames reviewed from the CI log
- First look at the GPU Quick Flight frames (recovered from base64 in the job log). Shadows correct (aircraft shadow down-sun on the runway). Defect: the ported ground detail speckled heavily at 320×180 (unfiltered 2 m noise, ±1 amplitude, strong micro-normals); neighbour-difference metric 21.6.
- Fix: amplitudes halved to match the CPU noise range, micro-relief ×0.24, and each octave fades by its screen-space footprint (`fwidth`). New CI assertion: metric < 9.

### 2026-11-08 P1.13 real-world scene (r) Merritt Island, Florida — response to the user's MSFS 2024 comparison
- New `sfpreview real`: real Terrarium elevation, USGS orthoimagery (z16, ≈2 m) near, Sentinel-2 cloudless 2016 (≈20 m) to 40 km, imagery converted to albedo (exposure removed), 16 m smoothed water mask from colour, Fresnel water with wind-roughened reflection, ≈19,600 3D pines/oaks grown on forest pixels with canopy colour from the photo, physical sky, chase aircraft at 1,250 ft.
- Compared with the user's reference (MSFS 2024, same region type): ground now reads as a real place (lagoon, neighbourhoods, tree cover, roads, sports fields). Still behind: no photogrammetry buildings, aircraft is a low-poly model, clouds are a 2D layer, imagery softens within ~300 m.
- Scores: sharpness 7, lighting 8, colour 8, variety 9, depth 8, cleanliness 7 → **7.8**.

### 2026-11-08 P1.14 volumetric cumulus (n)
- CPU reference `VolumetricClouds` (coverage + height-tapered density, 3D erosion, dual-lobe HG, multiple-scattering term, energy-conserving integration) rendered over the physical sky with `sfpreview clouds`: ground view (n_clouds_ground), toward a 20° sun (n_clouds_backlit, silver linings and dark cores), above the layer at 3.2 km (n_clouds_above).
- Metal port runs at half resolution against scene depth with aerial perspective; CI checks the GPU march against the CPU reference (p95 transmittance error < 0.02, radiance < 3 %) and that clouds appear in the sky but never over nearby terrain.
- Replaces the "2D layer" gap noted in (r). Scores for the cloud previews: shape 8, lighting 8, integration 7 → **7.7**. Open: no cloud shadows on the ground yet; slight step banding at grazing angles in the 48–64 step march.

### 2026-11-08 Metal frames from CI run 42472262069 (clouds, roll, cockpit)
- metal_clouds: fair-weather cumulus over the SkyWorld runway, flat bases, lit tops, aerial fade toward the horizon; terrain untouched. **8.0**.
- metal_roll90: camera rolled 90°, sky and terrain both rotate (the sky pass previously used a mirrored ENU→sky mapping, now a proper rotation with roll).
- metal_cockpit (first try): panel, pillars and PFD correct, but the view was filled by the fuselage interior. Cause: aircraft normals pointed inward, so the back-face discard removed the outer skin. Fixed in caee43d with winding tests.
- metal_cockpit (after caee43d): runway ahead through the windscreen, pillars, glare shield, panel and live PFD. Reads as a cockpit; pillars are heavy and the panel is flat-shaded. **6.5**.
- Cloud shadows: the first CI frame showed no shadow because the test patch is under a clear gap (the CPU model agrees: 0 of 1,024 samples shaded). Over 20 km the model shades 15 % of the ground at coverage 0.42 and 61 % at 0.6. The shadow samples moved into the lower half of the slab and the test now looks at a patch the CPU model puts about one third in shadow.

### 2026-11-08 Airfield grass (j and Quick Flight)
- The Metal Quick Flight final and preview (j) showed the approach as brown autumn stubble. `SceneBuilder.airfield` now paints the runway strip (±150 m) and 500 m extensions as mown grass with 40 m mowing stripes (wider than any vertex step), blended out over 50 m.
- j: approach reads as an airfield instead of a ploughed field. Score j 7.0 → **7.4**; average a 7.5, d 7.3, e 7.2, f 7.8, j 7.4 → **7.4**.

### 2026-11-08 Independent art-director review (subagent, benchmark = current commercial sims at 9–10)
- Scores: a 4.67, d 4.50, e 4.33, f 5.17, j 3.50 → **4.43**; r (real imagery) 5.50; n (clouds) 5.17. My own earlier scores (7.4 average) were measured against our previous frames, not against the real bar; this review is the honest baseline.
- Common defects: aliasing on aircraft, river banks and runway; loud high-frequency ground mottle; checkerboard dither in clouds; hard draw-distance cut-offs for trees and towns; faceted coast cliffs; no shoreline foam or shallow water; snow covering rock in (f); no airport furniture in (j); autumn trees clash with summer grass.
- Fixes in this pass: FXAA on the Metal frame; tent-filtered cloud upsample; CPU previews at 3×3 supersampling; ground detail amplitudes calmed (0.16/0.12 → 0.07/0.08, micro-normals 0.9 → 0.3, fade 1.4 km → 0.7 km); cloud preview at 192 steps. Previews re-rendered.
- Scenes switched to a summer palette (autumn crowns clashed with summer grass); previews re-rendered.

### 2026-11-08 Art-director re-review (round 2)
- a 5.17, d 4.83, e 5.00, f 5.33, j 4.00 → **4.87** (was 4.43); n 5.67; r 5.50. Aliasing, cloud step artefacts and ground mottle confirmed fixed.
- Remaining top fixes: smooth land-cover/water masks (stair-stepped river and field borders), per-instance tree colour variety, shoreline (beach, foam, shallow gradient, smooth cliff), slope/altitude mountain material, impostors for distant trees and towns; then an airport kit for (j), cloud multiple scattering and sun bloom, house variety.
- Applied now: eight summer broadleaf and four conifer greens (crowns no longer one lime tone); rock from 24° and snow only below ~30° slope (peaks show grey rock faces); field parcels warped by low-frequency noise with soft hedgerow margins. Previews re-rendered.
- Coast: near-shore water grid coloured by depth (foam at the waterline, turquoise shallows, deep blue beyond 28 m); visible as a lighter near-shore band in (e). The cliff is still faceted.
- Airport kit (Quick Flight and j): parallel taxiway with stubs and centre lines, concrete apron, four hangars, approach light bars with a 300 m crossbar, PAPI; airport flatten zone widened to ±200 m so the kit sits on level, tree-free ground.

### 2026-11-08 Art-director re-review (round 3) and fixes
- a 5.17, d 5.00, e 5.17, f 5.33, j 4.50 → **5.03** (was 4.87). Airport kit made (j) read as an airport; tree variety helped (d).
- Root cause of the blocky land-cover borders and stepped shallows: every triangle carried one averaged colour. `TriangleSoup` now has optional per-vertex albedo, interpolated perspective-correctly by the CPU rasterizer and packed per vertex for Metal; terrain and shore water use it.
- Mountains: rock darker grey-brown with strata and lichen variation; snow holds up to ~35°. Grass detail calmed again (mid 0.05, dry tint 0.3).
