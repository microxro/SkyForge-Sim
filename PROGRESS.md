# SKYFORGE progress

Legend: [x] done and verified, [ ] not done. Unchecked items are not available in the app.

## CURRENT
- CURRENT: P0.9 macOS CI green (app import fix pushed); then P1.3 visual passes
- Next 3: P1.6 OurAirports + runways · P1.8 input bindings · P1.2b bundled DEM

## P0 Bootstrap
- [x] P0.1 Save master prompt to docs/MASTER_PROMPT.md
- [x] P0.2 Auto-resume hooks (.claude/settings.json, tools/hooks/*)
- [x] P0.3 tools/setup_env.sh (Swift 6.3.3 on Linux)
- [x] P0.4 State files (STATE, PROGRESS, DECISIONS, ASSUMPTIONS, VERIFICATION_LOG, VISUAL_LOG)
- [x] P0.5 SkyforgeKit package skeleton, all 17 modules + sfpreview, Linux build and tests green
- [x] P0.6 Minimal hand-written SKYFORGE.xcodeproj (objectVersion 77, synchronized App folder, local package) + Linux lint
- [x] P0.7 CI workflow (or docs/ci.yml.template)
- [x] P0.8 MAC_DAY.md, APPLE_API_LEDGER.md and remaining docs stubs
- [ ] P0.9 Pull request open (done: #1, draft); CI `linux` green; CI `apple` failing on case collision, fix pushed

## P1 Vertical slice with a visual foundation
- [x] P1.1 SF-1 Trainer FDM at 120 Hz (trim, stall, energy, stability-sign, determinism, fuzz tests) — Linux verified; JSBSim oracle comparison still to do (P1.1b)
- [ ] P1.1b Optional JSBSim offline oracle comparison in tools/jsbsim_oracle/
- [x] P1.2 Terrain core: pure-Swift inflate + PNG decoder, Terrarium decode (verified on a real tile), Web Mercator tile math, bilinear height queries, CDLOD quadtree selection with morph ranges
- [ ] P1.2b Bundled global DEM baseline (≤ 25 MB, from Terrarium z4–z5) + tile streaming/cache
- [ ] P1.3 CPU preview renderer (§8.6) with scenes (a) suburban golden hour, (d) forest and river, (e) coastline, (f) mountain valley — renderer done, 4 scenes rendered and reviewed (avg 6.1/10); open until avg ≥ 8
- [x] P1.4 Biome model and first SkyWorld layers (procedural terrain recipes, rivers, street grid + rural roads, parcels, houses/warehouses/strip malls/farms, parking lots, Poisson-like vegetation) with determinism and placement tests
- [ ] P1.5 Hillaire sky LUTs (Metal) + cascaded shadows + PBR aircraft
- [ ] P1.6 OurAirports snapshot, runway generation
- [x] P1.7 METAR parser (230 real fixtures + edge cases + 5k-case fuzz), METAR → WeatherState (wind NED, QNH, ISA deviation, clouds, power-law wind profile), offline procedural presets
- [ ] P1.7b Live METAR fetch (aviationweather.gov, 10-min cache, stale-on-failure, injectable transport)
- [ ] P1.8 Input: touch, keyboard, gamepad bindings
- [ ] P1.9 Basic PFD / steam gauges
- [ ] P1.10 Offscreen Metal visual-regression harness
- [ ] P1.11 Scripted flight integration test

## P2–P5
See docs/MASTER_PROMPT.md §16. Not started.
