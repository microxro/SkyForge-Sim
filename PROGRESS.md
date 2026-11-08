# SKYFORGE progress

Legend: [x] done and verified, [ ] not done. Unchecked items are not available in the app.

## CURRENT
- CURRENT: Bold Mode (docs/BOLD_MODE.md). Phase A: real-world airports by default.
- Next 3: A2 generalised airport region + showcase fixtures · A3 OSM buildings/roads · A4 imagery colour match

## Bold Mode (user directive 2026-11-08, docs/BOLD_MODE.md)
### Phase A — Real world first
- [ ] A1 Real-world airport is the default Quick Flight start (SkyWorld = offline fallback)
- [x] A2 Any OurAirports airport: USGS near / Sentinel-2 far / Terrarium DEM / water / trees; stream + cache; ancestor-tile fallback; SkyWorld fallback on failure
- [x] A2b Bundled showcase airports: KMRY, KASE, KBFI, LSZS, NZQN, KCOI (43 MB tile packs, SHA-256 manifests, offline load test)
- [ ] A3 OSM buildings (extruded footprints, height tags or default), roads; ODbL attribution; procedural fallback — runtime Overpass client, parser, meshes, trees avoid footprints, attribution done; procedural fallback and OSM in showcase packs pending (OSM unreachable from the build environment, ADR-0016)
- [x] A4 Imagery: USGS↔Sentinel-2 colour match, de-haze/contrast curve, feathered near/far seam, mipmaps + 8× anisotropic filtering
- [ ] A5 Real DEM relief with CDLOD morphing (no cracks/popping), per-pixel detail normals + micro-albedo on imagery
### Phase B — Renderer quality
- [ ] B6a Bloom + sun glare (energy conserving)
- [ ] B6b TAA or FXAA+SMAA by tier
- [ ] B6c Contact shadows / SSAO
- [ ] B6d 3–4 stabilised shadow cascades on high tier
- [ ] B7 Aircraft PBR textures (panel lines, rivets, registration), glint, prop disc blur, cockpit textures and lighting
- [ ] B8 Water: normal-mapped waves, sky/cloud reflections, shoreline foam from the water mask
- [ ] B9 Cloud self-shadowing quality per tier
### Phase C — Performance (measured)
- [ ] C10 CI GPU frame-time test per tier on the macOS Metal runner (numbers in VERIFICATION_LOG)
- [ ] C11 Building LOD + instancing, GPU culling where useful, texture streaming with memory cap, no main-thread stalls (measured)
- [ ] C12 60 fps high / 30 fps low targets documented; device numbers unverified until run on hardware
### Phase D — Correctness
- [ ] D13 Tests for every new feature (unit, GPU-vs-CPU parity, Metal smoke)
- [x] D15 30-minute soak test (simulated, KMRY offline pack, 22 km box across mosaics/tiles): no crash, no NaN, memory bounded (Linux: 125 → 114 MB)
- [ ] D16 Stub/dishonest-code audit at the end of each phase
- [ ] Done: art ≥ 8 on Metal frames (≥3 real airports + 1 SkyWorld), frame-time + soak pass, attribution + licence audit, PR before/after

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
- [x] P1.13 Real-world ground: SFImagery, KCOI region, Metal imagery terrain, culled chunks, instanced trees, app location picker (CI 42474288474)
- [x] P1.14 Volumetric cumulus: CPU reference, Metal half-res march (GPU≈CPU in CI), cloud shadows, METAR-driven layer
- [x] P1.15 Performance: SkyWorld spatial cells (frustum + per-cascade shadow culling), real terrain chunk culling, instanced trees, tiered cloud steps (device frame times still unmeasured)
- [x] P1.16 Cockpit view: 3D panel, live SF-1000 PFD, banking camera, chase/cockpit toggle (CI frame reviewed)
- [ ] P1.1b Optional JSBSim offline oracle comparison in tools/jsbsim_oracle/
- [x] P1.2 Terrain core: pure-Swift inflate + PNG decoder, Terrarium decode (verified on a real tile), Web Mercator tile math, bilinear height queries, CDLOD quadtree selection with morph ranges
- [x] P1.2b-1 Bundled global DEM baseline (11.7 MB, Terrarium z4 → 4096x2048 equirectangular, tiled zlib, SHA-256 manifest, on-demand decode)
- [x] P1.2b-2 Terrarium streaming + content-store cache (injectable transport) feeding CDLOD
- [ ] P1.3 CPU preview renderer (§8.6) with scenes (a) suburban golden hour, (d) forest and river, (e) coastline, (f) mountain valley — renderer done, 4 scenes rendered and reviewed (avg 6.2/10 after pass 2, aircraft in scene a); open until avg ≥ 8
- [x] P1.4 Biome model and first SkyWorld layers (procedural terrain recipes, rivers, street grid + rural roads, parcels, houses/warehouses/strip malls/farms, parking lots, Poisson-like vegetation) with determinism and placement tests
- [x] P1.5 Hillaire sky LUTs (Metal) + cascaded shadows + PBR aircraft (all verified on CI Metal, run 42445934343)
  - [x] P1.5a Hillaire atmosphere CPU reference (transmittance/multi-scattering/sky-view LUTs, sun disc, aerial perspective), previews m_sky_*, 7 tests
  - [x] P1.5b MSL compute port of the LUTs verified against the CPU reference on a Metal device (CI run 42443252872)
  - [x] P1.5c-1 Metal physical sky pass (sky-view LUT + sun disc) verified against SkyModel in CI; app sky preview uses it
  - [x] P1.5c-2 two-cascade sun shadows (CI frame reviewed) and P1.5c-3 GGX aircraft paint/glass
- [x] P1.6a OurAirports parsing (RFC 4180 CSV), airports/runways/navaids model, runway geometry checks, labelled synthetic 3° ILS, nearest airport, bearing/distance (Vincenty)
- [x] P1.6b-1 Visual runway generation (surface, shoulders, Annex 14 markings, designators) + terrain flattening; preview scene (j)
- [x] P1.6b-2 Bundled compact OurAirports snapshot (2.6 MB, pure-Swift inflate) + validated atomic updater with injectable transport (UI button pending P1.9 UI work)
- [x] P1.7 METAR parser (230 real fixtures + edge cases + 5k-case fuzz), METAR → WeatherState (wind NED, QNH, ISA deviation, clouds, power-law wind profile), offline procedural presets
- [x] P1.7b Live METAR fetch (aviationweather.gov, 10-min cache, stale-on-failure, injectable transport) — `METARService` actor, disk cache, request coalescing, 9 tests
- [x] P1.8a SFInput: axes/actions, bindings with modifiers/context/aircraft, dead zones, calibration, curves (linear/exponential/monotone spline), smoothing, layered profiles, conflict detection, schema-versioned JSON; GameController gamepad + keyboard adapter (compile-checked in CI)
- [x] P1.8b Touch yoke/throttle UI and CoreMotion tilt adapter; press-to-bind UI (logic in SFInput with 7 tests; SwiftUI/CoreMotion adapters compile-only until CI/Mac day)
- [x] P1.9 Basic PFD / steam gauges (SFInstruments: pitot-static/gyro model with lags and blockages, six-pack, SF-1000 PFD, CPU raster previews k/l, SwiftUI Canvas demo; Metal 2D path pending)
- [x] P1.10 Offscreen Metal visual-regression harness (ImageDiff MAE/SSIM, golden check with bless/candidate artefacts; OffscreenSkyRenderer vs CPU SkyReference oracle runs when a Metal device exists; CPU goldens for sky and instruments run everywhere)
- [x] P1.11 Scripted flight integration test: autopilot-flown 10-minute circuit (takeoff, climb, circuit, 3° approach, flare, landing, rollout) in calm air and an 8 kt crosswind; touchdown −252 fpm, stops on the centre-line

## P2–P5
See docs/MASTER_PROMPT.md §16. Not started.

- [x] P1.12 Quick Flight vertical slice (SFQuickFlight + Metal WorldRenderer + SwiftUI screen) — headless flight tests on Linux; offscreen Metal frame verified in CI run 42443928244; interactive use on a device unverified
