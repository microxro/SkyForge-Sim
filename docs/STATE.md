LAST_UPDATE: 2026-11-22T16:30:00Z

# SKYFORGE state

## Phase
- 2026-11-22: gate fast green on `claude/stoic-gates-3stdhw` (250 tests, Swift 6.3.3 via tools/setup_env.sh); no code changes this session.
- 2026-11-14 (PRs #6, #7 and #8 merged; work continues on `claude/ecstatic-davinci-tjahz4` in a new PR): art rounds resumed after PR #5 merged.
  - Scores (ultra tier, same reviewer):

    | Round | Average of finals | Cockpit |
    |---|---|---|
    | 22 | 7.00 | 4.5 |
    | 23 | 7.04 | 4.5 |
    | 24 | 7.13 | 4.5 |
    | 25 | 7.17 | 4.5 |
    | 26 | 7.25 | 5.25 |
    | 29 | 7.25 | 5.5 |
    | 30 | 7.25 | 5.75 |
    | 31 | 7.33 | 6.0 |
    | 32 | 7.33 | 6.0 |
    | 33 | 7.33 | 6.0 |
    | 34 | 7.38 | 6.5 |
    | 35 | 7.42 | 6.75 |
    | 36 | 7.42 | 6.75 |
    | 38 | 7.46 | 6.75 |
    | 39 | 7.50 | 6.75 |
    | 40 | 7.50 | 6.75 |
    | 41 | 7.54 | 6.75 |
    | 42 | 7.58 | 6.75 |
    | 43 | 7.58 | 6.75 |
    | 44 | 7.58 | 6.75 |
    | 45 | 7.54 | 6.75 |
    | 46 | 7.58 | 6.75 |
    | 47 | 7.58 | 7.0 |
    | 48 | 7.58 | 7.25 |
    | 49 | 7.63 | 7.25 |
    | 50 | 7.63 | 7.25 |
    | 51 | 7.63 | 7.25 |
    | 52 | 7.67 | 7.25 |
    | 53 | 7.67 | 7.25 |
    | 54 | 7.75 | 7.25 |
    | 55 | 7.75 | 7.25 |
    | 56 | 7.75 | 7.25 |
    | 57 | 7.75 | 7.25 |
    | 58 | 7.75 | 7.25 |
    | 59 | 7.75 | 7.25 |
    | 60 | 7.75 | 7.25 |
    | 61 | 7.79 | 7.25 |

    KMRY final 7.75 at round 61 (near-band shadows warm-filled). Best scene: SkyWorld 8.25 (round 54, village beside the approach); LSZS final 8.0 (round 54, even clearing meadow); KASE final 7.75. Rounds 27 and 28 were regression checks only.
  - What landed:
    - One roof colour per building.
    - NaN-safe local tone compression.
    - Bloom guard against non-finite pixels.
    - Steep-slope relief on the photo terrain.
    - Conifer stand contrast.
    - Cockpit rework.
    - Water gated by slope.
    - Structural: a mid z12 height mosaic (`b051139`; z12 tiles in all packs through `tools/fetch_mid_heights.py`). Slopes 3–12 km out had been z10 blobs at about 156 m per sample.
  - High-frame average: 7.40 at round 60 (NZQN high 7.5: tussock slope, scrub, roof palette); 7.30 at round 59 (NZQN high 7.0, purple slope neutralised); 7.25 at round 58 (NZQN high 6.75 with scrub); 7.20 at round 57 (LSZS high 7.5 with the far-tree albedo floor); 7.15 at round 56 (3D trees to 6.5 km at ultra; KASE high 7.75); 6.70 at round 46 (6.65 at round 45; 6.38 at round 26). The KASE high mid-ring smear is accepted at 7.0: it is the z14 photo (6.8 m per texel) magnified ~3×, which only sharper imagery would fix.
  - Round 53 (7.67, flat; high frames 6.70; KASE close back to 7.5): clearing grass fixed KASE close, the village read well at 3× but was ~100×25 px at 1×, the LSZS meadow gained a lime wedge, and the KMRY near band did not move.
  - Round 54 (7.75; LSZS 8.0, SkyWorld 8.25; high frames 6.70, cockpit 7.25): the even meadow and the village landed. Canopy relief at 10/28 m and the KMRY campus blotches did not show on screen.
  - Round 55 (7.75, flat; high frames 6.70): buildings in the suburb mask, meadow patches and 18/55 m canopy relief each moved the screen by under 1 level.
    - KMRY debug view 1 (albedo) now shows even ground on the campus. The remaining blotches are lighting (tree shadows), so the near-band holds are done.
  - Round 56 (finals 7.75; high frames 7.15, up from 6.70: KASE 7.75, LSZS 7.25, KBFI 7.25, KMRY 7.0, NZQN 6.5): 3D trees to 6.5 km at ultra hid the mid-ring smear.
  - Round 57 frames (not sent for review):
    - The foliage cloud change darkened LSZS's final foreground forest by 9 levels, and the far lime clumps stayed.
    - The ring fade's extra random draw reshuffled every ultra tree.
    - Reverted the foliage change; the fade now uses its own hash.
  - Round 57 (finals 7.75; high frames 7.20, LSZS high 7.5): far stands now sit in the slope's cloud shadow.
  - Round 58 (finals 7.75; high frames 7.25, NZQN high 6.75 from scrub): the dark-forest fill at LSZS is invisible (dark trees on a dark slope). Ultra tree cap 1M.
  - Next: round-59 frames.
    - Blue-dominant land photo beyond ~1 km goes to a warm neutral at its luminance.
    - Photo-ground in-scatter keeps 85 % chroma far (was 100 %). The NZQN high left slope rendered purple.
    - Then KMRY near-band lighting and the NZQN town roofs.
Visual transformation (2026-11-10, PR #5, ADR-0021) is in progress; the Bold Mode summary below is the earlier baseline.
- Landed (CI-compiled): new SF-1 aircraft model with per-pixel livery, glass and clear coat; OSM-sourced 3D buildings with facade/roof shading (bundled `buildings.sfb`, ODbL); four shadow cascades; mid-distance imagery layer; 2x supersampling and sharpening in the ultra preset; exposure scale 0.45 with near-identity photo albedo; per-airport review-frame jobs.
- Landed 2026-11-10 (second batch): five tree species with ambient occlusion; rebuilt cockpit interior with cabin fill light; ESA WorldCover land cover grids in every pack (water at any distance); water shading (sky reflection, wind patches); tinted tower glass; fine cloud structure at ultra; magnification-aware local contrast on the ground photo; `LINZAerialProvider`.
- Landed 2026-11-10 (third batch): painted runway markings; OSM road ribbons with centre lines (`roads.sfr`, `RoadPack`); LINZ 0.1–0.3 m aerial tiles in the NZQN pack (z14–18, used by the region loader ahead of Sentinel-2); tinted tower glass; softer prop blur; `TriangleSoup.add` fix (first triangle's per-vertex fields were dropped).
- CI: run 42904058045 (`0799f6a`) all green incl. six per-airport frame jobs. `4c34428` (roads, LINZ tiles) is in CI (run 42920830841); read its NZQN, KBFI and KMRY frames next.
- Known limits (measured): US ground photo is about 1.6 m per pixel at source; no finer public-domain source is reachable from the build environment. No parity with MSFS is claimed.
- Next: read the run-42920830841 frames (road lines, NZQN aerial imagery, runway numerals); fix what they show; keep VISUAL_LOG current. PR #5 body is up to date and honest about limits.

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
  - Rounds 11–15: 5.88, 5.92, 6.00, 6.04, 6.04. Round 16 (structural: review frames also at the desktop/high tier): phone 6.04, high 6.08.
  - Round-17 batch (6a66ae6): quarter-resolution cloud reconstruction (high-tier checker), water minimum as an area (false ponds on the desktop layer), highlight knee and grade roll-off, SkyWorld relief.
  - Rounds 17–19 (phone / high): 6.21 / 6.42, 6.29 / 6.50, 6.42 / 6.71. High-tier KASE 7.25 and SkyWorld 7.0.
    - What landed: water texture test (false lakes on canopy), Bayer + exact-tent clouds at 1/3 resolution (high now matches phone sharpness), highlight shoulder and shadow toe, forest stands, SkyWorld hills.
  - Structural change (b10d6c3, phone rounds 18–19 under 0.2): photo trees and their baked shadows removed under the 3D trees (`ImageryDelighting`, push-pull inpainting) on the near, detail and in-flight detail layers.
  - The art reviewer stopped on its usage limit (resets 2026-11-14 09:00 UTC; ADR-0020). Rounds 20 (de-lighting) and 21 (crisper forest stands, in-field variation) are unscored, with regression checks only.
  - Two frame-time failures on CI (variance above 1 ms between runs) were fixed with real margin: high-tier clouds 22 steps / 3 light taps, outer tree shadows to 1 km, SkyWorld desktop trees 58k, full-mesh tree shadows within 200 m. Run 42725234508: SkyWorld high 15.11 ms, KMRY high 14.85 ms.
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
