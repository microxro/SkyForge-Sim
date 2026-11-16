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

### 2026-11-08 Art-director re-review (round 4) and fixes
- a 5.17, d 5.00, e 5.50, f 5.33, j 4.50 → **5.10** (was 5.03). Coast clearly better (beach, foam fringe, smooth shallows); even rock strata read as contour lines.
- Fixes: strata warped by noise with uneven spacing and half the contrast; CPU micro-relief normals 0.3 → 0.12 (matches Metal; low sun had turned them into blotches) and grass albedo detail calmer.
- Open from the review: per-pixel land-cover evaluation (field borders still step at vertex spacing), river rebuilt like the coast, house variants, impostors beyond draw distance.
- Houses: 30 % take colours from other regional schemes, headings jitter ±4°, 35 % get a lower side wing or garage (L-shaped plans); (a) no longer reads as clones.
- Tree density now thins smoothly over the outer quarter of the object radius (Quick Flight and previews) instead of stopping at a ring.
- River bank widened to 26 m with wet mud at the waterline: the vertex-spacing sawtooth remains in shape but no longer reads as dark water against bright grass. A true fix needs per-pixel water edges or a finer mesh along the river.

### 2026-11-08 Art-director re-review (round 5) and fixes
- a 5.50, d 5.00, e 5.50, f 5.50, j 4.50 → **5.20** (was 5.10). House variety and organic strata worked; (j) showed evenly spaced wavy bands over the foreground.
- Diagnosis by elimination: the bands survived removing micro-relief and halving terrain fine noise, and vanished with a larger shadow bias, so they were shadow acne at a 6° sun. CPU bias now texel·(1.2 + min(24, 1.6·tanθ)); Metal texel·(0.8 + min(16, 1.4·tanθ)). Mowing stripes are a smooth low-contrast sinusoid (the 40 m square wave aliased on the vertex grid); terrain fine noise gentler (0.6 m at 220 m).
- Mountains: bounce light on steep shaded terrain (0.10 × sun × steepness × shade) keeps faces readable; rock albedo neutral grey-brown.

### 2026-11-08 Art-director re-review (round 6) and river fix
- a 5.50, d 5.00, e 5.50, f 5.67, j 4.83 → **5.30** (was 5.20). Acne bands gone; bounce light helped (f).
- River waterline (top defect): the channel profile stepped 2.5 m at half-width + 4 m, just inside the 6 m-wider water ribbon, so terrain poked through the ribbon in a grid sawtooth. Channels are now continuous smoothsteps that stay below the surface past the ribbon edge (forest river −6.5 m fading over 12 m; mountain river 4.5 m over 18–30 m), so the ribbon's smooth edge is the waterline and the exposed slope beyond it reads as wet bank. `isWater` covers the ribbon extent. Waterlines in (d) and (f) are now smooth.
- Aircraft paint in the CPU previews now uses the same GGX dielectric as Metal plus a sky/ground environment term and slightly lower albedo: glossy gradients and sky reflections instead of flat over-exposed white.
- Tree crowns: near broadleaf trees are a main mass plus 2–3 offset lobes; all crowns get per-vertex shading (darker underside, lighter top) so they read as canopies rather than toy spheres.

### 2026-11-08 Art-director re-review (round 7)
- a 5.50, d 5.33, e 5.50, f 5.83, j 4.83 → **5.40** (was 5.30). The rebuilt river is the biggest single gain since anti-aliasing; lobed crowns read as trees.
- Applied: crease-aware smooth normals (50°) for the aircraft in previews and in Quick Flight, so the fuselage shades smoothly and the GGX lobe can glint.
- Open: per-pixel parcels with thin hedgerows (d, e), river water shading and width variation (d), airport layout and terrain relief (j), slope detail (f), distant edges (a).
- River water: ribbon split at the centre with a lighter shallow tint at the banks, width varying ±10 % along the river, and a 10 % reflection floor for wind-roughened water (seen from above it now carries sky colour instead of flat navy).
- Fields: parcels 110 × 170 m (was 160 × 240); approach corridors and airport zones no longer wear the forest canopy tint (trees were cleared but the ground stayed canopy-green), so the final in (j) shows a field patchwork.

### 2026-11-08 Art-director re-review (round 8) and per-pixel fields
- a 5.67, d 5.50, e 5.50, f 5.83, j 5.00 → **5.50** (was 5.40). River landed fully; aircraft normals partly (no visible glint, wings flat); smaller parcels multiplied the wide blurred hedgerow bands into a "tartan" in (e), with a lime parcel in (d), and (j)'s corridor stayed uniform.
- Fix: `FieldPattern` draws parcels and hedgerows per pixel in both renderers (CPU preview and the Metal world shader, an operation-for-operation mirror on integer hashes, checked GPU vs CPU in CI). The terrain mesh now carries only a per-vertex field weight (snorm8 in the packed normal's w on Metal). Hedgerows are 2.4 m dark strips with gaps, anti-aliased by pixel footprint and fading to their area average when thinner than a pixel. Crops are seven muted tones (pasture, hay, ripe wheat, ploughed soil, stubble, dark pasture, fallow) as ratios to the grassland colour; no lime.
- (j): the mown airfield zone shrank from ±150 m with 500 m extensions to ±90 m with 240 m beyond each end (runway strip and end safety area), so the final approach crosses a field patchwork. Previews re-rendered.
- Steep ground (f): per-pixel fall-line gullies, rock tone variation, scrub patches and pale scree, each octave faded by pixel footprint instead of a fixed 700 m distance, so the shaded valley wall carries detail; mirrored in the Metal world shader.
- Suburb impostor: past the building radius, built-up far terrain draws lots, roofs, back-garden trees and streets per pixel (`FieldPattern.town`, negative field weight; Metal mirror checked against the CPU in CI), averaging to the area colour as the pixel footprint grows. In (a), the band beyond the houses turned out to be farmland past the town edge (field weights confirmed), so (a) is unchanged; the impostor matters in Quick Flight, where tiers draw buildings to 1–2.5 km only.

### 2026-11-08 Art-director re-review (round 9) and fixes
- a 5.67, d 5.67, e 5.33, f 6.00, j 5.50 → **5.63** (was 5.50). Per-pixel fields landed: crisp edges, muted tones, no lime. The approach in (j) now crosses a patchwork. The right-hand face in (f) has gullies.
- Issues raised:
  - Parcels read as flat vector polygons.
  - Hedgerows near the camera read as black ink lines.
  - Scrub on the left massif looked like camouflage.
  - (e) regressed. This was my own error: the earlier preview was rendered with `--time midday`, but my re-render used the scene default, golden hour.
- Fixes:
  - Crop rows (3–6 m, ±7 %) and broad mowing stripes on pasture, oriented per field and faded by footprint.
  - Hedgerows are now mid-dark green and capped at about 3 px wide near the camera.
  - Scrub only on gentler ledges.
  - The coastline scene's default time is now midday, matching the committed preview.
  - `tools/render_previews.sh` renders the five reviewed scenes at their canonical times.
  - The Metal shader mirrors all of the above.
- Aircraft: thin dark seams outline the flaps, ailerons, elevator and rudder on both faces (shared mesh, previews and Quick Flight).

### 2026-11-08 Art-director re-review (round 10) and fixes
- a 5.83, d 5.83, e 6.00, f 6.17, j 5.83 → **5.93** (was 5.63). All four changes landed and nothing regressed.
- Open from the review:
  - (j) near parcels lack visible rows.
  - Parcels dissolve into meadow with soft, stepped edges in (e) and (d).
  - Rock in (f) reads as smooth plastic at mid-distance.
  - No wing glint.
- Field edges: farming is now decided once per parcel at its centre (`FieldPattern.ParcelGrid`; on Metal an R8 texture plus a `fieldGrid` uniform). The vertex weight carries only local clips (river bank, rock, snow, sand, airfield), and their switch is anti-aliased by the screen-space weight gradient (fwidth on Metal, G-buffer neighbours on the CPU). Field areas now end on whole parcels with crisp edges; (e)'s sawtooth is gone.
- Rows: contrast varies per field (5–12 %), pasture mowing stripes are at 6 %, and the generic ground mottle is calmed by 70 % under fields.
- Rock: fine crevices (4 m, along the fall line) and ledges (3.5 m, across it) as normal detail on steep faces, faded by footprint (CPU and Metal).

### 2026-11-08 Art-director re-review (round 11) and fixes
- a 5.83, d 6.00, e 6.17, f 6.17, j 5.83 → **6.00** (was 5.93). Whole-parcel farming landed: crisp continuous edges in (d) and (e).
- Not visible: rows in (j) under the low sun (albedo contrast vanishes) and the 4 m rock detail in (f) (sub-pixel at that range).
- Rows as relief: `FieldPattern.rowTilt` tilts the normal across each row (ploughed 0.20, crops 0.10, pasture 0.03), faded earlier than the colour so it never moirés. The low sun now rakes the rows in (j). Mirrored on Metal.
- Rock at visible scale: buttresses and couloirs (45 × 160 m), dark fall-line streaks and pale ledge bands.
- Swirl fix: all steep-ground noise is now triplanar on the vertical planes (horizontal axis × world height). Rotating world coordinates by the local fall direction had produced a wood-grain swirl, because tiny angle changes times kilometre-scale coordinates warp the pattern. Mirrored on Metal.
- CI: 42d95de failed to compile a Metal-only test on macOS (type-checker timeout in an array literal); split into simple statements.

## Bold Mode

### 2026-11-08 Baseline: first Metal frames of real showcase airports (CI run 42505456889, docs/previews/ci)
- Reviewed by me before the art director sees them:
  - Foreground ground is very blurry. The test used a 1.5 km near layer, and in the app the 2 km final also sits at the edge of the near imagery (far-field Sentinel-2 underneath).
  - A tall terrain "wall" across LSZS: heights switched abruptly from the z14 to the z10 elevation mosaic at the near-square edge.
  - Clouds at ground level at Samedan (1,707 m): the fair-weather layer used an absolute 1,400 m base.
- Fixes:
  - Near imagery, heights and the fine terrain ring now centre 900 m toward the approach.
  - Near and far heights blend over the outer 15 %.
  - Cloud base is the field elevation + 1,100 m.
  - CI review frames use the phone tier from re-recorded packs.
  - The macOS CI tests run in release, so the loads take seconds.

## Bold round 1 — CI Metal frames (commit 4618a1c, run 42527626613), independent art director
First round on real GPU frames after the ground fixes (baseVertex, grading crush, false water).
| Frame | Score |
|---|---|
| KMRY (coastal, default) | 4.5 |
| KASE (mountain) | 5.5 |
| KBFI (city, procedural buildings) | 3.5 |
| LSZS (Sentinel-2) | 3.0 |
| NZQN (Sentinel-2) | 4.0 |
| SkyWorld 320×180 | 2.5 |
| **Average** | **3.83** |
Findings:
- Near-ground "smear": the reviewer suspected a DOF/TAA pass. The renderer has none; the cause is about 6× magnification of the about 3 m/px phone imagery.
- LSZS near-black foreground: the Sentinel-2 imagery is dark there (linear albedo about 0.01–0.02), and there were no trees in it.
- White shore rim (NZQN); untextured fallback boxes doubling the photo roofs (KBFI); flat white aircraft.

Round-2 batch:
1. Imagery clarity: unsharp mask against the mip two levels up.
2. Canopy crowns and bumped normals on photo forest out to 1.5 km; ground micro-detail out to 900 m.
3. Gamma lift of dark mosaics toward a median sRGB luminance of 0.26.
4. Foam at 0.18 and only where wavelets resolve.
5. Trees thinned with distance instead of cut (bac5be8).
Next structural candidate: a higher-resolution inner imagery layer (z17 USGS) around the approach in the packs.

## Bold round 2 — CI Metal frames (16a6845, run 42528493894)
KMRY 4.5, KASE 5.5, KBFI 3.5, LSZS 4.0 (+1.0: trees in the foreground), NZQN 4.5 (+0.5: shore rim gone), SkyWorld 2.5. **Average 4.08 (+0.25).**
The clarity and micro-detail changes are not visible at 640×360.
Round-3 structural change, chosen with the reviewer:
- A z17 USGS approach layer at about 1 m/px (a8f0977, ADR-0017).
- Next: SkyWorld relief and trees in the Metal path, procedural buildings tinted from the photo, aircraft exposure and shadow.

## Bold round 3 — 1280×720 Metal frames (9f8c54a, run 42533862905)
KMRY 5.0, KASE 6.0, KBFI 4.0, LSZS 4.5, NZQN 5.0, SkyWorld 4.5 (full-detail frame). **Average 4.83 (+0.75).**
Findings:
- The z17 layer and the full-HD frames show.
- Photo trees and their baked shadows double the 3D trees (KMRY).
- KBFI boxes are still pale.
- LSZS is dark.
- SkyWorld is flat, its tree belts read as walls, and the approach foreground had no objects.
- A CPU reference render of the KMRY camera matches the GPU softness, so the GPU path is clean.
Round-4 batch:
1. Camera-following z18 detail streaming (ea82990).
2. Photo tree and shadow suppression in the near band, where the 3D trees and shadow map take over.
3. Foliage albedo floor for tree tints.
4. SkyWorld objects also around the final approach.

## Bold round 4 — 1280×720 Metal frames (2e80968, run 42537244102)
KMRY 5.0, KASE 6.0, KBFI 4.0, LSZS 4.5, NZQN 5.0, SkyWorld 5.0. **Average 4.92 (+0.09, below 0.2).**
Findings:
- Only SkyWorld visibly improved, from the approach-area trees.
- The LSZS lower half stayed at a mean of 34/255 even with the foliage floor, so lighting or shadow is the cause; a cumulus shadow is suspected.
- KBFI roofs still pale.
- A colour grade is estimated at about +0.2, but only after LSZS exposure is fixed and with a gentle toe.
Same run: the frame-time step failed. SkyWorld high was 17.05 ms (baked approach trees doubled its shadow cost) and KMRY high 17.81 ms (extra imagery samples on every terrain pixel). Fixes:
- SkyWorld trees are GPU-instanced and cell-culled (`setTrees`).
- Hedgerow trees along farmed parcels.
- Detail-layer and suppression samples run only where used, with explicit gradients.

## Bold round 5: 1280×720 Metal frames (commit ab5c88a, run 42552583206)
Scores: KMRY 4.5, KASE 6.0, KBFI 4.0, LSZS 5.0, NZQN 5.0, SkyWorld 5.5. **Average 5.00 (+0.08).** This is the second round in a row that gained less than 0.2.

Findings:
- **What worked:**
  - The cloud-shadow fill light. LSZS's lower half is 34 → 46/255, and crowns and their shadows now read.
  - The colour grade.
  - The SkyWorld hedgerows.
- **KMRY regressed:** the near ground was posterised.
  - Cause: photo-tree suppression lifted building and terrain shadows to a flat local average and left hard dark rims.
  - A numpy prototype on KMRY tiles showed the rims survive feathering, because the partly dark edge pixels stay below the darkness test.
- **KBFI:** walls derived from the roof turned charcoal.
- **SkyWorld:** near crowns were faceted, and fields turned lime.

Round-6 batch, a structural change of approach:
1. Suppression removed. The 3D trees stand on the photo's foliage pixels.
2. Fallback roofs use the brighter half of their samples. Walls use a stucco/siding palette.
3. Vibrance spares greens.
4. Tree crowns get smooth radial normals.

## Bold round 6: 1280×720 Metal frames (c769527, run 42554218498)
Scores: KMRY 5.0, KASE 6.0, KBFI 4.5, LSZS 5.0, NZQN 5.0, SkyWorld 5.5. **Average 5.17 (+0.17).** This is the third round in a row under 0.2.

Findings:
- KMRY's posterisation is gone.
- KBFI walls now read as stucco with lit and shaded sides. Some boxes still stand on paved lots.
- SkyWorld crowns are still faceted. Cause: stacked crown sections with opposite slopes, not the shading normals.
- Biggest lever (art director): four of the five real frames are capped by the bottom 40 % of the frame, which shows a magnified ~1 m/px photo.

Round-7 batch, structural (b7affb8):
- **Near-ground detail materials.** Each photo pixel within 800 m is classified, and each class adds its own high frequencies and normal tilt:
  - grass
  - dry grass
  - soil
  - pavement/roof
- **Tree crowns.** Near broadleaf crowns get 12 sides and ellipsoid normals.

## Bold round 7: 1280×720 Metal frames (499eca0, run 42557478493)
Scores: KMRY 5.0, KASE 6.0, KBFI 4.5, LSZS 5.25, NZQN 5.0, SkyWorld 5.75. **Average 5.25 (+0.08).**

Findings:
- **What worked:** smooth SkyWorld crowns, the LSZS forest-floor floor, and the hinge dashes are gone.
- **Accepted by the art director:** ground softness at this camera is in the photo, not magnification (ADR-0019).

Round-8 batch, reusing the classifier:
1. **Canopy trees.** 3D trees are placed on dark crowns that are not redder than green. Oak and shaded crowns had missed the forest score.
2. **Crown shapes.** Per-instance crown width, squash and lean, shared by the main and shadow passes.
3. **Aircraft paint.** Albedo is capped at 0.52; at 0.66 it sat at the tone-map shoulder.

Not changed: shadow ambient stays physically based. Ambient is not multiplied by the shadow term; it is the clear-sky irradiance.

## Bold round 8: 1280×720 Metal frames (5c2575c, run 42561292621, all CI green)
Scores: KMRY 5.5, KASE 6.25, KBFI 4.75, LSZS 5.75, NZQN 5.0, SkyWorld 5.75. **Average 5.50 (+0.25).**

What worked:
- Dense 3D trees on photo canopy gave the largest real-airport gain since the z17 imagery.
- The cause of the earlier misses: the 2 km final's foreground lay outside the tree disc, and oak and shaded canopy failed the forest score.

New problems:
- Crowns are cooler and bluer than the photo canopy.
- Crowns stand beside their photo trees, so trees and shadows appear twice.
- Some trees stand on shadowed pavement.
- The aircraft still renders near 245/255.

Round-9 batch:
1. Trees snap to the darkest point within 3 m, the photo crown's centre.
2. Dark-canopy placement requires green ≥ blue.
3. Crown hue is clamped (blue ≤ 0.75 × green, red 0.65–1.05 × green).
4. Foliage ambient is 0.7 × a sky/ground mix, standing in for occlusion inside the crown.
5. Aircraft paint albedo capped at 0.40.

## Bold round 9: 1280×720 Metal frames (feb6272, run 42562430575, tests and frame time green)
Scores: KMRY 5.75, KASE 6.5, KBFI 5.0, LSZS 5.25, NZQN 5.0, SkyWorld 5.75. **Average 5.54 (+0.04).**

Findings:
- **What worked:** crown colours now match the photo (no more blue crowns), and trees snap onto their photo blobs.
- **Regression:** the clamp's red ceiling of 1.05 × green turned LSZS forest khaki; saturation fell from 29 to 16.
- **Still open:**
  - The photo's own baked tree shadows remain beside the 3D trees.
  - Some trees still stand on paved lots.
  - The aircraft's sides render flat.

Round-10 batch:
1. **Crown colour:**
   - Red is clamped to 0.70–0.90 × green, with saturation at least 0.25.
   - Foliage ambient returns to 0.85; darkening applies only to downward-facing crown surfaces.
2. **Placement:** dark canopy requires green ≥ blue + 0.015–0.04 and green ≥ 0.9 × red.
3. **Crown shape:** crowns start at 0.2 of the tree's height, so less trunk shows.
4. **Aircraft:** occlusion darkens the fuselage's lower curve.

## Bold round 10: 1280×720 Metal frames (8d14b3c, run 42563635349)
Scores: KMRY 5.75, KASE 6.5, KBFI 5.0, LSZS 5.5, NZQN 5.0, SkyWorld 5.75. **Average 5.58 (+0.04).**

Findings:
- Under 5 % of pixels changed in five of the six frames.
- **LSZS saturation:** 18 on screen, against 29 in r8. The cause was the 0.25 saturation floor, which could never act while blue was already clamped to ≤ 0.75 × green.
- **Tree snapping:** snapping to the darkest point drifted trees onto their own baked shadow.
- **Aircraft:** shading changes don't show from above and behind.

Round-11 batch:
1. **Crown colour:** blue ≤ 0.55 × green and red 0.62–0.85 × green, which gives saturation of at least ~0.4. Luminance floor 0.08.
2. **Snapping:** trees snap to the greenest point instead of the darkest.
3. **Livery:** accent-blue fin, tailplane tips and fuselage-top stripe.
4. **Deferred:** SkyWorld relief in view, because of the risk of terrain under the approach.

## Bold rounds 11: 1280×720 Metal frames (34d36eb, run 42581086411, all green)
Scores: KMRY 6.0, KASE 6.75, KBFI 5.25, LSZS 6.0, NZQN 5.25, SkyWorld 6.0. **Average 5.88 (+0.30).**

Findings:
- **What worked:**
  - The crown saturation fix: LSZS is lit green forest again (saturation 18 → 26).
  - The livery breaks up the white aircraft in every frame.
  - The cheaper tree LOD shows no visible regression in stills.
- **Still open:**
  - The photo's own shadows sit beside the 3D trees (KMRY).
  - Lone lollipop trees on bare lots (KBFI).
  - NZQN's lake is unchanged for eight rounds.

Round-12 batch:
1. **Lake water:**
   - A shallow turquoise body across the shore band.
   - A broad sun sheen.
   - Reflection scale 0.85 (was 0.6).
2. **Lone trees:** trees with fewer than 2 neighbours within 10 m are dropped.
3. **Crown variety:** ±4 % per-tree red/green hue.

## Bold round 12: 1280×720 Metal frames (28cf4aa, run 42583714104)
Scores: KMRY 5.75, KASE 6.75, KBFI 5.25, LSZS 6.0, NZQN 5.75, SkyWorld 6.0. **Average 5.92 (+0.04).**

Findings:
- **What worked:** NZQN water now reflects the sky (lower-half brightness 81 → 97).
- **KMRY regressed:** the rule "2 neighbours within 10 m" removed real suburban oaks, which stand 10–25 m apart.
- **Performance cuts not checked:** the review frames do not use the high cloud tier or the desktop tree cap. Their sky and SkyWorld are byte-identical to r11, so these frames cannot judge the cloud-step and tree-cap cuts.

Round-13 batch:
1. **Lone-tree rule:** a tree needs 1 neighbour within 20 m.
2. **Tree brightness:** ±8 % jitter, applied after the floor.
3. **Water:**
   - A 60 m swell octave on rotated axes, against visible wavelet tiling.
   - A wider shallows band.

## Bold round 13: 1280×720 Metal frames (135c980, run 42585133971, all green)
Scores: KMRY 6.0, KASE 6.75, KBFI 5.25, LSZS 6.0, NZQN 6.0, SkyWorld 6.0. **Average 6.00 (+0.08), the first round at 6.**

Findings:
- **What worked:**
  - The swell octave makes NZQN read as a real lake.
  - KMRY's tree density is restored.
- **Still open:**
  - KBFI's lot props are back.
  - Single-pixel water sparkles.

Round-14 work:
1. **Photo-shadow decals: tried, not shipped.**
   - The direction estimate (a pooled luminance profile around trees) found clear dips at KMRY (east) and KBFI (northwest), and none at KASE.
   - Lifting each tree's shadow toward the ground colour beside it painted flat grey ovals over neighbouring crowns. That is the same flat-fill failure as the round-5 suppression.
2. **Lone-tree rule by ground class:** trees on paved surroundings (5 of 8 ring samples bright and unsaturated) need 2 neighbours within 10 m. Elsewhere, 1 within 20 m.
3. **Water sparkles:** the needle specular lobe only applies where wavelets resolve, capped at 12.

## Bold round 14: 1280×720 Metal frames (1f9312c, run 42590247714)
Scores: KMRY 6.0, KASE 6.75, KBFI 5.5, LSZS 6.0, NZQN 6.0, SkyWorld 6.0. **Average 6.04 (+0.04).**

Findings:
- **What worked:** the ground-class lone-tree rule cleared KBFI's lot props and kept KMRY's oaks.
- **Glints:** the specular cap dims them; they now read as plausible glints.
- **SkyWorld:** unchanged for seven rounds.

Round-15 batch:
1. **Multi-lobe crowns:** near broadleaf crowns are a 9-sided main crown plus two offset 7-sided lobes, each with its own ellipsoid normals (97 triangles, against 70). SkyWorld shares the mesh.
2. **Highlight shoulder:** photo albedo above 0.28 is compressed (0.72 → 0.52), so near-white concrete and roofs no longer blow out.

## Bold round 15: 1280×720 Metal frames (1aaf2da, run 42592435319)
Scores: KMRY 6.0, KASE 6.75, KBFI 5.5, LSZS 6.0, NZQN 6.0, SkyWorld 6.0. **Average 6.04 (+0.00).**

Findings:
- Rounds 14 and 15 both gained less than 0.2.
- **Lobed crowns:** they reach only trees within 350 m, which here means SkyWorld. Their own normals left facets and creases.
- **Highlight shoulder:** it moved the brightest 1 % by only 5–6 of 255.

Round-16 change, structural:
- **Review coverage extended to the desktop/high tier.**
  - The phone-tier review frames never showed the high tier, which has the 4096 px detail imagery, denser terrain and more trees.
  - They also never covered the frame-budget cuts: cloud steps and light taps, and the 65k and 75k tree caps.
  - CI now also captures all five airports and SkyWorld with `RealWorldDetail.desktop` and `Settings.high`.
  - Both tiers are scored and reported.

Same batch:
1. Highlight shoulder: knee 0.22, slope 0.45.
2. Lobe normals blended 50/50 with the whole crown's ellipsoid normal.
3. Wall contact band: the lowest ~0.8 m of ground-standing walls at 0.62 × the wall colour.

## Bold round 16: 12 Metal frames, phone and high tiers (dd41f05, run 42593932269)
Phone: KMRY 6.0, KASE 6.75, KBFI 5.5, LSZS 6.0, NZQN 6.0, SkyWorld 6.0. **Average 6.04 (+0.00).**
High: KMRY 6.0, KASE 6.5, KBFI 5.5, LSZS 6.25, NZQN 6.0, SkyWorld 6.25. **Average 6.08.**

Findings:
- The three round-16 changes are barely visible on phone (lower-half mean pixel difference ≤ 0.6).
- **High tier:** denser trees help every scene, but the clouds show a regular 2×2 checker: quarter-resolution clouds with per-pixel jitter, under a tent filter sized for half resolution.
- **High-tier KMRY:** blue patches in the mid-ground where phone shows tree shadows. The desktop near layer's water-mask cells are 8 m, so the 24-cell minimum admitted water bodies of only ~1,500 m².
- **Highlights:** the brightest 1 % (≈ 224/255) is bare sand and concrete in the photo, not the aircraft (222 with the aircraft masked out). ACES is flat near white, so each shoulder step moved it only ~5 levels, and the grade's S-curve lifted it ~7 levels more.
- **SkyWorld:** flat terrain, for nine rounds.

Round-17 batch:
1. **Cloud reconstruction at quarter resolution:** a 3×3 box over the low-res texels. Interleaved-gradient jitter is near uniform over any 3×3 block. Half resolution keeps the tent.
2. **Water minimum is an area (6,000 m²), not a cell count:** test with 8 m cells (48 m shadow patch removed, 120 m pond kept).
3. **Highlights:** knee 0.20, slope 0.32; the grade's S stops lifting above ~0.6.
4. **SkyWorld relief:** hills up to ~240 m, 2–4.5 km either side of the runway axis (0.45 × on the town side) and past the far end. The runway, approach and climb-out are untouched (test).

## Bold round 17: 12 Metal frames (710cdb7, run 42596319498)
Phone: KMRY 6.25, KASE 6.75, KBFI 5.75, LSZS 6.0, NZQN 6.0, SkyWorld 6.5. **Average 6.21 (+0.17).**
High: KMRY 6.25, KASE 7.0, KBFI 5.75, LSZS 6.5, NZQN 6.25, SkyWorld 6.75. **Average 6.42 (+0.34).** KASE high is the first frame at 7.

Findings:
- **Highlights:** the brightest 1 % fell 13 levels on KMRY and KBFI (221 → 208, 224 → 211, aircraft excluded); near concrete no longer reads clipped.
- **Clouds:** the checker is gone and there are no halos at ridgelines. The 3×3 box over quarter-resolution texels softened them, though (sky fine detail 0.78 on high against 1.20 on phone).
- **SkyWorld:** the hills show, but as a low, pale band.
- **KMRY blue patches:** still there on high, and now on phone too. The source imagery settles it (dumped water mask over the near photo):
  - The real pond north of the approach is detected, but its mask bleeds into the trees around it.
  - The other patches are dense dark canopy: an oak and pine stand on the hillside south of the runway, a conifer strip, and town tree clusters.
  - Laguna Grande and Roberts Lake are real but not detected (olive water colour). Left as is.
  - Per 8×8 block (sRGB luminance standard deviation): ponds and sea 0.004–0.008, canopy 0.05 or more, town 0.14.

Round-18 batch:
1. **Water texture test:** each mask cell's water score is weighted by `1 − smoothstep(0.02, 0.04)` of the median luminance spread over its 3×3 neighbourhood. Test: textured dark canopy is not water; a smooth lake and its edge stay.
2. **Clouds, quarter resolution:** 2×2 Bayer step jitter, with a composite of 4 bilinear taps at ±0.5 texel. That is an exact [1 2 1]² tent, which weights the four Bayer phases equally at any position, so the pattern cancels over a 3-texel footprint instead of the box's ~4.
3. **Photo shadow toe:** below 0.07 albedo, lifted as `0.07·(al/0.07)^0.7` (0.02 → 0.03); fades by 1.2 km; not on water.
4. **SkyWorld hills:** 340 m, starting 1.9 km off the axis (was 240 m from 2 km).
5. **KBFI fallback boxes:** skipped where 5 of 8 photo samples 14 m out match the roof luminance (on a warehouse roof or car park the photo already shows). Test.

## Bold round 18: 12 Metal frames (ba04e91, run 42600144759)
Phone: KMRY 6.5, KASE 6.75, KBFI 5.75, LSZS 6.0, NZQN 6.0, SkyWorld 6.75. **Average 6.29 (+0.08).**
High: KMRY 6.5, KASE 7.0, KBFI 5.75, LSZS 6.5, NZQN 6.25, SkyWorld 7.0. **Average 6.50 (+0.08).** High: KASE and SkyWorld at 7.

Findings:
- **KMRY false water:** gone on both tiers (blue pixels in the area 785 → 200 on high); the big lake still reads as water.
- **SkyWorld hills:** now read as terrain.
- **High-tier clouds:** no pattern, slightly crisper (fine detail 0.78 → 0.81; phone 1.20). Quarter resolution caps edge sharpness whatever the filter.
- **Shadow toe:** invisible (KMRY darkest 1 % unchanged). At 0.07 it sits below most photo shadow albedo.
- **KBFI skip test:** barely visible; the remaining boxes are uniform pale cubes.
- **Remaining issues:**
  - LSZS: one uniform canopy texture.
  - NZQN and KASE (phone): smeared photo at grazing angles.

Round-19 batch (first round under 0.2 since the structural change; a second would trigger another):
1. **Toe:** knee 0.10, exponent 0.65 (0.03 → 0.046, 0.06 → 0.072).
2. **High-tier clouds:** one-third resolution with 26 steps (quarter with 32). The Bayer tent path applies above downsample 2.5. 2 ms of headroom was measured.
3. **Forest stands:** ~300 m noise sets the conifer share (12–88 %), with darker conifer and lighter broadleaf stand tones; half of each tree's height comes from its stand. Test: the conifer share varies by > 0.4 between 200 m patches.
4. **Photo sampler:** anisotropy 16 (was 8).
5. **KBFI fallback buildings:** darker siding and brick wall tones, and a fifth of them two-storey.

## Bold round 19: 12 Metal frames (6fad245, run 42602113280)
Phone: KMRY 6.75, KASE 6.75, KBFI 6.0, LSZS 6.25, NZQN 6.0, SkyWorld 6.75. **Average 6.42 (+0.13).**
High: KMRY 6.75, KASE 7.25, KBFI 6.0, LSZS 6.75, NZQN 6.5, SkyWorld 7.0. **Average 6.71 (+0.21).**

Findings:
- **High-tier clouds:** now match phone (fine detail 1.18 against 1.21), with no pattern.
- **Shadow toe:** softer, not washed out.
- **KBFI:** the brick and siding tones sit in the scene.
- **LSZS stands:** not yet readable as patches.
- **Anisotropy 16:** made no visible difference.
- **Process:** phone gained under 0.2 in rounds 18 and 19, so a structural change follows. The art director's pick: baked photo shadows and photo tree blobs are what hold KMRY, KBFI, NZQN and KASE-phone below 7.

Round-20 structural change: **photo trees removed under the 3D trees** (`ImageryDelighting`, applied to the near and detail layers when the render data is built, and to the in-flight detail layer).
1. **Discs:** one around each placed 3D tree, `h·(0.42 broadleaf | 0.25 conifer) + 0.25·h` for the photo crown plus its shadow, feathered 2.5 m.
2. **Mask:** inside the discs, photo canopy (green above red and blue, not bright lawn) or shadow (luminance below 0.6–0.85 × its 10 m local mean). Water is excluded, and the mask fades where under 15–35 % of the ground within 25 m is unmasked (closed forest keeps its photo; nothing lit to fill from).
3. **Fill:** push-pull inpainting (weighted 2×2 pyramid, then bilinear pull), in 512 px tiles with a 64 px apron, so holes take the lit ground next to them rather than an average (the round-13 decal's grey ovals).
4. **Tests:**
   - A blob and its shadow under a 3D tree are filled to the ground colour; the same blob without a tree is untouched; lit ground is unchanged.
   - Water is kept, and closed forest is left alone.
   - Push-pull fills from neighbours.
5. **KMRY check on the real pack (phone near):** the golf-course trees and their shadows become fairway, with no ovals. 227k of 4.2M pixels changed; the 0.59 m detail layer changed 620k.

## Round 20: de-lighting (b10d6c3 → 7deeb4c, run 42619494239). Unscored.
- **Reviewer:** stopped on its usage limit before scoring (ADR-0020).
- **Own regression check:**
  - KMRY near band: fewer dark photo blobs under the 3D trees; the remaining dark patches are shadow-map shadows.
  - KBFI near band: unchanged (few trees there).
  - No ovals, rims or smears seen.
- **Frame times:** within budget (SkyWorld high 16.16 ms, KMRY high 15.52 ms).

Round-21 batch (the reviewer's round-19 fixes 2 and 5; unscored):
1. **LSZS stands:** crisp edges (the conifer share is a smoothstep over ±0.08 of the noise, was ±0.22, range 10–90 %); conifer stands ~22 % darker and bluer-green, broadleaf stands lighter and yellower.
2. **SkyWorld fields:** within-field variation, ±9 % brightness at ~55 m and a ±4 % green/red shift at ~35 m, faded where it would alias. Applied after `fieldFactor`, so the CPU mirror test still holds.
- Round 21 own check (run 42722423559): the LSZS stands and SkyWorld in-field variation are barely visible at review distance; the high-tier clouds are unchanged by the 22/3 step cut. Unscored (ADR-0020).

## Visual transformation phase (2026-11-10, PR #5, ADR-0021)
Frames are Metal renders from the CI GPU at the ultra tier, 1280×720, four cameras per airport (final, aircraft close-up, a high view, cockpit). Own inspection only; no independent score is claimed (ADR-0020) and no parity with MSFS is claimed.

| Run | What was looked at | Findings |
|---|---|---|
| 42744312670 (baseline, before) | phone and high tier frames | Soft, bleached ground; almost no buildings; lollipop trees; low-poly aircraft. |
| 42817030287 (exposure fix) | KMRY, KASE, LSZS | Mid-tones correct; real OSM buildings with facades across Monterey; new airframe with livery and registration. Weak: KASE and KMRY foreground photo soft; trees still the old blobs; cockpit a set of black boxes. |
| 42818081873 (trees, cockpit, ground detail) | KBFI, KMRY, NZQN | Trees read as species with lobes and shading; Seattle skyline present but towers flat grey; cockpit gauges visible but cabin unlit (black). NZQN: Sentinel-2 ground (10 m) is a blur, and the lake is cut by a straight line where the near layer's water mask ends. Near ground at US airports is limited by the source (USGS tiles are about 1.6 m per pixel; the finer export is an upsample, checked directly). |

Changes made in response (frames pending at the time of writing): land cover water mask at any distance (ESA WorldCover), water reflecting the real sky with wind patches, cabin fill light, tinted reflective tower glass, fine cloud structure, magnification-aware local contrast for the ground photo, and LINZ 0.1–0.3 m aerial imagery for NZQN.

## Bold round 22: new baseline after PR #5 (main af4ede2, run 42921068888, ultra tier)
Same reviewer and scale as rounds 5–19 (ADR-0020 pause ended).

**Final camera:** KMRY 7.0, KASE 7.25, KBFI 6.75, LSZS 6.75, NZQN 7.25, SkyWorld 7.0. **Average 7.00** (round-19 high tier: 6.71).

| Airport | Close | High |
|---|---|---|
| KMRY | 7.25 | 6.75 |
| KASE | 7.0 | 6.5 |
| KBFI | 6.75 | 6.75 |
| LSZS | 6.5 | 6.0 |
| NZQN | 7.25 | 6.0 |

KMRY cockpit: 4.5.

**Improved most:** OSM buildings (KBFI +0.75, NZQN), the aircraft model, and a more photographic sky.

**Regressed:**
- **Near-band local contrast:** in the near band, 21 % (KBFI) and 34 % (KMRY) of pixels sit above 1.6× the band median, against 0–2.5 % in round 19. The near-identity photo albedo lost the round-17–19 shoulder, so concrete and roofs read as white blotches.
- **LSZS:** the forest is near-black (lower half 64 → 35).
- **KASE road ribbon:** broken, near-black, and floating over the cliff.

Round-23 batch (top fixes 1–4):
1. **Photo albedo shoulder:** knee 0.24, slope 0.25 (was 0.42/0.48), so 0.8 → 0.38.
2. **OSM roofs:** take the photo's tone about 4 mips coarser (~13 m at US sources) instead of the projected photo, clamped to 0.32.
3. **Roads:** asphalt 0.10–0.12 (was ~0.05). A quarter of the blurred photo tone is blended in, rising toward the carriageway edges. Draped every 8 m (was 20), with lift 0.4 m.
4. **LSZS:** canopy photo floor 0.07 (0.05) and 3D tree tint floor 0.10 (0.08).

Not done: the cockpit materials, and slope-aware detail on steep photo (fix 5).

## Bold round 23: PR #6 d7faa5d (ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.0, KASE 7.5, KBFI 6.75, LSZS 6.75, NZQN 7.25, SkyWorld 7.0. **Average 7.04** (round 22: 7.00). Cockpit 4.5.

**Improved:** the KASE road ribbon (now drapes and reads as asphalt); fewer near-band blotches (share of pixels above 1.6× the band median: KMRY 33.5 % → 32.3 %, KBFI 21 % → 15.1 %).

**Still wrong:**
- **KBFI roofs:** a near-black oval roof (the photo's own shading projected onto it, even at the coarser mip).
- **LSZS forest:** still near-black (lower-half mean 35.1 → 38.8).
- **Baked shadows:** photo shadows and dark car parks still read as blotches beside the 3D lighting.

Rounds 22 and 23 both gained under 0.2, so this batch is structural.

Round-24 batch:
1. **One roof colour per building, set at load:**
   - Median of a 6 × 6 photo grid inside the footprint, ignoring the darkest fifth.
   - Luminance held to 0.08–0.25 and saturation to 60 %.
   - The shader's per-pixel photo roof is off; mottle and weathering streaks are procedural.
2. **Local tone compression on the near photo ground (within 1.8 km):**
   - Each pixel is held within ±40 % of the photo's ~30 m mean, with a soft tanh knee.
   - Not applied on water or the runway.
3. **Foliage ambient ×1.6, crown occlusion floor 0.5 (was 0.35):** for LSZS's near-black stands under the 0.45 exposure.

Not done: slope-aware detail and the cockpit materials.

## Bold round 24: PR #6 3287a56 (run 43582068030, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.5, KBFI 6.75, LSZS 7.0, NZQN 7.25, SkyWorld 7.0. **Average 7.13** (round 23: 7.04). Cockpit 4.5.

| Airport | Close | High |
|---|---|---|
| KMRY | 7.0 | 6.75 |
| KASE | 7.25 | 6.5 |
| KBFI | 7.0 | 6.75 |
| LSZS | 6.75 | 6.0 |
| NZQN | 7.25 | 6.0 |

**Improved:**
- **KBFI roofs:** the near-black roof blob is gone; roofs read as clean uniform surfaces.
- **LSZS forest:** crowns read individually, and the lower half is brighter (38.8 → 47.2).
- **Near-band blotches:** KMRY 32.3 % → 27.6 %, KBFI 15.1 % → 11.6 %.

**Regressed:**
- **KBFI shadows:** lifted photo shadows turned saturated blue.
- **KMRY close:** a 70 px white flare on a roof.
- **KMRY tile roofs:** terracotta turned grey.

Cause of the flare: fast-math `tanh` of a large argument returns NaN. The bloom tap's `min(NaN, 6e4)` gave 6e4, so one pixel bloomed.

Round-25 batch:
1. **Tone compression:**
   - The `tanh` argument is clamped.
   - Lifted pixels (over 1.1×) take the local mean's chroma at their new luminance, so shadows can't saturate.
2. **Bloom taps:** non-finite values are dropped by checking their exponent bits.
3. **Roof hue:** red and orange tile keeps 90 % saturation (others 60 %).
4. **Steep-slope detail on the photo terrain:** fall-line gullies, ledges and crumple, as on SkyWorld. Relief is at full strength, tone at 60 %, with no scrub or scree.

Not done: the cockpit materials.

## Bold round 25: PR #6 e6b2c66 (run 43583381131, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.5, KBFI 7.0, LSZS 7.0, NZQN 7.25, SkyWorld 7.0. **Average 7.17** (round 24: 7.13). Cockpit 4.5. KMRY close rose from 7.0 to 7.25; the high frames are unchanged (6.0–6.75).

**Fixed:**
- **KBFI blue smears:** saturated-blue pixels in the lower band fell from 2,919 to 374.
- **KMRY close flare:** gone.

**Landed weakly:** tile roofs are slightly warmer; the source photo's tile colour is already desaturated.

**Did not land:** the steep-slope detail. KASE high is byte-identical to round 24. The photo terrain's mesh normals come from a smoothed 30 m DEM, so the 0.9 gate never fired, and the small octaves fade out at high-camera footprints.

Round-26 batch:
1. **Slope gate on the photo terrain:** n.z < 0.97 (smoothstep 0.97 → 0.82). A new 150 m spur and gully octave (relief and a tone band) survives at several metres per pixel.
2. **LSZS stands:** conifers another ~20 % darker and bluer (0.58/0.66/0.76); stand edges sharper (±0.05).
3. **Cockpit:**
   - Glare shield, panel, door panels and headliner are subdivided, with edge occlusion and moulded grain.
   - Stitched seam on the glare shield.
   - Avionics displays, digits, knobs and keys now sit on the box's real front face (they were inside it, hence the "stripes").
   - A wet compass housing with a card window replaces the hanging disc.
   - Slim headliner roll (was a fat black bar), sun visors, and pillars in trim colour.

## Bold round 26: PR #6 4ac2b99 (run 43584489956, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.0, LSZS 7.25, NZQN 7.25, SkyWorld 7.0. **Average 7.25** (round 25: 7.17). **Cockpit 5.25** (4.5).

**Improved:**
- **KASE cliff:** fall-line gullies, spurs and ledge bands (final 7.75, close 7.5).
- **LSZS:** distinct conifer stands.
- **Cockpit:** avionics displays and knobs read.

**Regressed:**
- **KASE road median:** a near-black sliver between the carriageways (relief tipping shaded slopes past the terminator).
- **Compass:** a housing three times too large in the windscreen.

**Unchanged:** NZQN high hillside (smeared blue-grey).

Round-27 batch:
1. **Water lies flat:** the water fraction is scaled by the mesh normal (smoothstep 0.93 → 0.985).
   - Suspected cause: the coarse land-cover water outside the near layer bleeds onto the steep shore above Lake Wakatipu. That would render the slope as water (`m = 1`) and skip the slope detail.
   - Unverified until the frames show it.
2. **Photo-terrain relief at 70 %:** for the KASE median sliver.
3. **Cockpit:**
   - Compass a third the size, on a windscreen centre post.
   - Headliner as a shallow arch of quilted strips with seams.
   - Mid-grey moulded pillar covers.
   - Lighter glare shield with a padded lip that catches the light.

The "floating white arc" the reviewer took for the yoke is the cowling seen over the glare shield; the yoke is below the view.

## Round 27 (5c7ec27, run 43586198123): not scored, regression check only
- **NZQN high left hillside:** unchanged (mean difference 0.02). The water gate was not the cause.
  - At full size the slope is shaded (ambient only) and seen at a grazing angle, so the photo smears radially even with 16× anisotropic filtering.
  - Every relief octave faded on fwidth, which there is the long axis of the footprint.
- **KASE road median:** changed (relief at 70 %).
- **Cockpit:** the compass is smaller, but its 30 cm centre post read as a third windscreen pillar.

Round-28 batch: slope-detail fades use the geometric mean of the two footprint axes on the photo terrain; the compass mount is a 6 cm stub.

## Round 28 (59eacb6, run 43587252208): not scored; structural change
- **NZQN high left hillside:** unchanged for the third round (mean difference 0.02).
- **Root cause:** terrain heights outside the near square (3.2 km half extent) came from the z10 far mosaic, about 156 m per sample, under a 32 m ultra mid mesh.
  - Every slope 3–12 km out was a smooth blob with the photo stretched over it.
  - It was also too gentle for the slope gate, so no shader change could reach it.
  - The same limit sits under the KASE and LSZS valley walls in the high frames.
- **Structural fix:** a mid height mosaic (Terrarium z12, 1024² over the 12 km mid half extent, about 23 m per sample).
  - Near → mid → far, each blended over its outer 15 %.
  - Kept only when every tile is real Terrarium data, not the coarse global baseline.
  - z12 tiles added to all six showcase packs with `tools/fetch_mid_heights.py` (same keyless AWS open-data source and attribution; about 18 MB).
- **Compass:** the mount stub reads as intended.

## Bold round 29: PR #6 b051139 (run 43588783942, ultra tier)
Same reviewer and scale; compared with round 26.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.0, LSZS 7.25, NZQN 7.25, SkyWorld 7.0. **Average 7.25** (unchanged; the finals moved under 1 level).

**High frames:** KMRY 6.75, KASE 6.75, KBFI 6.75, LSZS 6.25, NZQN 6.5. **Average 6.58** (6.38). **Cockpit 5.5** (5.25).

**Improved:**
- **NZQN high:** the shore hillside has spurs and gullies with lit and shaded faces (the mid z12 height mosaic).
- **KASE high:** drainage lines on the valley sides.
- **Cockpit:** the compass is the right size and in the right place.

**Still wrong:**
- **KASE road median:** a fainter dark streak remains.
- **Photo slopes:** the photo on them is still soft.
- **Cockpit:** the headliner seams are too faint, there is no yoke in view, and the visor has no shape.

Round-30 batch:
1. **Road proximity mask:** in the near water-mask texture's second channel (rg32Float). Slope relief is zeroed within half the carriageway plus 4 m of an OSM road centreline, fading over 6 m more.
2. **Photo slopes:** scrub (−22 %) and scree (+22 %) tone patches at 32 m, on the photo's own colour.
3. **SkyWorld:**
   - Field variation ±14 % at 55 m and ±7 % hue, plus ±12 % wet/dry patches at 140 m.
   - Per-tree crown brightness ±18 %.
4. **Cockpit:**
   - Yoke hub raised to 0.5 m below the eye, with upswept horns at the bottom of the view.
   - Headliner strips alternate ±8 %, with seams at 45 %.
   - Stitched visor rims.
   - A highlight edge on each pillar.
   - Shaded carpet.

## Bold round 30: PR #6 26a42ba (run 43596537161, ultra tier)
Same reviewer and scale.

**Scores:** finals 7.25 (unchanged), high frames 6.58 (unchanged), **cockpit 5.75** (5.5).

**Fixed:**
- **KASE road median:** the sliver is gone (road proximity mask).
- **Cockpit:** the headliner and pillars read, and the yoke horns show.

**Too faint to score (about 1 % pixel change):**
- Slope scrub and scree at ±22 %.
- SkyWorld field variation at ±14 %.
- Crown brightness ±18 %.

Rounds 29 and 30 both left the finals flat. Round 29 carried the structural change (the mid z12 height mosaic), which lifted the high frames.

Round-31 batch (`6163802` plus this commit):
1. **Yoke shaft:** leaves the panel below the PFD, with taller horn tips.
2. **SkyWorld:**
   - Variation fades by the geometric-mean footprint (it faded out at grazing angles).
   - ±25 % value and ±10 % hue at 110 m.
   - Crown size ±30 %.
3. **Photo slopes:** scree fans and scrub bands at about 90 m. Amplitude rises from 25 % to 35 % beyond 3 km, and the scrub is a cooler green.
4. **LSZS:** forest floor at 0.09 with a slight green lean.
5. **Cockpit:**
   - Crinkle finish on the panel face and lower panel.
   - Rounded visor front edges.

## Bold round 31: PR #6 13a1375 (run 43598001198, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.0, LSZS 7.25, NZQN 7.25, SkyWorld 7.25. **Average 7.33** (round 30: 7.25).

**High frames:** 6.58 (unchanged). **Cockpit 6.0** (5.75).

**Improved:**
- **SkyWorld:** field tone variation shows across the patchwork, including at grazing angles, and crown sizes vary.
- **Cockpit:** the PFD is clear.

**Did not show:**
- Slope scree and scrub at 90 m.
- The LSZS forest floor (little open ground between the crowns).
- The cockpit crinkle finish. The yoke horns left the frame.

Round-32 batch:
1. **SkyWorld crop palette** (CPU `FieldPattern` and GPU together):
   - Golden ripe wheat, pale stubble, and a lighter cut hay.
   - A new eighth crop: flowering rapeseed.
2. **Slope bands:** about 200 m, stretched down the fall line, ±30–40 %, on a wider slope gate (n.z < 0.985) and masked at roads.
3. **Shaded photo terrain:** 35 % more sky light where the sun term is small (LSZS high foreground slope).
4. **Cockpit:**
   - Yoke horn tips back in view.
   - Placards, a rocker-switch row and a fuel selector on the lower panel.

## Bold round 32: PR #6 1e00305 (run 43600292820, ultra tier)
Same reviewer and scale.

**Scores:** finals 7.33, high frames 6.58, cockpit 6.0 (all unchanged).

**SkyWorld:** more varied, but the new crops read as lime and chartreuse. Their ratios on the green grass base kept green above red, and lower-half saturation rose from 43 to 52.

**Not visible:**
- **Slope bands:** they sat inside the photo-terrain slope block, whose own gate was 0.97, so their wider gate never applied.
- **Sky light on shaded terrain:** the LSZS high right slope is still near-black.
- **Cockpit additions:** below the frame edge.

CI note: `1e7e87c` failed the GPU/CPU field parity test. Two shader paths still took the crop index modulo 7; fixed in `1e00305`.

Round-33 batch:
1. **Crop ratios retuned** so mature crops have red above green in linear terms (CPU and GPU):
   - wheat about 0.48/0.40/0.20
   - stubble about 0.50/0.45/0.30
   - rapeseed about 0.62/0.55/0.09
2. **Photo-terrain slope block** entered at n.z < 0.985. The relief still starts at 0.97 through `steep`.
3. **Shadow toe** out to about 5 km at half strength beyond 1.2 km (dark mid-ring photo forest).
4. **Cockpit view** looks 7° down (was 5°), so the yoke tops and lower panel come into frame.

## Bold round 33: PR #6 321f0e9 (run 43601747436, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.0, LSZS 7.25, NZQN 7.25, SkyWorld 7.5. **Average 7.38** (round 32: 7.33).

**High frames:** 6.58 (unchanged). **Cockpit:** 6.0 (unchanged).

**SkyWorld:** calmer. Lime pixels fell from 13.3 % to 6.0 % and saturation from 52 to 44. Still, only 1.5 % of the ground had red above green on screen.

**Slope bands:** a diff map against round 31 (before the 200 m bands) shows they fire. On the NZQN sunlit hill, about 50,000 pixels changed by more than 6, up to 52 levels. They read as part of the photo, so they add no score and the effort stops here.

**LSZS high slope:** about 2 levels brighter; still dark.

**Cockpit:** reframed, but the yoke is still out of view.

Round-34 batch:
1. **Mature crops shifted warm after the field factor:** red +16 %, green −10 %, blue −18 %, scaled by the factor's red-over-green and the coverage.
2. **Shadow toe at full strength to about 4 km.**
3. **Yoke:** raised again, with its horn tips in the bottom 60 px.
4. **Cabin:** panel face and lower panel lighter dark grey (about 0.08–0.09).

## Bold round 34: PR #6 4c1793d (run 43602791437, ultra tier)
Same reviewer and scale. The reviewer corrected round 33's average to 7.33.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.0, LSZS 7.25, NZQN 7.25, SkyWorld 7.75. **Average 7.38**.

**High frames:** 6.58 (unchanged). **Cockpit 6.5** (6.0).

**Improved:**
- **SkyWorld:** warm tan, khaki and ochre crops. In the lower half, pixels with red above green rose from 0.2 % to 11.6 %.
- **Cockpit:** the yoke horns and rim give the cabin depth, though the rim crosses the PFD's bottom strip.

**Still dark:** the LSZS high slope (+2 levels from the toe).

Round-35 batch:
1. **Near-ground detail:**
   - The material octaves fade by twice the geometric-mean footprint (they faded by the axis sum, which erased everything finer than ~8 m in the grazing near band).
   - New ±12 % and ±10 % wear and growth patches at 4 m and 12 m on natural ground.
   - Aimed at the KMRY and KBFI near ground, flat since round 24.
2. **Foliage in shadow:** 40 % more sky light (the dark LSZS high valley wall, likely shaded 3D crowns).
3. **SkyWorld stubble:** warmer (it read mint).
4. **Yoke:** 1.5 cm lower, clearing the PFD's bottom strip.

## Bold round 35: PR #6 8c53ea2 (run 43604226441, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.0, LSZS 7.5 (7.25), NZQN 7.25, SkyWorld 7.75. **Average 7.42**.

**High frames:** 6.58 (unchanged). **Cockpit 6.75** (6.5).

**Improved:**
- **LSZS forest:** brighter in the final and close frames, with shaded crowns green and conifer stands still distinct.
- **Cockpit:** the PFD's bottom strip is clear of the yoke.

**Not visible:**
- **KMRY and KBFI near-ground octaves.** The cause: the soft, low-chroma photo of lawn and dirt classifies as pavement, so the "natural" weight was near zero. Value noise also sits near zero, so ±12 % read as about ±4 %.
- **LSZS high slope.** It lies under the cumulus shadow (cloud transmittance floor 0.12), which the foliage lift does not reach.

**Round 35 gain:** +0.04, the second round in a row under +0.2. The batch below is the structural change: the near band's look now comes from re-synthesised ground rather than photo mottle.

Round-36 batch:
1. **Near-ground re-synthesis (structural):**
   - Within about 700 m, photo luminance is held to ±25 % of the 30 m mean (±40 % farther out), and 60 % of the chroma comes from that mean. The 3–10 m blue-grey and white photo blotches take the ground's own hue.
   - The 4 m and 12 m patches are contrast-shaped, raised to ±20 % and ±16 %, and fade later. They also reach unroaded ground classed as pavement, at 60 %.
2. **Cloud shadow:** transmittance floor 0.25 (from 0.12) and a gentler falloff; fill light under the cloud raised from 0.35 to 0.42 of the sun.
3. **NZQN near lake:** the water body is modulated by wave facets toward or away from the sun (about ±28 %) and by ruffle; scattering is stronger where the water is ruffled.
4. **SkyWorld stubble:** straw (3.00/2.00/3.90; red over green 1.30), on CPU and GPU.

## Bold round 36: PR #6 92382be (run 43623273138, ultra tier)
Same reviewer and scale. **All scores unchanged:** finals 7.42, high frames 6.58, cockpit 6.75, SkyWorld 7.75.

Measured changes, all too small to move a score:
- **KBFI near band:** the blotch share (pixels brighter than 1.6× the band median) fell from 11.7 % to 10.5 %, and the ground reads slightly warmer and greener. KMRY looks the same as round 35.
- **4 m and 12 m patches:** still not visible.
- **LSZS high slope:** unchanged, a mean difference of 0.58 levels. Cloud shadow is ruled out.
- **NZQN near lake:** slight facet variation, but it still reads navy.
- **LSZS final:** brighter and more saturated (27.9). This is the ceiling; no further canopy lift.

This is the third round under +0.2. Guessing at lighting terms has stopped paying off, so round 37 adds instrumentation:
- `WorldRenderer.debugView` writes one shader term per channel, encoded so the tone map returns it unchanged (bloom, SSAO, grade and sharpening off):
  - **1:** albedo.
  - **2:** sun visibility, n·l and cloud shade.
  - **3:** near-ground patch term, ground-material weight and natural-class weight.
  - **4:** direct share, ambient share and irradiance relative to full sun.
- The showcase job saves `debug_LSZS_high_v1/2/4` and `debug_KMRY|KBFI_final_v1/3`, and prints region-of-interest means to the log.

Round-37 batch also includes, for the NZQN near lake:
- Wind streaks about 25 m across.
- Facet modulation ×2.6, clamped to 0.5–1.7.

## Round 37 debug views: PR #6 0d75d55 (run 43625224382)
Region-of-interest means, each channel a 0–1 term:

| View | Region | R | G | B |
|---|---|---|---|---|
| 1: albedo (sRGB) | LSZS high slope (x 700–1280, y 430–720) | 0.165 | 0.230 | 0.213 |
| 2: sun visibility / n·l / cloud shade | LSZS high slope | 0.50 | 0.65 | 0.50 |
| 4: direct share / ambient share / irradiance | LSZS high slope | 0.54 | 0.46 | 0.57 |
| 3: patch (0.5 = none) / ground weight / natural | KMRY near band (y 540–720) | 0.498 | 0.39 | 0.38 |
| 3 | KBFI near band | 0.501 | 0.66 | 0.65 |

Findings:
- **LSZS high slope:** it sits under the cumulus shadow at the transmittance floor (the blue-cyan region in view 2), over forest whose albedo is about 0.04 linear. Raising the floor from 0.12 to 0.25 still left only a quarter of the direct sun, which is why it barely moved. The reviewer's "not cloud shadow" was a guess, and it was wrong.
- **Near-ground patches:** they were present at full strength. The patch channel's standard deviation was 0.28–0.31 (patch ±15 %, saturating at ±0.25) over 41 % (KMRY) and 67 % (KBFI) of the band. They read as more of the photo's 5–20 m mottle, not as texture.
- **The missing piece is grass texture:** blue-grey lawn classified as pavement, so it never received grass texture at any scale the final camera resolves.

Round-38 batch:
1. **Ground classes:** 60 % now come from the ~30 m mean photo colour. A car park's mean stays grey; a lawn's reads green.
2. **Grass tufts:** a ~2.5 m octave (dense, darker tufts against paler ones) that fades by a 1.25 m footprint, two pixels per cell.
3. **4 m and 12 m patches:** cut back to ±10 % and ±8 %, on natural classes only.
4. **Cloud shadow:** transmittance floor 0.35.

Round-38 frames (52b2ef7, run 43626600606) before review:
- KBFI and KMRY near bands shifted only slightly.
- LSZS high irradiance went from 0.57 to 0.58 of full sun (view 4). The 0.35 cloud floor adds little because the slope's direct share in shadow is small.

Two more changes went into the same review round:
5. **Near band, green ground:** luminance is pulled 45 % of the way to the 30 m mean, so the grass material's texture replaces the photo's blotches.
6. **Higher toe beyond about 1.5 km:** target 0.13, exponent 0.5. On the LSZS high valley wall, 0.04 becomes 0.067. The near canopy keeps the 0.10 toe.

## Bold round 38: PR #6 38eed94 (run 43628077654, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.25 (7.0), LSZS 7.5, NZQN 7.25, SkyWorld 7.75. **Average 7.46**.

**High frames:** 6.58. **Cockpit:** 6.75.

**Landed:** KBFI near ground. The blotch share fell from 10.5 % to 5.3 %, and the lawn now reads as one coherent green surface. This is the first near-ground change in four rounds to move a score.

**No score change:**
- **KMRY near band:** pale roofs and roads, so the grass pull has little to act on.
- **LSZS high slope:** brighter (lower half 55.5 → 58.8) but still a near-black mass.
- **NZQN near-lake streaks:** not visible.
- **SkyWorld:** identical to round 36.

Round-39 batch:
1. **Valley haze on the real terrain** after the aerial table: toward the horizon sky colour, up to 30 % by about 10 km, scaled by the table's transmittance. The reviewer: a shadowed slope at 3–6 km needs in-scattered light, not more albedo.
2. **Water:** facet (±) and streak modulation now applies to the whole water colour, reflection included, not only the dark body.
3. **Green-ground luminance pull extended to cultivated and dry fields** at 80 % (KASE foreground).
4. **Tree crowns:** irregular outlines (a one-sided bulge of ±22 % and a two-lobed stretch of ±14 %, from the per-tree hash) and a crown-height spread of ±5 %. Shadows use the same shape.

Round-39 frames (0ef9aa9, run 43629348206) before review:
- The 30 % valley haze turned every real airport milky and cyan.
  - Lower-half brightness rose 6–20 levels; the y 200–400 contrast fell about 15 %.
  - LSZS final rose 55.8 → 62.1, past the ceiling the reviewer set.
- Haze retuned before review: none within about 800 m, at most 18 % by 6 km, toward a horizon colour desaturated by half.

## Bold round 39: PR #6 4bb4b9c (run 43630710363, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.25, KASE 7.75, KBFI 7.25, LSZS 7.5, NZQN 7.5 (7.25), SkyWorld 7.75. **Average 7.50**.

**High frames:** LSZS high 6.5 (6.25). **Average 6.65** (6.58). **Cockpit:** 6.75.

**Landed:**
- **Valley haze:** the LSZS high slope reads as a valley in cloud shadow, not a black mass. The 7–14 % loss of distant contrast is judged not a regression ("keep it about here").
- **NZQN near lake:** facets and streaks are visible on the whole surface colour.

**Did not show:**
- **Irregular crowns:** too subtle at ±22 %.
- **Field luminance pull:** KASE's fields are stretched by the grazing angle, not blotchy.

Round-40 batch:
1. **Crop rows on cultivated ground within about 1 km** (class from the 30 m mean colour):
   - Rows 3–6 m apart, ±10 %, in ~150×170 m parcels on axes rotated 0.35 rad.
   - Faded by the footprint across the rows.
2. **Crown outline and size:** bulge ±35 % and lobes ±20 %. Whole-tree size is now 0.72–1.28× from a second hash, and tree cell culling bounds widened to match.
3. **Per-tree tone:** brightness ±18 %, with a warm shift on about a third of trees.
4. **Valley haze on SkyWorld** as well as the real terrain.

## Bold round 40: a8f8287 (run 43632167796, ultra tier; merged with PR #6)
Same reviewer and scale.

**Final camera:** KMRY 7.5 (7.25), KASE 7.5 (7.75), KBFI 7.25, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.50**.

**High frames:** 6.65. **Cockpit:** 6.75. KMRY close 7.5 (7.25).

**Landed:** KMRY trees now differ clearly in size, outline and tone, and the suburb reads as mixed planting.

**Regression:** KASE final. The crop rows aliased into a fine 2–4 px diagonal hatch that read as a screen-door weave. No parcel grid was visible.

Round-41 batch:
1. **Crop rows:** shown only where the row spacing spans 8–14 or more pixels along the long footprint axis.
2. **Field patchwork:** each parcel has its own tone (±12 %) and a straw-to-green lean, with a 1–2 m darker margin.
3. **Wet shore:** land just outside the water mask is darker and cooler.
4. **Near-lake shallow tint:** strength raised from 0.6 to 0.8.

Round-41 frames (47c7956, run 43649602100) before review:
- **Crop-row hatch:** gone beyond the near band.
- **Parcel margins:** they drew straight dark lines across KASE's foreground that ignore the photo's own field edges, and the band darkened from 83.2 to 78.6.
- **Fix before review:** soft ~120 m tone patches (±12 %) and a ~160 m straw-to-green hue lean (luminance-neutral), with no parcel edges or margins. The rows keep their parcels, faded by pixel spacing.

## Bold round 41: PR #7 273690d (run 43650626794, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75 (7.5), KBFI 7.25, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.54**.

**High frames:** 6.65. **Cockpit:** 6.75.

**Landed:** the KASE crop-row hatch is gone.

**Did not show:**
- **Patchwork:** ±12 % noise patches were lost in the photo's own variation.
- **NZQN shore band and shallow tint:** both are under a pixel at the final camera's distance.

Round-42 batch:
1. **Field patchwork from the photo's own fields:**
   - A phase from the 30 m mean colour (near constant inside a field, changing across its edge) drives the patches.
   - ±22 % tone and a hay-to-irrigated hue lean, luminance-neutral.
2. **Mid-ring detail:** luminance octaves at about 60 m and 30 m (±16 %) from 0.8 to 15 km, faded by the footprint, for the high views.
3. **KBFI roofs:**
   - Rooftop plant density raised to 1 box per 250 m², up to 14.
   - Rows of low dark-glass skylights along the long axis of flat roofs over 900 m².

Round-42 frames (d0fa0f4, run 43651812034) before review:
- **Contour rings:** the sine phase of the mean colour drew rings over KASE's fields and slopes wherever the mean varied. This is a regression.
- **Mid-ring detail:** absent from the high frames (≤ 41k pixels changed). The long-axis footprint faded it out at grazing angles.
- **KBFI rooftop plant and skylights:** visible.

Fixed before review:
- **Field contrast:** each field's 30 m mean against the ~150 m mean around it, with that ratio pushed 80 % further (clamped to 0.75–1.35 per channel). Fields separate along the photo's own boundaries, with no bands.
- **Mid-ring fade:** now uses the geometric-mean footprint.

## Bold round 42: PR #7 1d4bc07 (run 43652804502, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5 (7.25), LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.58**.

**High frames:** 6.65. **Close:** KBFI 7.25 (7.0). **Cockpit:** 6.75.

**Landed:**
- **KBFI rooftop plant and skylights:** the blocks read as real buildings.
- **KASE field contrast:** partial. The lower half's contrast rose from 31.7 to 34.4, with no grid or rings, but it still reads as one smeared field.

**Did not show:** the mid-ring 30/60 m octaves are sub-pixel at the high camera's distances.

Round-43 batch:
1. **KASE field push:** the exponent goes from 0.8 to 1.4 where the 30 m / 150 m ratio is large (clamp 0.65–1.5). Boundaries sharpen while field interiors stay calm.
2. **Mid ring (high frames):**
   - Coarse 120 m and 240 m luminance octaves.
   - Field contrast from the photo's 150 m / 600 m mean ratio, pushed 60 % further (0.75–1.33).
3. **KBFI rooftop units:** a mix of mid-grey, white, pale tan and dark ducts.

## Bold round 43: PR #7 2a513dd (ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.58** (unchanged).

**High frames:** 6.70 (6.65); KASE high 7.0, its first rise above 6.75. **Cockpit:** 6.75.

**Main limit named:** on steep slopes the 10 m photo stretches down the fall line into streaks (KASE high right side, NZQN left hillside, LSZS slopes).

Round-44 batch:
1. **Steep-slope replacement (structural, after rounds 42–43 under +0.2):** where the photo's stretch 1/n.z passes ~1.6×, blend to procedural rock, scree and scrub, fully past ~2.6×.
   - Tinted from the photo's 150 m mean; 30 % of the photo's own luminance kept for exposure.
   - Fall-line octaves at 150, 40 and 12 m (footprint-faded) plus 60 m scrub patches.

Round-44 frames (d34d1f4, run 43655398099) before review:
- **Slope replacement did not fire:** at most 120 pixels changed per frame. The 1/n.z gate of 1.6–2.6× needs slopes past 51°; the smoothed DEM's slopes sit at 25–40°.

Fixed before review:
- **Gate:** the blend now runs from n.z 0.92 to 0.75, at most 80 %, keeping 45 % of the photo's luminance (clamped 0.7–1.4) so forest stands stay.

Round-44 frames (2facaf2 merged as 0d5cdc5, main run 43656475843) before review:
- **Slope blend fires:** pixels changed against round 43 — KASE final 49k, KASE close 61k, NZQN close 60k, LSZS high 27k, LSZS close 40k, NZQN high 15k, KASE high 6k. Mean luminance is unchanged.
- **KASE final cliff:** the smear reads calmer, as rock and scree.
- **KASE high right side:** barely changed. Those hills sit under the n.z 0.92 gate.
- **PR run 43656365406:** failed on a runner SwiftPM cache error in the LSZS frames job before any test ran. Main's run on the same tree is green.

## Bold round 44: main 0d5cdc5 (2facaf2; run 43656475843, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.58** (unchanged).

**High frames:** 6.70. **Cockpit:** 6.75.

**Slope blend:** a mild improvement where it fires, with no regressions. The KASE final cliff is calmer, with scree streaks down the fall line, but it has no hard rock structure.

**KASE high right side:** the streaks run along the contours, not down the fall line, so they are not photo stretch. The suspects are a coarse imagery layer magnified at a grazing angle, or terracing from the 23 m heights.

Round-45 batch:
1. **Debug views of KASE high** (ROI 800,480–1120,640):
   - View 1: albedo.
   - View 2: shading terms, to show height terracing.
   - New view 5: the finest imagery layer's metres per texel against pixel footprint and anisotropy.
2. **Rock outcrops in the slope blend:**
   - Thresholded 25 m noise gives crisp edges, widened with the footprint.
   - Rock is greyed, at ~55 % of the local mean's luminance.
   - A shadow line runs 5 m below each ledge.
3. **KASE field boundaries:** a faint dark line (−16 %, ~6 m wide) where the photo's 4 m-blurred luminance changes sharply over ±3 m. It applies only within the crop class and below a 3 m footprint.

Round-45 frames (b54375b, run 43660479024) before review — KASE high debug views (ROI 800,480–1120,640):
- **View 2 (shading):** smooth, with no bands. Height terracing is ruled out. ROI means: vis 0.80, n·l 0.83.
- **View 5:** imagery at ~6.8 m per texel (the z14 USGS mid layer, 4096 px over 28 km) under a ~2.2 m pixel footprint at 2.9× anisotropy. The photo is magnified ~3× at a grazing angle; its bilinear texels smear sideways into the contour-parallel streaks.
- **View 1 (albedo):** the streaks are already in the albedo.
- A z15 mid layer would need an 8192² texture; not taken.

Fixed before review (structural; rounds 42–44 under +0.2):
- **Magnified coarse photo:** where a layer of 3 m or more per texel is magnified past ~1.5×, keep its ~20 m mean colour and replace the texel detail with procedural detail.
  - Canopy: ridged 10 m crowns in 25 m stands. Open ground: 10/25 m patches.
  - Classed from the mean colour; 25 % of the photo's own deviation kept, up to 85 % blend.

Round-45 frames (d15e96f, run 43661627056) before review:
- **Pixels changed against round 44:** KASE high 158k, LSZS high 196k, NZQN high 123k, KBFI high 113k, KMRY high 45k; KASE final and close ~44k each. Other finals and closes are under 26k.
- **High frames:** 1–3 points darker in mean luminance (LSZS high 99.7 → 96.6).
- **KASE high:** the right-side foreground reads crisper and less melted.
- **LSZS and KBFI high:** gain slight texture.

## Bold round 45: PR #8 d15e96f (run 43661627056, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.5 (7.75), KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.54** (7.58). A regression.

**High frames:** 6.65 (6.70); LSZS high 6.25 (6.5). **Cockpit:** 6.75.

**What went wrong:**
- **Magnified-photo detail:** the KASE high smear survived. The 20 m mean was sampled anisotropically along the same axis, 25 % of the photo's deviation was kept, and the 10/25 m octaves were faded at this range.
- **Darkening:** the LSZS high right slope went back to near black. The 20 m mean skipped the photo's dark-ground toe lift.
- **Rock ledges:** thresholded isotropic noise drew swirling contour rings on the KASE final cliff.
- **Field boundary lines:** barely visible.

Round-46 batch:
1. **Magnified photo:**
   - An isotropic 20 m mean with the same toe lift.
   - Zero-mean 6/12 m octaves faded at 1.5 px per feature, clamped symmetrically (0.55–1.45).
   - 10 % of the photo's deviation kept, up to 90 % blend.
2. **Ledges:**
   - Ridged noise stretched 3:1 along the contour, broken by a 40 m mask into short outcrops.
   - Faded where an ~8 m band is under 4–8 px on screen.
3. **Cockpit:**
   - An upholstered door insert with a piped border, and a moulded crease under the sill.
   - A recessed inside door handle at the armrest front.
   - Carpet darker toward the firewall, with rubber heel mats.

Round-46 frames (ffcf2d1, run 43691350679) before review — lower-half mean luminance (round 44 / 45 / 46):
- KASE high 92.8 / 88.9 / 91.9
- LSZS high 63.7 / 57.7 / 61.9
- NZQN high 79.9 / 77.7 / 80.2
- KMRY high 89.9 / 88.9 / 90.0
- KBFI high 111.9 / 109.6 / 111.8
- KASE final 83.6 / 82.3 / 82.5

NZQN, KMRY and KBFI are back within 0.5 of round 44. LSZS high (−1.8), KASE high (−0.9) and the KASE final (−1.1) are still darker.

**Cause:** the ledge outcrops. A 0.78 threshold on ridged noise covers ~35 % of the masked slope, at 55 % luminance.

Fixed before review:
- **Outcrops:** threshold 0.92 (~13 %), rock at 65 %, a +6 % slope compensation, and shadow lines at −30 %.
- **Crown octave:** re-centred; ridged value noise averages +0.29.

Round-46b frames (0281a79, run 43692325823) before review — the outcrop change barely moved luminance (LSZS high 61.8, KASE high 91.7, KASE final 82.8):
- **Where:** a region map puts LSZS high's loss at the left lake shore (−12 output luminance in 160×90 cells) and along the shore below the town (−3 to −5). This is the coarse layer outside the near imagery.
- **Cause:** the "isotropic" 20 m mean took the footprint's long axis (tens of metres at grazing angles) and averaged in the lake and shaded forest.

Fixed before review:
- **Footprint:** geometric mean (area-equivalent) instead of the long axis.
- **Luminance guard:** the mean stays within −15 % / +18 % of the photo's own luminance at the pixel.

Round-46c frames (a4e5302, run 43693339251) before review — lower-half mean luminance (round 44 → 46c):
- KASE high 92.8 → 92.3
- NZQN high 79.9 → 80.1
- LSZS high 63.7 → 62.6
- KMRY high 89.9 → 89.9
- KBFI high 111.9 → 111.8
- KASE final 83.6 → 82.8
- KASE close 80.7 → 80.1

The LSZS left shore is still −7 to −9 locally, but the slope is no longer near-black. The KASE cliff shows no rings. Sent for review as round 46.

## Bold round 46: PR #9 a4e5302 (run 43693339251, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.58** (round 45's regression undone).

**High frames:** 6.70. **Cockpit:** 6.75.

**Not visible at review distance:**
- **KASE high smear:** no real change; the 6/12 m octaves are under 3 px there.
- **Cliff outcrops:** too faint at ~13 %.
- **Cockpit door and floor work:** outside the cockpit camera's view.

**LSZS high:** back to its round-44 look.

**Decision:** the KASE high mid-ring smear is accepted at 7.0. Four procedural rounds did not move it. The cause is the 6.8 m-per-texel z14 photo magnified ~3×, and only sharper imagery in that ring would fix it (a z15/z16 band; not taken now).

Round-47 batch:
1. **Cliff outcrops:**
   - ~25 % coverage (threshold 0.85) at 0.6× the local mean.
   - A lit upper rim (+45 %) and a shadow line below (−35 %).
   - They survive to ~3 px; slope compensation +12 %.
2. **Cockpit, where the camera looks:**
   - Mounting screws at each gauge's corners.
   - An engraved placard under each gauge.
   - Vinyl grain on the glareshield top (36×12 grid, ±20 %).
3. **KMRY flat roofs from the photo:**
   - Each roof its own grey (±15 %).
   - A soft knee above 0.28 luminance.

## Bold round 47: PR #9 1c63400 (run 43694637402, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.58**.

**High frames:** 6.70. **Cockpit:** 7.0 (6.75).

**What registered:**
- **Cockpit:** the placards and gauge screws land; the panel reads as a manufactured part. The glareshield grain read as soft blotches (minor).
- **KMRY flat-roof greys:** visible only side by side.
- **KASE cliff outcrops:** now visible, but as thin wavy contour hairlines (wood grain), not rock.

Round-48 batch:
1. **Outcrops as cellular blocks:**
   - ~25 % of jittered 22 m cells, with the contour axis stretched only 1.5:1.
   - A soft border from F2 − F1, so neighbouring blocks show cracks.
   - Lit rim and shadow bands at least ~2 px thick.
2. **Glareshield:** ±6 % grain on a ~1 cm grid, and a lengthwise sheen band along the crown.
3. **KMRY flat roofs from the photo:** ±25 % grey per roof.

Round-48 frames (beadb0b, run 43696082021) before review:
- **Cliff hairlines:** gone. The cellular blocks read as soft dark patches, and KASE final and close are 1.7–1.8 darker in lower-half luminance.
- **Glareshield:** smooth vinyl with a crown sheen; the blotches are gone.

Fixed before review:
- **Block edges:** border ~1 px (was 1.5 px).
- **Slope compensation:** +17 % (was +12 %).

Round-48b frames (21f6619, run 43697075735) before review:
- **Still darker:** KASE final is still 1.8 darker and KASE close 1.9 darker in lower-half luminance.
- **Where:** a region map puts the loss in the cliff cells (up to −14).
- **Cause:** the block colour came from the photo's 150 m mean, which takes in the dark forest round the pale cliff, not from the local rock.

Fixed before review:
- **Block colour:** 0.6× the local rock's own luminance.
- **Slope compensation:** back to +12 %.

Round-48c frames (4bd9240, run 43698505387) before review:
- **Still darker:** KASE final 80.9 (82.9) and close 78.1 (80.2); the cliff cells are still at −10 to −12.
- **Cause:** a bug in `outcropCells`. `fp_unit` reads the low 24 bits, so `fp_unit(h >> 16)` stayed under 0.004 and every cell passed the 25 % cover test. The cliff was 100 % rock.

Fixed before review: the per-cell choice now uses its own `fp_hash` seed.

Round-48d frames (31a446e, run 43699719058) before review:
- **Luminance:** back within 0.2 of round 47 everywhere (KASE final 82.8, close 80.1).
- **Swirls:** the cliff shows swirling contour rings, stronger than before.
- **Cause:** the cells and the rock octaves g0/g1/g2 were sampled in fall-line coordinates. Their axes turn with the normal from pixel to pixel, so curved slopes warp the pattern into swirls. The same warp drew the round-45 rings and round-47 hairlines.

Fixed before review:
- **Cells and octaves:** in world metres.
- **Rim / shadow offset:** only this still follows the fall line.

Round-48e frames (94cbf4a, run 43700909816) before review:
- **Swirls:** gone from the KASE cliff.
- **Outcrops:** faint polygonal blocks now show.
- **Luminance:** KASE final 82.0 (82.9) and close 79.3 (80.2); everything else within 0.2 of round 47. Sent for review as round 48.

## Bold round 48: PR #9 94cbf4a (run 43700909816, ultra tier)
Same reviewer and scale.

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 7.75. **Average 7.58**.

**High frames:** 6.70. **Cockpit:** 7.25 (7.0); the glareshield sheen registers.

**KASE cliff:** the hairlines and swirls are gone and the slope reads more naturally. The 22 m blocks (5–8 px, soft edges) read as stains, not rock.

**KMRY roofs:** ±25 % still does not register at 1×.

Round-49 batch:
1. **Outcrops:**
   - 35 m blocks at 0.5× the local rock.
   - Hard borders (under 1 px).
   - ~3 m rim (+55 %) and shadow band (−45 %).
   - Slope compensation +14 %.
2. **KMRY near band:**
   - Chroma pull toward the 30 m mean raised to 72 % (60 %).
   - A mild 20 % luminance pull on non-green, non-field near-band ground.
3. **SkyWorld:**
   - Grass darkens up to 16 % with slope, with a warmer tone on sun-facing slopes.
   - Farmsteads on every 5th rural-road point at 65 % (every 9th at 45 %), each with a small shed beside the house and barn.

### Round 49 frames (CI run 43702269615, before review)

All jobs green. Lower-half luminance against round 48e is within 0.4 everywhere.

**SkyWorld:** the frame is unchanged apart from 107 pixels on the horizon.
- The final camera looks across flat parcels, so the slope tone has nothing to act on.
- Farms are placed only along rural roads, and no rural road crosses those fields.

**KMRY near band:** changed by 0.05 levels on average. The stronger pull barely moves it.

Round-49b batch, added before review:
1. **SkyWorld farmsteads in the fields:** about one farmed parcel in six gets a house, barn and shed in a corner.
   - Laid out on the parcel axes.
   - Clear of hedgerows, roads, water and the runway approach.
   - Trees inside a farm footprint are dropped.
   - A test checks that each building sits inside a farmed parcel and off the approach.
2. **NZQN shallow shelf:** the water mask is averaged over rings 20 m and 40 m out (near layer only).
   - The shallows now reach 30–60 m from shore, instead of following the mask's one-texel rise.
3. **Cockpit:** an eyeball air vent above the two small gauges, with a chrome bezel, a ball nozzle and louvre slots.

## Round 49 review (r49b frames)

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.5, NZQN 7.5, SkyWorld 8.0 (7.75). **Average 7.63**, the first final at 8.

**High frames:** 6.70. **Cockpit:** 7.25.

- **SkyWorld farmsteads:** visible and give the patchwork scale. The barns are flat saturated red boxes with no yard, trees or track, and one group sits right under the aircraft.
- **KASE cliff blocks:** still read as soft dark stains.
- **KMRY lake shelf:** not visible.
- **Cockpit vent:** visible but tiny.
- **KMRY near band:** no change. Pulls toward the mean are exhausted; the reviewer asks for a structural material replacement.

Round-50 batch:
1. **Farmsteads:**
   - Weathered barn red, with grey or dark-green metal roofs.
   - A gravel yard, two or three trees and a track to the nearest hedge.
   - None within 300 m of the approach centreline.
2. **KASE outcrops:**
   - Cool-grey rock.
   - Rims +60 %.
   - Shadow bands at least 2 px wide.
3. **NZQN shelf:** rings at 40 m and 90 m, and a stronger turquoise tint.
4. **Cockpit:** the vent 1.5× larger, plus a second vent on the right.

### Round 50 frames (CI run 43705389095, before review)

All jobs green. Lower-half luminance against round 49b is within 0.6 everywhere.

- **SkyWorld:** both foreground farmsteads had disappeared.
  - The full-size yard had to clear the hedges, and the final-path exclusion covered 140 m either side.
  - Fix: the yard now shrinks to fit (or is dropped) instead of rejecting the farm, and the exclusion is 40 m either side of the centreline.
  - A probe shows a farmstead 300 m ahead of the aircraft, 107 m right of the path.
- **KASE cliff:** the cool-grey blocks with bright rims read as flat concrete quadrilaterals.
  - Fix: outlines are warped ±7 m at about 14 m, so blocks are ragged.
  - Faces vary ±25 % at 40 m and 12 m.
  - Block colour keeps a quarter of the local rock's hue.

## Round 50 review (r50b frames)

**Finals 7.63, high frames 6.70, cockpit 7.25: no change.**

- **SkyWorld farmstead:** reads as a farm now, and nothing sits under the tail. The barn walls are still fairly saturated, and the track doesn't show at this distance.
- **KASE outcrops:** discrete grey slabs that read as rock, but flat. No rim or shadow is visible at 1×.
- **NZQN shelf:** still invisible at the final range.

Round 49 gained +0.05 and round 50 nothing: two rounds under +0.2, so this round makes a structural change.

Round-51 batch:
1. **Structural: KMRY lawn replacement.**
   - On grass (and 30 % of dry grass), the near-band photo pixel is replaced, at 75 % weight, by a synthesised lawn.
   - Hue: the 30 m mean's, a third of the way to a lawn green.
   - Luminance: the pixel's own, held within ±12 % of the mean.
   - The procedural grass octaves carry the texture. Pavement, roofs and soil keep the photo.
2. **KASE slabs:** a 1.9× sun-side rim, a 0.4× down-slope shadow, and ±15 % variation between slabs.
3. **NZQN shore:**
   - A pale gravel band 15–25 m wide on flat land beside the near-layer water.
   - Near-shore water about 20 % lighter.
4. **Farmsteads:** more weathered barn walls, linear (0.26, 0.11, 0.09).

### Round 51 frames (CI run 43715660257, before review)

All jobs green. Lower-half luminance against round 50b is within 0.6 everywhere.

- **KMRY near band:** the lawn replacement moved only 0.16 levels.
  - The ground between buildings is pale grey with orange, sky-blue and green blotches 20–60 m across.
  - Those blotches are wider than the 30 m mean and classify as pavement, so neither the mean pulls nor the lawn replacement reach them.
  - Fix:
    - Blue-dominant near-band ground becomes a warm grey at its own luminance (the ~120 m mean too).
    - Half the near-band chroma comes from a ~120 m mean (a quarter on green ground).
    - A fixed chroma cap was rejected: linear grass sits near 0.7 chroma and would have gone grey.
- **KASE slabs:** bright top rims now show at 2×.

### Round 51b frames (CI run 43716986870, before review)

The chroma fix moved KMRY's near band by 0.07 levels (near-band saturation 0.258 → 0.251).

**Root cause, from debug view 1 (albedo):** the near-band albedo is already muted grey-green with mild orange.
- The final frame's sky-blue and orange blotches are lighting, not photo colour.
- The blue patches are soft tree and building shadows lit only by the blue sky ambient.
- The orange is warm sun on dry grass.
- Rounds 48–51 changed albedo, which is why none of them moved this band.

**Fix:** on photo ground the shadow-filling sky light keeps 55 % of its chroma, as an aerial camera's white balance renders it. SkyWorld's procedural terrain is unchanged.

### Round 51c frames (CI run 43718168874, before review)

The desaturated ambient cut KMRY's blue near-band fraction from 6.1 % to 4.5 %, and KBFI's from 7.4 % to 5.0 %. Luminance moved by 0.3 levels or less.
- Soft blue patches remain.
- The rest of the blue is the additive in-scatter over dark shadows.
- Fix: on photo ground, in-scatter keeps 60 % of its chroma within about 1.5 km, returning to full by 4 km so distant haze stays blue.

## Round 51 review (r51d frames)

**Finals 7.63, high frames 6.70, cockpit 7.25: no change.** This is the third flat round in a row.

- **KMRY and KBFI near bands:** slightly less blue, but they read the same.
  - The remaining blotches are 30–120 m colour cells.
  - At about 1 m per pixel the synthesised lawn does not read as lawn.
- **KASE slabs:** a mild regression. They read as smooth grey lozenges (puddles, stickers), and the approach has stalled for four rounds.
- **SkyWorld barns:** checked. The barn region did shift slightly, so the colour reaches the screen; the change was small.

Round-52 batch:
1. **Near band:** chroma from a ~400 m mean (65 % weight, half as much on green ground), so suburban ground reads as one coherent colour. Detail comes only from the procedural octaves and 3D objects.
2. **KASE:** slabs dropped. The round-46 world-space rock octaves stay.
3. **High frames:** extra haze beyond 5 km (up to +14 % by 14 km), with a cooler, less desaturated horizon colour.
4. **SkyWorld:** yards and tracks brighter.
5. **Forest clearings (LSZS foreground):**
   - `FieldPattern.clearing` marks about 22 % of 220 m cells with a 45–85 m meadow with a ragged edge. The world shader mirrors it operation for operation as `clearingMask`.
   - The shader paints meadow over the photo canopy there, and the real-world tree placement leaves the clearing open apart from about 6 % lone trees.
   - A test checks that clearings cover 2–15 % of the ground with soft edges.

### Round 52 frames (CI run 43721363610, before review)

All jobs green.

- **KASE cliff:** without the slabs, the cliff shows natural rock streaks.
- **KASE high:** the far ridges are cooler and separate in depth. The distant ground band is 5.8 levels brighter; other frames are within 2.
- **LSZS clearings:** none visible in the final frame, although a probe on the real LSZS region showed them working.
  - Clearings cover 5 % of the foreground, and only 171 of 46,159 trees stand in them.
  - At the camera's ~10° view, 15 m crowns hide about 85 m of ground behind them, so 45–85 m meadows disappear.
  - Fix: clearings are now 90–160 m across, in about 30 % of 420 m cells, with a ±20 m ragged edge.

### Round 52b frames (CI run 43722783527, before review)

- **LSZS clearings:** a 90–160 m clearing now shows in the LSZS foreground, but as a dark hole. LSZS final and close lost 2.2 and 4.3 levels.
  - Cause: the near-band tone compression pulled the meadow toward the dark forest's 30 m photo mean.
  - Fix: clearings are exempt from that pass, and the meadow is a sunlit alpine green, linear (0.13, 0.18, 0.065).
- **KASE close:** a pale meadow clearing reads acceptably at lower left.

## Round 52 review (r52c frames)

**Final camera:** KMRY 7.5, KASE 7.75, KBFI 7.5, LSZS 7.75 (7.5), NZQN 7.5, SkyWorld 8.0. **Average 7.67** (7.63). High frames 6.70; cockpit 7.25. KASE close fell from 7.5 to 7.25.

- **LSZS clearing:** works and reads as alpine valley farmland. The meadow is a flat, dark, uniform green.
- **KASE close clearing:** trees were removed, but the ground under them is the smeared forest photo. Some roadside trees went too.
- **KMRY near band:** no visible change. The remaining blotches are luminance cells, not chroma.
- **High-frame haze:** too subtle to see.

Round-53 batch:
1. **Clearing ground:**
   - Clearings apply wherever the ~100 m photo mean reads as forest, not only on canopy pixels, and stay off roads.
   - The grass is procedural: linear (0.15, 0.20, 0.07), ±10 % patches at about 30 m, and a 15 % darker forest-edge band.
2. **Near band:** ground luminance is held within ±8 % of a mean that blends the 30 m and 400 m means 40/60 (80 % weight on green ground, 50 % elsewhere).
3. **NZQN shore:** a gravel band 35 m wide at about 0.35 albedo, on slopes down to n.z 0.8.
4. **SkyWorld village:**
   - About 650 m right of the centreline near the threshold, so about 15° right of centre in the final frame.
   - Church: given a square west tower and pyramid spire (it used to be meshed as a plain box).
   - About 12 gabled houses with gable ends to a 300 m lane, plus garden trees.
   - It avoids existing buildings, and farmsteads, hedgerow trees and forest trees inside it are dropped.
   - A test keeps every village building more than 300 m off the runway axis.

### Round 53 frames (CI run 43726184614, before review)

All jobs green.

- **SkyWorld:** the frame is pixel-identical to round 52.
  - The village, 650 m right of the threshold, sat inside the forest on the right of the frame.
  - Fix: moved to 900 m before the threshold and 340 m right, open ground about 1.1 km ahead of the final start. The houses run outward from the church, spanning about 316–530 m from the axis.
- **KASE close:** the clearing now reads as grassy meadow rather than smeared photo.
- **Near band:** KBFI final is +2.2 levels and KMRY final +0.8 from the luminance hold. KMRY's colour blotches are still visible.

### Round 53b frames (CI run 43727861429, `34d4dfb`, sent for review)

All jobs green.

- **SkyWorld final:** the village is now in view at the forest edge right of the path (x ≈ 830–930, y ≈ 340–395): the church tower and about eight white houses with red roofs. It is small at this range; 678 pixels differ from round 52.
- Round 53 was sent to the art director with the four changes: clearing grass, the near-band luminance hold, the NZQN gravel shore and the SkyWorld village.

## Round 53 review (r53b): finals 7.67 (flat), high frames 6.70, cockpit 7.25

- KASE close is back to 7.5: the clearing reads as a grassy meadow.
- SkyWorld stays at 8.0. The village reads as a hamlet at 3×, but at 1× it is ~100×25 px.
- LSZS final has a new lime-yellow wedge below the tail (x 640–700, y 510–570). The rest of the meadow is a flat dark green.
- The KMRY and KBFI near band is unchanged on screen. The NZQN gravel band is not visible at final distance.

### Diagnosis

- **KMRY debug view 1 (albedo):** the 50–150 m yellow, orange and blue-grey blotches are present in the final ground albedo, so lighting is not the cause. Two passes after the near-band holds put them back:
  - The crop field-contrast pass classed the warm yard blotches as fields and pushed each one's 30 m mean up to 1.5× away from its 150 m surroundings.
  - The lawn replacement took its hue from the 30 m mean, which is the blotch's own colour.
- **LSZS wedge:** the clearing meadow was at ~0.18 albedo luminance against ~0.10 for the surrounding pasture, about 1.8× in output. Where the 100 m forest gate crossed open ground at the clearing edge, it drew an angular bright patch.

### Round 54 batch (structural round: two rounds under +0.2)

1. **Canopy relief (structural):** photo forest from 300 m out to ~10 km takes lit crown hemispheres on jittered ~10 m and ~28 m grids. They tilt the normal, so the sun lights one side and shades the other, with gaps between crowns 28 % darker. The relief fades with the pixel footprint. The aim is to replace the high frames' smooth magnified forest smear.
2. **Suburb score:** the mean of 13 road-mask taps out to ~130 m. It turns off the crop field-contrast pass, takes the lawn hue from the already-held albedo instead of the 30 m mean, and raises the 400 m chroma pull to 90 % and the ±8 % luminance hold to 90 % on suburban ground.
3. **Meadow:** ~0.12 luminance and less saturated, about 25 % above the pasture. The luminance hold no longer pulls pasture toward a forest-dominated 400 m mean.
4. **SkyWorld village:**
   - It moves to 1,450 m before the threshold and 190 m right, about 550 m ahead of the final start.
   - It grows to two streets (a main street running outward and a cross street along the approach), ~28 houses, a church at the crossroads and three barns.
   - The test now keeps village buildings more than 150 m off the axis.
   - `inside()` now bounds its early-out by the footprint size; a fixed 60 m cut ignored most of a 150 m lane.

### Round 54 frames (CI run 43734044812, `9004f61`), all green

- **SkyWorld final:** the village now reads at 1× in the right foreground: the church at the crossroads, two streets of houses with red roofs, and barns.
- **KMRY final:** the orange and yellow yard blotches are gone. The near band is an even pale grey-green under the 3D trees.
- **LSZS final:** the wedge is dimmer (output luminance 0.046 linear) but the pasture around it went darker (0.052 → 0.033). The pasture photo is dark enough that the 0.10 canopy class takes it for forest, so the canopy gap darkening landed on it. The whole frame is −1 level.
- **LSZS high:** the canopy relief shows on the sunlit forest at lower left, but the large slope on the right lies in cloud shadow, where normal tilt changes nothing.
- **Fix (`round 54b`):**
  - Canopy relief now starts at 900–1,600 m and needs photo luminance below ~0.06, so the final frames' pasture is untouched.
  - A sun-independent crown dome term (tops +10 %, rims −10 %) carries the relief into cloud shadow.

### Preset comparison frames (CI run 43737094439, `47bd7df`)

- KMRY and SkyWorld finals at low (phone detail), medium (tablet), high (desktop) and ultra.
- High and ultra show a clean KMRY near band. Low and medium still show the orange and yellow yard blotches.
- **Cause:** the bundled street pack keeps residential streets only within `buildingFullRadius × 0.6` of the field: 1.5 km at phone, 2.1 km at tablet. The final view's suburbs are 2–2.5 km out, so those tiers had no residential street ribbons and a road-density suburb score of 0.
- **Fix:** every street class is also kept within 1.5 km of the start view's foreground (1.5 km before the threshold), the same point the sharp imagery layer is centred on.
- **Round 54b check:** LSZS pasture stayed at 0.033, so canopy relief was not the cause. The forest-aware luminance target had also classed the dark pasture's 400 m mean as forest, which removed round 53's lift. That gate is reverted. The round-54b ultra frames are otherwise as intended.
- **Round 54c (`a7f1e7c`):**
  - KMRY low and medium presets are now clean, with street ribbons and no yard blotches, matching high.
  - The LSZS "pasture" stayed at 0.033. A round-54/53 luminance ratio map shows a smooth patch shaped like the clearing, with no crown texture. It is clearing meadow at partial weight: the 100 m forest score is ~0.5 there, so the ground was half photo, half meadow, and the wedge was the only spot at full weight.
  - **Fix:** a saturating forest gate (smoothstep 0.1–0.45) makes the meadow even, at ~0.145 luminance, about 25 % above round 53.

## Round 54 review (r54d): finals 7.75 (+0.08), high frames 6.70, cockpit 7.25

- LSZS final 8.0: the lime wedge is gone and the even sunlit meadow reads as an alpine clearing, though it has no internal variation.
- SkyWorld 8.25: the village reads at 1×.
- Canopy relief (10/28 m) is not visible in the high frames. KMRY near band "unchanged":
  - A full-width crop shows the left half is clean now.
  - The right half, a campus with large buildings and few streets, keeps its blotches. The road-density suburb score is near zero there.

### Round 55 batch

1. **Suburb mask:** OSM building footprints are rasterised into the road mask as discs of their size.
2. **Meadow:** ±18 % patches at 25 m and 60 m, and a darker (−22 %), narrower forest-edge band.
3. **Canopy relief:** crown clusters at 18 m and 55 m, gap darkening 38 %, dome shading ×1.5, kept to a 40 m footprint.

## Round 55 review (r55): finals 7.75 (flat), high frames 6.70, cockpit 7.25

- No change moved a score; every frame changed by under 0.6 levels.
- **Diagnosis, KMRY:** debug view 1 (albedo) shows even grey-green ground on the campus (x 640–1280, y 540–720). What remains in the final frame is lighting (tree shadows and ambient), not albedo, so the near-band holds stop here.
- **Diagnosis, high frames:** the LSZS high camera is 6 km before the threshold. The smeared slope is 3–5 km before it, outside the ultra tree disc (4.2 km), and beyond the near imagery square (3.2 km), where tree placement found no photo at all.

### Round 56 (structural)

- Ultra trees reach 6.5 km (cap 650,000).
- Beyond the near square, tree placement samples the mid imagery layer (~6.8 m/px at ultra), so forest stands on the high views' slopes get 3D trees.

## Round 56 review (r56): high frames 7.15 (+0.45), finals 7.75, cockpit 7.25

High frames, round 55 → round 56:

| Scene | r55 | r56 | Note |
|---|---|---|---|
| KASE | 7.0 | 7.75 | "Like a commercial sim at this altitude" |
| LSZS | 6.5 | 7.25 | |
| KBFI | 6.75 | 7.25 | |
| KMRY | 6.75 | 7.0 | |
| NZQN | 6.5 | 6.5 | 41k trees; tussock slopes have no forest class |

- **Remaining:**
  - Far stands in cloud shadow on the LSZS high slope read as sunlit lime clumps. Foliage multiplies ambient by 1.6 and adds +40 % in shadow, and under a cumulus that ambient already carries the cloud's sunlit fill, so crowns took ~2.2× the light of the ground under them.
  - Abrupt edges at the ring.
- **Round 57:**
  - Both foliage boosts fade out under cloud shadow.
  - Tree density fades over the outer 15 % of the disc with a ~400 m noisy edge (the final-approach disc is untouched).

### Round 57 frames (CI run 43749542746, `455a792`), not sent for review

- **LSZS final and close:** −9 levels. Removing the foliage boosts under cloud darkened the near forest, which lies under a cumulus, and the round-54 8.0 frame depended on it. The far lime clumps on the high slope barely changed.
- **Every ultra frame:** shifted 2–5 levels in absolute difference. The ring fade drew an extra value from each tree's random stream, which reshuffled heights, species and tints.
- **Fix (57b):**
  - The foliage change is reverted.
  - The fade uses its own hash.
  - Trees placed from the mid layer take a 0.065 albedo floor (0.10 before). The clumps were an albedo mismatch, 0.10+ crowns on ~0.04 photo forest, not a lighting one.

## Round 57 review (r57b): high frames 7.20 (+0.05; LSZS high 7.5), finals 7.75

- The far stands at LSZS now read as shaded forest on the slope.
- The slope between stands is still smooth dark photo: the mid-layer classifier missed ~0.04 shaded forest, whose colour margins vanish.

### Round 58 batch (ultra)

1. Mid-layer forest placement accepts dark (<0.075), non-blue photo on slopes over ~7°.
2. Scrub class: sparse 2–4.5 m bushes on steep (>14°), warm tan or olive photo where the forest score is near zero (NZQN tussock, KASE sage). It uses its own hash, so forest trees are unchanged.

### Round 58 frames (CI run 43752698370, `2a7193a`), not sent for review

- Pixel-identical to round 57b except NZQN (+4k trees).
- **Cause:** both new rules used linear thresholds, but tree placement samples the mosaics as sRGB bytes ÷ 255. The ~0.04-linear shaded forest is ~0.22 in sRGB, and tan tussock is ~0.4–0.6.
- **Fix (58b):** dark-forest rule at l < 0.30 sRGB; scrub at l 0.25–0.62.

### Round 58b frames (CI run 43754171517, `99809e1`)

Tree counts: LSZS 650k (capped), KASE 650k (capped), NZQN 116k (+70k scrub), KMRY 528k, KBFI 415k.

- **LSZS high:** changed by only 0.27 levels. With the new dark-forest stands it hit the 650k cap, which thins by distance to the nearest focus, so exactly the far-slope trees were dropped.
- **NZQN high:** sparse scrub on the left hills. The purple shadowed slope at lower left stays bare: its photo is blue-shifted in shadow.
- **Round 58c:**
  - Ultra cap 1,000,000 (~64 MB of instances; ultra has no budget).
  - Scrub density 0.35 (was 0.22).

## Round 58 review (r58c): high frames 7.25 (+0.05; NZQN high 6.75), finals 7.75

- **NZQN:** the scrub adds bushes on the ridge and shore.
- **LSZS:** the dark-forest fill is not visible.
- **Most wrong patch:** the NZQN high left slope (x 0–260, y 280–720), smeared photo with a strong purple-blue cast.
- **Round 59:**
  - Blue-dominant land photo beyond 0.7–1.5 km is pulled 75 % toward a warm neutral at its luminance; the near band has done this since round 51.
  - The photo-ground in-scatter keeps 85 % chroma by 6 km (was 100 % by 4 km).
- **Round 59 result:** NZQN high unchanged. The purple slope is ~400 m out (inside the 0.7 km start) and has r ≈ b > g, so the `b > 0.9·r` test never fired.
- **Round 59b:** the blue/purple neutral applies at any distance on land, and both tests use `b − max(0.85·r, g)`. NZQN high debug views 1/2/4 added to find the cause if it persists.
- **Round 59b result:** NZQN high unchanged (purple fraction 0.45 → 0.446). Debug views 2 and 4 show the slope fully sunlit and lit mostly by direct sun, so the cause is not ambient. Debug view 1 shows the final albedo at ~(63, 66, 68) sRGB, a blue excess of ~0.003 linear, which the absolute 0.03 ramp scaled to ~3 % strength.
- **Round 59c:** both blue tests are relative to the blue channel, `(b − max(0.85·r, g)) / b` over 0–0.06, with a 90 % pull beyond the near band.
- **Round 59c result:** NZQN high slope purple fraction 0.55 → 0.43 (vs r58c), b down ~2 levels; KASE/LSZS within 0.4 levels (no orange rock). Debug view 1 still b > g in 70 % of slope pixels.
- **Round 59d:** the magnified-photo pass (90 % toward the raw photo's 20 m mean) and the per-channel mid-ring ratio restore the cast after the neutral, so the neutral runs again after the detail passes.
- **Round 59d result:** fixed. NZQN high slope purple fraction 0.55 → 0.003; mean (54.7, 57.2, 59.8) → (58.4, 57.3, 49.6), olive-brown; debug view 1 albedo b > g in 0 % of pixels (was 70 %). Every other frame within 0.8 levels mean; SkyWorld identical. Sent to the reviewer as round 59.

## Round 59 review (r59d): high frames 7.30 (+0.05; NZQN high 7.0), finals 7.75, cockpit 7.25

- **NZQN high:** purple gone; the slope is now a dark, flat brown-olive smear ~25–30 % darker than the tan hills above, still the most wrong patch.
- **Round 60:**
  - Neutralised blue/purple land lifted 35 % with tussock: tan to olive by a 40 m noise, ±15 % at 6/14 m.
  - Scrub placement also accepts grey-to-purple photo (b 0.85–1.2·g, r ≥ 0.8·g, l 0.18–0.45 sRGB) on steep ground.
  - SSAO floor 0.7 and near-cascade PCF taps 1.6 texels apart (KMRY/KBFI near-band lighting blotches).
  - Pitched photo roofs 55 % toward a roofing palette (dark iron, charcoal, terracotta, red iron, pale sheet, slate green).
- **Round 60 frames (d88bf8d):**
  - NZQN high slope (x 0–300, y 300–720) went (69.8, 67.8, 58.5) → (75.6, 73.3, 60.7). NZQN has 200k trees.
  - NZQN roofs now visibly mixed: terracotta, red and dark iron.
  - KMRY/KBFI near band moved only 0.2–0.5 levels from the AO floor and PCF.
  - SkyWorld unchanged. Sent to the reviewer.

## Round 60 review (r60): high frames 7.40 (+0.10; NZQN high 7.5), finals 7.75, cockpit 7.25

- **NZQN high:** the slope now reads as dry tussock with scattered scrub, still darker than the sunlit hills above. Roofs read as natural, not confetti; a few NZQN reds pop.
- **SSAO floor and PCF:** no visible change.
- **Most wrong patch:** KMRY final's near band (y 560–720), blotchy ochre and blue-grey ground.
- **Round 61:**
  - KMRY/KBFI final debug views 2 (sun visibility) and 4 (direct/ambient split), to tell tree shadows from tint.
  - Tussock lift 1.35 → 1.55, with ridged 35 m gully lines (up to −18 %).
  - Roof reds toned down and ~2/7 of the mix.
  - High preset (desktop) trees to 4 km and a 180k cap (was 3 km and 75k).
- **Round 61 frames (7ee211a):**
  - GPU frame-time step green, with the high preset trees at 4 km.
  - NZQN high slope (75.6, 73.3, 60.7) → (77.8, 75.4, 62.2).
  - KMRY near-band diagnosis (y 560–720):
    - Correlation of luminance with sun visibility is 0.47, and with albedo 0.45.
    - Shadowed ground is 37 against 103 lit, and bluish (blue−red +4 against −15 lit).
    - Debug view 1 shows the photo's baked tree shadows as dark smudges on lit ground with no 3D tree.
  - Two causes, two fixes (round 61b):
    - A warm sun-coloured fill of 12 % in cast shadows on photo ground.
    - The near-band luminance hold tightened on the dark side (−8 % → −4 %).
- **Round 61b result:**
  - KMRY shadow/lit luminance 0.36 → 0.42; shadow blue−red +4.1 → 0.0.
  - KBFI shadow/lit 0.37 → 0.41; shadow blue−red +4.5 → +1.8.
  - Frame diffs 0.5–0.8 levels.
  - The photo's baked smudges on KMRY's left third are still faintly visible.
  - Sent to the reviewer as round 61.

## Round 61 review (r61b): finals 7.79 (+0.04; KMRY final 7.75), high frames 7.40, cockpit 7.25

- **KMRY near band:** acceptable at last. Shadows neutral and warm, and the campus reads as one dry-grass surface. Leave the left-third photo smudges.
- **Most wrong patch:** KBFI final's lawns (x 200–1100, y 500–720), a 40–80 m cloudy mottle with no grass structure.
- **Round 62:**
  - Green ground leans on the 400 m mean (60 → 85 %), held within ±5 % at up to 92 %.
  - 9 m mowing stripes (±3.5 %), one direction per ~200 m block, faded by pixel footprint.
  - Ultra building radius 9.5 → 12 km, full detail 6.5 → 9 km (KMRY high's town at 2–6 km).
  - High-preset frames to go to the reviewer.
