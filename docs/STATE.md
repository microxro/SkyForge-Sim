LAST_UPDATE: 2026-11-09T07:42:39Z

# SKYFORGE state

## Phase
Bold Mode (docs/BOLD_MODE.md) is in progress.
- Done (CI-verified unless noted):
  - A real-world showcase airport (KMRY, offline tile pack) is the default start. Six packs are bundled; any OurAirports airport streams after a prompt; SkyWorld is the fallback.
  - Imagery grading and a feathered seam.
  - Near layer centred toward the approach; near/far height blend.
  - OSM runtime client and meshes. Unit-tested; OSM is unreachable from the build environment, so no showcase pack carries OSM yet (ADR-0016).
  - HDR scene buffer with bloom, SSAO (CI compile pending), water waves and foam, prop disc (CI pending).
  - Tier render presets and the CI GPU frame-time test, run alone in its own CI step. All tiers are within budget on the CI virtual GPU (run 42531565329): KMRY high 16.11 ms and SkyWorld high 12.41 ms against 16.7 ms. Device numbers are unverified.
  - Sharp z17 approach imagery for US airports (ADR-0017); depth-aware FXAA.
  - Art rounds on Metal frames: 3.83, then 4.08. Review frames now 1280×720.
  - 30-minute soak test.
- Fixed 2026-11-08: broken showcase Metal frames. Causes: (1) the CI GPU assembled real-terrain chunks wrongly with `baseVertex`/`baseInstance`; now absolute indices and buffer offsets (debba5b); (2) imagery grading crushed shadows (41a9679); (3) the colour water classifier flagged shadowed slopes, roofs and asphalt (f9824ad: slope, area and runway filters). Frame-time tests now run alone in their own CI step (873eaf5).
- 2026-11-09 art rounds 5–10 on CI Metal frames:

  | Round | Score |
  |---|---|
  | 5 | 5.00 |
  | 6 | 5.17 |
  | 7 | 5.25 |
  | 8 | 5.50 |
  | 9 | 5.54 |
  | 10 | 5.58 |

  - What landed:
    - Tree distance LOD and outer-cascade shadow limits. All tiers were within budget on run 42553332470: SkyWorld high 15.1 ms, KMRY high 11.2 ms.
    - Dense 3D trees on photo canopy, including over the final approach's foreground.
    - Crown colour clamps.
    - Hipped roofs.
    - Stucco walls.
    - Cloud-shadow fill.
    - Colour grade.
    - Aircraft livery.
  - ADR-0019: the review-camera ground is limited by the imagery source, not by magnification.
  - Round-11 batch (fbb647f), then a frame-time fix (52a48d2) after SkyWorld high reached 17.15 ms.
- Open:
  - Procedural building fallback where OSM is missing; cascades 3–4; aircraft textures; cockpit textures; cloud self-shadow tiers.
  - Art review of the CI Metal frames (target ≥ 8).

P0 accepted (CI fully green). P1 in progress: P1.1, P1.2, P1.2b-2, P1.4, P1.7b, P1.8b, P1.9, P1.10, P1.12, P1.5, P1.6a, P1.2b-1, P1.6b, P1.7, P1.8a, P1.11 done; P1.3 renderer done with visuals below target (independent art review 6.00/10 vs commercial sims after 11 rounds; open: per-pixel land cover, tree crowns, impostors).

## Environment facts (recorded at session start)
- Host: Linux x86_64, Ubuntu 24.04.5 LTS, 4 CPUs, 15 GB RAM (Claude Code on the web sandbox).
- Swift: 6.3.3-RELEASE installed by `tools/setup_env.sh` into `~/.skyforge-toolchain` (download.swift.org reachable).
- No Mac, no Xcode, no Metal device. Apple-only code is author-only until CI or Mac day.
- GitHub: `gh` CLI present but GitHub access goes through the session's GitHub tools; the GitHub MCP plugin failed to connect at session start (proxy 403). Pushing over git works through the session proxy.
- Workflow push permission: allowed (ci.yml pushed). CI results are readable through the session's GitHub tools. PR: https://github.com/microxro/SkyForge-Sim/pull/1 (draft).
- Branch: work happens on `claude/ecstatic-davinci-tjahz4` (the branch this session is required to use), not `skyforge/main-build`. See ADR-0001.

## Auto-resume
- Project hooks installed in `.claude/settings.json` (SessionStart, Stop guard, StopFailure, PreCompact).
- `autoContinueAtUsageLimit: true` is set in the session's user settings (`~/.claude/settings.json`); the user asked for this instead of a scheduled task, (ADR-0002).
- 2026-11-08: the user then explicitly asked for a scheduled task that sends "continue" every 5 hours; created as `trig_01VkukC5znseCkMfBGwFqndn` ("SKYFORGE continue pulse", cron `33 */5 * * *` UTC, bound to this session).
- PR #1 was merged by the owner at 2026-11-07T23:13Z (commit 50fdfb9). Follow-up work restarts the branch from main and goes into a new PR.
- PR #2 was merged by the owner at 2026-11-08T23:19Z (merge 67b7ddc). The branch restarted from main; follow-up Bold work goes into a new PR.
- Fallback: send the message "continue" to resume.

## What works (verified on Linux)
- `swift build` and `swift test` for SkyforgeKit (see VERIFICATION_LOG.md).
- SFMath: WGS84 geodetic/ECEF/ENU (<1 mm round trip over 10k points), quaternions, Xoshiro256/SplitMix64, gradient noise.
- SFAtmosphere: USSA-76 to 86 km within 0.1% of tables; CAS/TAS/EAS.
- SFSim: fixed-step clock (1/120 s, 8 substep cap), triple buffer.
- SFContent: SHA-256 content store with atomic install and corruption detection.
- SFPreview: PNG encoder; procedural app icon.
- SFSystems/SFSim: cascaded PID autopilot (roll/heading/track, pitch/VS/altitude, autothrottle) and a scripted autoland circuit (integration test).
- SFFlightModel: SF-1 Trainer 6-DOF RK4 at 120 Hz (480 Hz near ground), aero build-up with soft stall and post-stall, ground effect, piston/fixed-pitch thrust, spring-damper gear with brakes and nose steering, Newton trim. Tests: trim at 100 KTAS/3,000 ft (|VS| < 50 fpm over 10 s), stall speed within 3 kt of design, energy drift < 0.1 % / 60 s, stability signs, control sense, 10-min determinism hash, 1-hour fuzz finite, rest on ground, takeoff roll.
- Xcode project passes the Linux lint (`tools/lint_pbxproj.py`); Xcode 26.6 resolved the project and the local package in CI.
- SFTerrainCore: inflate/PNG decode, Terrarium, tile math, CDLOD.
- SFWorldGen + SFPreview: procedural regions and a parallel CPU renderer; previews of scenes (a)(d)(e)(f) in docs/previews (reviewed, avg 6.1/10).

- SFInstruments: pitot-static system (ASI lag, altimeter with Kollsman, VSI lag, blocked static/pitot), turn/slip from physics; steam six-pack and SF-1000 PFD rendered from the real FDM (docs/previews k, l).

- SFWeather `METARService`: live METAR from aviationweather.gov with memory+disk cache (10 min), stale fallback, coalesced requests (tests use a scripted transport only).

- Visual regression: `VisualRegression.check` against Tests/Fixtures/golden (bless with SKYFORGE_BLESS=1; failures write actual+diff PNGs to SKYFORGE_VISUAL_OUT, uploaded by CI).

- SFAtmosphere `SkyModel`: Hillaire 2020 sky (LUTs in ~0.25 s on 4 cores release), zenith transmittance within 0.6 % of analytic optical depth; previews m_sky_noon/golden/sunset/twilight.

- Quick Flight: `QuickFlightSession` flies headless (rest, touch takeoff, final, crash); Metal `WorldRenderer` frame (sky, terrain, objects, aircraft) verified offscreen in CI.

## What is unverified
- Quick Flight interactivity (touch/keyboard/gamepad in the running app), frame time and memory on real devices.
- RESOLVED 2026-11-08: GitHub's macos-26 runner exposes a Metal device. CI run 42441951368 ran `metalOffscreenSkyMatchesCPUReference` and it passed, so Metal shaders now execute and are verified in CI on every PR.
- SwiftUI `InstrumentCanvas`/`InstrumentDemoView`, `TouchFlightControls`, `BindingsView` and the CoreMotion `MotionTiltInput` compile only in CI; never run.
- SwiftUI screens and device tiers compile in CI but have never run interactively (Metal passes do run offscreen in CI).

- Real-world Quick Flight (KCOI): USGS/Sentinel-2 imagery terrain, water mask, instanced trees, culled chunks; Metal frame from fixture imagery in CI.
- Volumetric cumulus (Metal, half-res, depth-aware) matching the CPU reference in CI; cloud shadows; live METAR cloud cover at real airports.
- Cockpit view with live PFD texture and banking camera; sky pass rolls and uses the proper ENU→sky rotation.

## Broken
- Nothing known. Speckle fixed in f8afa50 (CI frame reviewed).

## Last green SHA
- ee36845 (CI run 42503914209: all jobs green; parcel grid, row relief, triplanar rock)
