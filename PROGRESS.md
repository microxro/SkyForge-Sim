# SKYFORGE progress

Legend: [x] done and verified, [ ] not done. Unchecked items are not available in the app.

## CURRENT
- CURRENT: P0.9 Open the pull request and record CI status
- Next 3: P1.1 SF-1 Trainer FDM core (6-DOF RK4, aero build-up) · P1.2 Terrain core (Terrarium decode, height query, CDLOD) · P1.3 CPU preview renderer scenes (a)(d)(e)(f)

## P0 Bootstrap
- [x] P0.1 Save master prompt to docs/MASTER_PROMPT.md
- [x] P0.2 Auto-resume hooks (.claude/settings.json, tools/hooks/*)
- [x] P0.3 tools/setup_env.sh (Swift 6.3.3 on Linux)
- [x] P0.4 State files (STATE, PROGRESS, DECISIONS, ASSUMPTIONS, VERIFICATION_LOG, VISUAL_LOG)
- [x] P0.5 SkyforgeKit package skeleton, all 17 modules + sfpreview, Linux build and tests green
- [x] P0.6 Minimal hand-written SKYFORGE.xcodeproj (objectVersion 77, synchronized App folder, local package) + Linux lint
- [x] P0.7 CI workflow (or docs/ci.yml.template)
- [x] P0.8 MAC_DAY.md, APPLE_API_LEDGER.md and remaining docs stubs
- [ ] P0.9 Pull request open; CI `apple` status recorded (green if readable)

## P1 Vertical slice with a visual foundation
- [ ] P1.1 SF-1 Trainer FDM at 120 Hz (trim, stall, energy, stability-sign, determinism, fuzz tests)
- [ ] P1.2 Terrain core: Terrarium decode, bundled global DEM baseline, height queries, CDLOD quadtree
- [ ] P1.3 CPU preview renderer (§8.6) with scenes (a) suburban golden hour, (d) forest and river, (e) coastline, (f) mountain valley
- [ ] P1.4 Biome model and first SkyWorld layers (roads, trees, simple buildings) in a test region
- [ ] P1.5 Hillaire sky LUTs (Metal) + cascaded shadows + PBR aircraft
- [ ] P1.6 OurAirports snapshot, runway generation
- [ ] P1.7 METAR parser (≥200 fixtures), wind/QNH, procedural weather fallback
- [ ] P1.8 Input: touch, keyboard, gamepad bindings
- [ ] P1.9 Basic PFD / steam gauges
- [ ] P1.10 Offscreen Metal visual-regression harness
- [ ] P1.11 Scripted flight integration test

## P2–P5
See docs/MASTER_PROMPT.md §16. Not started.
