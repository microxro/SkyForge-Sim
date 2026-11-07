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
