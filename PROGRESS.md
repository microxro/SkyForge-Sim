# SKYFORGE progress

Legend: [x] done and verified, [ ] not done. Unchecked items are not available in the app.

## CURRENT
- CURRENT: P1.3 visual passes toward 8/10 (aircraft in frame, ground detail)
- Next 3: P1.9 gauges · P1.7b live METAR fetch · P1.8b touch/tilt + bind UI

## P0 Bootstrap
- [x] P0.1 Save master prompt to docs/MASTER_PROMPT.md
- [x] P0.2 Auto-resume hooks (.claude/settings.json, tools/hooks/*)
- [x] P0.3 tools/setup_env.sh (Swift 6.3.3 on Linux)
- [x] P0.4 State files (STATE, PROGRESS, DECISIONS, ASSUMPTIONS, VERIFICATION_LOG, VISUAL_LOG)
- [x] P0.5 SkyforgeKit package skeleton, all 17 modules + sfpreview, Linux build and tests green
- [x] P0.6 Minimal hand-written SKYFORGE.xcodeproj (objectVersion 77, synchronized App folder, local package) + Linux lint
- [x] P0.7 CI workflow (or docs/ci.yml.template)
- [x] P0.8 MAC_DAY.md, APPLE_API_LEDGER.md and remaining docs stubs
- [x] P0.9 Pull request #1 (draft) open; CI green on run 42421809423: Linux tests, macOS package tests, iOS Simulator and macOS app builds

## P1 Vertical slice with a visual foundation
- [x] P1.1 SF-1 Trainer FDM at 120 Hz (trim, stall, energy, stability-sign, determinism, fuzz tests) — Linux verified; JSBSim oracle comparison still to do (P1.1b)
- [ ] P1.1b Optional JSBSim offline oracle comparison in tools/jsbsim_oracle/
- [x] P1.2 Terrain core: pure-Swift inflate + PNG decoder, Terrarium decode (verified on a real tile), Web Mercator tile math, bilinear height queries, CDLOD quadtree selection with morph ranges
- [x] P1.2b-1 Bundled global DEM baseline (11.7 MB, Terrarium z4 → 4096x2048 equirectangular, tiled zlib, SHA-256 manifest, on-demand decode)
- [x] P1.2b-2 Terrarium streaming + content-store cache (injectable transport) feeding CDLOD
- [ ] P1.3 CPU preview renderer (§8.6) with scenes (a) suburban golden hour, (d) forest and river, (e) coastline, (f) mountain valley — renderer done, 4 scenes rendered and reviewed (avg 6.2/10 after pass 2, aircraft in scene a); open until avg ≥ 8
- [x] P1.4 Biome model and first SkyWorld layers (procedural terrain recipes, rivers, street grid + rural roads, parcels, houses/warehouses/strip malls/farms, parking lots, Poisson-like vegetation) with determinism and placement tests
- [ ] P1.5 Hillaire sky LUTs (Metal) + cascaded shadows + PBR aircraft
- [x] P1.6a OurAirports parsing (RFC 4180 CSV), airports/runways/navaids model, runway geometry checks, labelled synthetic 3° ILS, nearest airport, bearing/distance (Vincenty)
- [x] P1.6b-1 Visual runway generation (surface, shoulders, Annex 14 markings, designators) + terrain flattening; preview scene (j)
- [x] P1.6b-2 Bundled compact OurAirports snapshot (2.6 MB, pure-Swift inflate) + validated atomic updater with injectable transport (UI button pending P1.9 UI work)
- [x] P1.7 METAR parser (230 real fixtures + edge cases + 5k-case fuzz), METAR → WeatherState (wind NED, QNH, ISA deviation, clouds, power-law wind profile), offline procedural presets
- [ ] P1.7b Live METAR fetch (aviationweather.gov, 10-min cache, stale-on-failure, injectable transport)
- [x] P1.8a SFInput: axes/actions, bindings with modifiers/context/aircraft, dead zones, calibration, curves (linear/exponential/monotone spline), smoothing, layered profiles, conflict detection, schema-versioned JSON; GameController gamepad + keyboard adapter (compile-checked in CI)
- [ ] P1.8b Touch yoke/throttle UI and CoreMotion tilt adapter; press-to-bind UI
- [ ] P1.9 Basic PFD / steam gauges
- [ ] P1.10 Offscreen Metal visual-regression harness
- [x] P1.11 Scripted flight integration test: autopilot-flown 10-minute circuit (takeoff, climb, circuit, 3° approach, flare, landing, rollout) in calm air and an 8 kt crosswind; touchdown −252 fpm, stops on the centre-line

## P2–P5
See docs/MASTER_PROMPT.md §16. Not started.
