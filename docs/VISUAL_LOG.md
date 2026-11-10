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
