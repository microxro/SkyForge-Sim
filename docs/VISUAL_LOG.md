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
