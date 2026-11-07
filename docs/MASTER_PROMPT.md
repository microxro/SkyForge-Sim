# SKYFORGE — AUTONOMOUS BUILD DIRECTIVE v3 (single source of truth)

## 0. MISSION AND PRIORITIES
Build SKYFORGE: a free, open-source (Apache-2.0), realistic global flight simulator for iOS, iPadOS and macOS. Native multiplatform, Swift 6 plus a custom Metal renderer.

Priority order for every decision: (1) it compiles and runs, (2) licence safety, (3) VISUAL QUALITY AND SHARPNESS, (4) SMOOTH PERFORMANCE (frame pacing), (5) simulation correctness, (6) breadth of features. Items 3 and 4 are the product. A simulator that flies correctly but looks soft, flickers or stutters has failed.

Deliverable: a repository the user opens in Xcode (`SKYFORGE.xcodeproj`) and builds and runs on iPhone, iPad and Mac with nothing beyond choosing a signing team. The repo contains only code plus open-source dependencies (vendored or Swift Package Manager, no accounts). NO API keys, NO S3 buckets of our own, NO paid services, NO accounts, NO secrets. All work goes to branch `skyforge/main-build` and ONE pull request.

**THE USER IS AWAY AND WORKING FROM AN iPAD.** You run in Claude Code on the web: a cloud Linux sandbox with no Mac, no Xcode, no Apple SDKs and no Metal GPU. The user reviews your pull requests from an iPad and will later move the code to a Mac with Xcode ("Mac day", §24). You are a fully autonomous engineering team. You never ask questions, never wait for approval, never stop to "check in". You decide, document, build, test, verify, fix and continue until the Definition of Done (§22) is met.

**BEAUTY IS THE PRODUCT.** The generated world and aircraft must look extremely beautiful: art-directed, cohesive, polished and sharp, and at its best BETTER than Microsoft Flight Simulator where authored consistency beats scanned data (no melted buildings, no stretched textures, no pop-in, flattering light everywhere, rock-steady frame pacing). All "AI-generated" content means algorithmic procedural generation in code; no external AI services, API keys or paid tools are ever used.

Step 0.1: save this entire prompt verbatim to `docs/MASTER_PROMPT.md` (if not already there) and commit it. Everything you need is in this document.

## 1. AUTONOMY RULES (non-negotiable)
1. Never ask the user anything. When a decision is ambiguous, pick the option that maximises compile safety, then licence safety, then visual quality, then performance. Record it in `docs/DECISIONS.md` as an ADR (context, options, decision, consequences). Record assumptions in `docs/ASSUMPTIONS.md`.
2. Work in small increments: plan → implement → build → test → self-review → commit → push. Commit only when the gates relevant to the change are green. Commit message format `[P<phase>.<item>] <summary>`.
3. Never fake functionality. No stubs that pretend to work, no hardcoded success, no placeholder UI presented as a feature. Unimplemented things show "Not yet available" or are hidden, and are unchecked in `PROGRESS.md`.
4. Never claim something works without a test or a logged verification. Never ignore compiler warnings in our code (CI greps for `warning:` in our sources).
5. Use subagents for parallel work (verification of APIs and licences, independent code review of a finished module, writing fixtures, visual-regression review). Verify every subagent result yourself before merging.
6. Self-review before each commit: no hallucinated Apple API (check SDK headers or docs); no force unwraps on external data; no blocking I/O on the main or render thread; licence recorded for any new dependency; tests added; for visual changes, a screenshot comparison logged.
7. If the repo is broken at session start, make it green first (revert your last commit if needed). If a subsystem proves unworkable, you may restart it; document why.
8. Persist everything in files, never only in conversation memory: `PROGRESS.md` (checklist, CURRENT item and next 3), `docs/STATE.md` (what works, what is broken, last green SHA, environment facts), `docs/DECISIONS.md`, `docs/ASSUMPTIONS.md`, `docs/VERIFICATION_LOG.md` (every gate run: date, command, result), `docs/VISUAL_LOG.md` (every visual milestone with screenshot paths and metrics). Update STATE.md before long operations and at least every ~30 minutes.
9. Do not stop until §22 is satisfied or every remaining item is classified as blocked by an external factor. Only then create `SKYFORGE_DONE`.
10. Context discipline: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=65` in `.claude/settings.json` asks Claude Code to auto-compact at about 65% of the context window (about 650k tokens only if the window is 1M; the setting is a percentage, and it is reported to only lower the default threshold, never raise it). Do not rely on it alone: if you can run `/compact` yourself, do so at natural breakpoints (end of a phase item, after a commit), and always write STATE.md and PROGRESS.md before long operations so compaction or a fresh session loses nothing. Never keep large files, logs or images in context longer than needed.
11. Reality over optimism: if a visual or performance target cannot be met on a device tier, ship the best honest result, record the measured gap in `docs/PERFORMANCE.md`, and keep improving in later passes. Never fake screenshots or numbers.

## 2. AUTO-RESUME PROTOCOL (install FIRST, before any feature work)
Verified Claude Code mechanisms (docs: code.claude.com/docs/en/headless and /hooks). Re-verify flags with `claude --help`.
- `claude -p "<prompt>"` runs non-interactively. `--output-format json` returns an object including `session_id`.
- `--continue`/`-c` continues the latest conversation in this directory; `--resume <session_id>`/`-r` resumes a specific one. Both work with `-p`.
- Hooks live in `.claude/settings.json`: `SessionStart` (matchers startup/resume/clear/compact) injects stdout as context; `Stop` can return `{"decision":"block","reason":"..."}` to force continuation; `StopFailure` (matchers incl. `rate_limit`, `overloaded`, `server_error`) fires on API errors (output ignored, command still runs); `PreCompact` fires before compaction.

### 2.1 `.claude/settings.json`
```json
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "65"
  },
  "hooks": {
    "SessionStart": [
      { "matcher": "startup|resume|clear|compact",
        "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/tools/hooks/session_start.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/tools/hooks/stop_guard.sh" } ] }
    ],
    "StopFailure": [
      { "matcher": "rate_limit|overloaded|server_error",
        "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/tools/hooks/on_api_failure.sh" } ] }
    ],
    "PreCompact": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/tools/hooks/pre_compact.sh" } ] }
    ]
  },
  "permissions": {
    "allow": ["Bash(swift *)", "Bash(git *)", "Bash(gh *)", "Bash(xcodebuild *)", "Bash(xcrun *)",
              "Bash(curl *)", "Bash(python3 *)", "Bash(./tools/*)", "Bash(sh tools/*)", "Bash(plutil *)"]
  }
}
```

### 2.2 Hook scripts in `tools/hooks/` (chmod +x, POSIX sh, no jq)
`session_start.sh`:
```sh
#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
echo "SKYFORGE AUTONOMOUS MODE. The user is away. Never ask questions. Priorities: compile, licence, VISUALS, PERFORMANCE. Re-read docs/MASTER_PROMPT.md sections 1, 2, 8, 22 if unsure."
echo "--- docs/STATE.md (head) ---"; head -n 60 docs/STATE.md 2>/dev/null
echo "--- PROGRESS.md current ---"; grep -n -A4 "CURRENT" PROGRESS.md 2>/dev/null | head -n 20
echo "--- last commits ---"; git log --oneline -n 8 2>/dev/null
echo "Next action: run tools/gate.sh fast, then continue the CURRENT item."
exit 0
```
`stop_guard.sh` (keeps the agent working; per-session cap lets the wrapper rotate sessions):
```sh
#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
mkdir -p .skyforge
[ -f SKYFORGE_DONE ] && exit 0
[ -f .skyforge/rate_limited ] && exit 0
n=$(cat .skyforge/stop_blocks 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > .skyforge/stop_blocks
if [ "$n" -gt "${SKYFORGE_MAX_STOP_BLOCKS:-60}" ]; then echo 0 > .skyforge/stop_blocks; exit 0; fi
printf '%s\n' '{"decision":"block","reason":"SKYFORGE is not done (SKYFORGE_DONE absent). The user is away. Update docs/STATE.md, run tools/gate.sh fast, commit if green, then continue the next unchecked item in PROGRESS.md. Do not ask the user anything."}'
exit 0
```
`on_api_failure.sh`:
```sh
#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
mkdir -p .skyforge
date -u +%s > .skyforge/rate_limited
cat >> .skyforge/api_failures.log
exit 0
```
`pre_compact.sh`:
```sh
#!/bin/sh
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
echo "$(date -u +%FT%TZ) compaction; last commit $(git rev-parse --short HEAD 2>/dev/null)" >> docs/VERIFICATION_LOG.md
exit 0
```
Add `.skyforge/` to `.gitignore` (keep `.skyforge/.keep`).

### 2.3 Resuming after usage limits on Claude Code on the web
Facts about this environment (confirm by observing your session): the web session runs in a cloud sandbox and keeps running if the user closes the app; there is no terminal wrapper you can rely on; when a usage limit is hit the session stops until it resets; a new session or scheduled run starts from a FRESH CLONE of the repo, so ONLY COMMITTED FILES SURVIVE. Therefore:
1. Persist everything in committed files (`PROGRESS.md`, `docs/STATE.md`, `docs/DECISIONS.md`, `docs/VISUAL_LOG.md`, ...). Commit and push at least every 20–30 minutes and before any long operation. Put `LAST_UPDATE: <ISO UTC time>` on the first line of `docs/STATE.md` at every update. The completion marker is the committed root file `SKYFORGE_DONE`.
2. The Stop hook keeps you working inside a session. It cannot defeat a usage limit.
3. Scheduled resume: in P0, if a scheduling tool is available in your session (a tool that creates scheduled or recurring tasks), create ONE recurring scheduled task named "SKYFORGE resume" for this repo, every 5 hours (the nearest offered interval if 5 hours is not available), with the resume prompt below. Record in STATE.md whether it was created and which approval mode it got; if its runs would stop for approvals, say so in `docs/PR_BODY.md`. If no scheduling tool exists, write in `docs/PR_BODY.md` and in the last message of every session: "To resume after a limit, send the message: continue".
4. Resume prompt: "Resume SKYFORGE. The user is away on an iPad. Read docs/MASTER_PROMPT.md sections 1, 2, 8 and 22, then docs/STATE.md and PROGRESS.md. Run git fetch. If the newest commit on origin/skyforge/main-build or the LAST_UPDATE timestamp is less than 20 minutes old, another session is active: exit immediately without changes. Otherwise check out skyforge/main-build, run tools/setup_env.sh, run tools/gate.sh fast and continue the CURRENT item. Never ask questions."
5. Never end a session by asking the user something. End with a status line: what is done, what is next. Nothing is required from the user. If SKYFORGE_DONE exists, do nothing.

### 2.4 `tools/setup_env.sh` (run at the start of every session, not inside hooks, which have time limits)
Create a script that exits 0 if `swift --version` reports ≥ 6.2; otherwise installs the Swift toolchain for the sandbox distro and architecture from /etc/os-release and `uname -m`, following https://www.swift.org/install/linux/ (swiftly, or the tarball under download.swift.org), updates PATH and re-checks. It needs network access to download.swift.org, swift.org and github.com. If blocked, record "Swift unavailable: author-only mode" in STATE.md, tell the user in `docs/PR_BODY.md` to add those domains in the environment's network settings, and keep authoring code and docs carefully.

## 3. ENVIRONMENT, VERIFICATION LAYERS AND MAC DAY
At every session start record in STATE.md: `uname -s -m`, `swift --version`, which GitHub tooling works (gh, any GitHub tools in the session, or the API via curl), and whether pushing files under `.github/workflows/` is allowed.

Verification layers (use all that are available and log each run in VERIFICATION_LOG.md):
- **L1 Linux**: `swift build` and `swift test` for every pure-Swift target (math, FDM, atmosphere, weather, nav, terrain CPU, WorldGen, storage, input, ATC, preview renderer).
- **L2 CPU preview renders (§8.6)**: PNG images made by a pure-Swift software renderer of the same generated world. You LOOK at them (read the PNGs) and critique them. This is your primary visual verification for content and beauty.
- **L3 GitHub Actions macOS CI**: compiles iOS and macOS, runs Apple tests, uploads renders. Trust it only if you can read its results.
- **L4 Mac day (user, §24)**: real Xcode build, GPU look, device profiling.

Compile-risk controls for Apple-only code that you cannot compile here:
- Keep Apple-only code small, isolated in `#if canImport(...)` files, and in boring, long-stable APIs (MTKView, MTLDevice/CommandQueue/RenderPipeline, SwiftUI basics, GameController, AVAudioEngine).
- Maintain `docs/APPLE_API_LEDGER.md`: every Apple API used (framework, symbol, minimum OS, documentation URL, status verified/unverified). Verify against documentation whenever you can reach it.
- Before committing an Apple-only file, have a fresh subagent act as the Swift compiler (types, optionality, actor isolation, Sendable, availability, missing imports) and log the result.
- No clever generics, macros or result builders beyond SwiftUI basics.
- Honesty: first-try Xcode success of never-compiled Metal and SwiftUI code cannot be guaranteed. The goal is to minimise errors and make Mac day fast.

CI access:
- Try `gh`, then any GitHub tools in the session, then the GitHub API via curl. If one works, use the draft-PR + CI loop: push, wait, read failures, fix, repeat.
- If pushing `.github/workflows/ci.yml` is rejected (the token may lack workflow permission), keep the file at `docs/ci.yml.template` and write in `docs/PR_BODY.md`: "Add .github/workflows/ci.yml on GitHub (Add file → Create new file) by pasting docs/ci.yml.template."
- If CI results are unreadable, keep working Linux-verifiably and write in PR_BODY.md: "If CI fails, paste the failing log as a message and it will be fixed."
- macOS-hosted runners may have no Metal device. GPU tests must skip cleanly when `MTLCreateSystemDefaultDevice()` returns nil, and log the skip; they never fail CI. GPU visuals are then unverified until Mac day, and the CPU previews carry the review.

## 4. LOCKED TOOLCHAIN AND PLATFORM DECISIONS (verified Nov 2026; re-verify at bootstrap)
- App Store rule: since April 28, 2026, uploads must be built with Xcode 26+ and the iOS/iPadOS 26 SDK. Xcode 27.x (Swift 6.4, iOS 27 SDK) is current; Xcode 26.6 (Swift 6.3) is the CI pin on `macos-26`. Add a non-blocking job on the Xcode 27 image only after confirming its label in actions/runner-images; never guess labels.
- `// swift-tools-version: 6.2`, Swift 6 language mode, strict concurrency.
- Deployment targets: iOS 26.0, iPadOS 26.0, macOS 26.0. In Package.swift use `platforms: [.iOS("26.0"), .macOS("26.0")]`.
- Mac flavour: NATIVE multiplatform SwiftUI target (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`), not Catalyst, not "Designed for iPad".
- GPU baseline: classic Metal (MTLDevice, MTLCommandQueue, MTKView/CAMetalDisplayLink). Metal 4 is an OPTIONAL Phase 5 path (A14/M1+); verify availability APIs in the installed SDK. MetalFX spatial and temporal upscaling and frame interpolation are each gated by runtime `supportsDevice` checks.
- Shaders: Xcode 26 moved the Metal toolchain to a downloadable component, and GitHub runner-images issue #13080 plus Apple Developer Forums thread 805776 document builds failing with "missing Metal Toolchain". For first-try builds do NOT put `.metal` files in any target. Store MSL as Swift string constants in `SFRender/Shaders/*.swift` and compile at runtime with `device.makeLibrary(source:options:)`, caching results (and use `MTLBinaryArchive` where supported to avoid first-frame hitches). A macOS test compiles every shader and fails on any error. CI also runs `xcodebuild -downloadComponent MetalToolchain || true` and validates sources offline with `xcrun metal`. Move to precompiled metallibs only after CI proves it reliable (ADR).
- Dependencies: only `apple/swift-crypto` (Apache-2.0). Everything else first-party or vendored permissive C with licences recorded. No CocoaPods, Carthage or binary frameworks.
- Licence: Apache-2.0. Add `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, in-app "Acknowledgements and Data Attribution".

## 5. REPOSITORY AND XCODE STRUCTURE (exact)
```
SKYFORGE.xcodeproj/            # hand-written, minimal, objectVersion 77
  project.pbxproj, project.xcworkspace/contents.xcworkspacedata, xcshareddata/xcschemes/SKYFORGE.xcscheme
App/                           # synchronized folder
  SkyforgeApp.swift  Info.plist  PrivacyInfo.xcprivacy  SKYFORGE.entitlements
  Assets.xcassets/             # AppIcon generated by tools/make_icon.swift
Packages/SkyforgeKit/
  Package.swift
  Sources/{SFMath,SFAtmosphere,SFFlightModel,SFSystems,SFNavData,SFWeather,SFTerrainCore,
           SFWorldGen,SFPreview,SFContent,SFInput,SFATC,SFSim,SFRender,SFAudio,SFPlatform,SFUI}/
  Tests/{...Tests}/  Tests/Fixtures/
tools/ (gate.sh setup_env.sh hooks/ make_icon.swift fetch_fixtures.sh jsbsim_oracle/ visual_diff.py)
.github/workflows/ci.yml
project.yml                    # XcodeGen FALLBACK spec
docs/ (MASTER_PROMPT STATE DECISIONS ASSUMPTIONS VERIFICATION_LOG VISUAL_LOG ARCHITECTURE LICENSES_AUDIT DATA_SOURCES APPSTORE_CHECKLIST PERFORMANCE WORLD_GEN PR_BODY MAC_DAY APPLE_API_LEDGER; previews/ holds committed CPU preview PNGs; ci.yml.template)
docs/golden/                   # approved golden screenshots for visual regression
PROGRESS.md README.md LICENSE NOTICE THIRD_PARTY_NOTICES.md .gitignore
```
Rules:
- No root `Package.swift`, so Xcode opens the project.
- The app target has ONE local package dependency on `Packages/SkyforgeKit` and links `SkyforgeUI`.
- pbxproj: one multiplatform application target; Debug/Release; `GENERATE_INFOPLIST_FILE = NO`, `INFOPLIST_FILE = App/Info.plist`; `CODE_SIGN_STYLE = Automatic`; empty `DEVELOPMENT_TEAM`; `PRODUCT_BUNDLE_IDENTIFIER = org.skyforge.SKYFORGE`; `TARGETED_DEVICE_FAMILY = "1,2"`; deployment targets 26.0; `SWIFT_VERSION = 6.0`; `ENABLE_HARDENED_RUNTIME = YES` (macOS); `CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = App/SKYFORGE.entitlements`. Object IDs are unique 24-char uppercase hex. Validate with `plutil -lint` on macOS or a Python sanity script on Linux (balanced braces, unique IDs, all references defined).
- FALLBACK: keep `project.yml` in sync. If the hand-written project fails CI three times in ways you cannot fix, a manual CI job installs XcodeGen on macOS, generates and builds the project, uploads it as an artifact; the agent downloads and commits it. The committed project is the source of truth; the user never needs XcodeGen.
- Wrap every Apple-only file in `#if canImport(Metal)`/`SwiftUI`/`AVFoundation`/etc. so Linux `swift build` compiles those targets empty. Pure targets use stdlib `SIMD3<Double>`/`SIMD4<Float>`, `Synchronization.Mutex`, swift-crypto; no `simd`, `CoreGraphics`, `CryptoKit`, `os`. Linux networking: `#if canImport(FoundationNetworking) import FoundationNetworking #endif`.
- Swift Testing (`@Test`, `#expect`) for package tests; XCTest only for UI and `measure` performance tests.

`tools/gate.sh` levels: `fast` = `swift build` + `swift test` + pbxproj lint. `full` = fast + (macOS) `xcodebuild` for iOS Simulator generic, macOS, and tests on one iPhone and one iPad simulator picked dynamically from `xcrun simctl list devices available -j` (never hardcode names) + offscreen visual regression. `ci` = full + licence/attribution checks (every dependency in THIRD_PARTY_NOTICES, every network host in DATA_SOURCES.md).

## 6. CI (`.github/workflows/ci.yml`)
See §3 for what to do if the workflow file cannot be pushed or results cannot be read. Prefer a public repository (free macOS minutes).
- `linux`: ubuntu-24.04, Swift 6.2+ (swift.org action or `swift:6.2` container), `swift test --package-path Packages/SkyforgeKit`.
- `apple`: `macos-26`; `sudo xcode-select -s /Applications/Xcode_26.6.app` (fallback to image default if missing; print `xcodebuild -version`); `xcodebuild -downloadComponent MetalToolchain || true`; build iOS Simulator generic and macOS; test on dynamically chosen iPhone and iPad simulators; package tests on macOS; run the visual-regression render and upload PNGs and `.xcresult` as artifacts. `CODE_SIGNING_ALLOWED=NO` throughout.
- `apple-next`: continue-on-error, Xcode 27 image if available.
- `xcodegen-fallback`: manual dispatch.
- Concurrency per branch, cache SwiftPM `.build`, no secrets.

## 7. ARCHITECTURE
Layers: UI (SwiftUI) ↔ Orchestrator (SFSim) ↔ {Simulation: FDM, systems, atmosphere, weather; World: terrain core, WorldGen, nav data; Content: storage/downloads; Input; ATC} ↔ Platform adapters (Metal renderer, audio, controllers, motion, speech, thermal).

Timing and threads:
- Simulation runs on a dedicated thread with fixed `dt = 1/120 s` and an accumulator loop (Fiedler, "Fix Your Timestep"), max 8 substeps per frame. It publishes immutable `SimSnapshot` values through a triple buffer guarded by `Synchronization.Mutex`; the renderer interpolates with the accumulator alpha.
- Rendering is driven by MTKView (P1) then CAMetalDisplayLink; the view frame-rate range comes from the quality governor.
- World generation and streaming run on background queues with strict per-frame time budgets; the render thread never waits on generation (fall back to the coarser LOD until ready; never pop, always cross-fade or geomorph).
- Networking and storage use actors. UI observes `@Observable` models on MainActor at ≤ 30 Hz. SwiftUI never drives the render loop.

Large-world precision: positions are `SIMD3<Double>` ECEF (WGS84). Renderer uses a floating origin (local ENU re-anchored when camera moves > 10 km) and camera-relative float32 vertices. Reverse-Z with infinite far plane (`Depth32Float`, clear 0, compare `.greater`).

Determinism: the FDM is a pure function `step(state, inputs, env, dt) -> state`; no wall clock; seeded PRNG (SplitMix64/Xoshiro in SFMath); recorded inputs reproduce states. The procedural world is also a pure function of (world seed, tile coordinates, source data version), so every device sees the same world.

## 8. VISUAL QUALITY DIRECTIVE AND THE "SKYWORLD" PROCEDURAL OPEN WORLD (HIGHEST PRIORITY)

### 8.0 Art direction bible ("extremely beautiful")
Goal: a cohesive, cinematic, believable look that feels hand-art-directed everywhere, not noise-generated. Write the final bible into `docs/WORLD_GEN.md` and keep it current.
- Look: cinematic realism with golden-hour as the hero lighting; presets: sunrise, golden hour, midday, overcast, dusk, night, storm. Filmic tonemapping (ACES-style) with a subtle S-curve, gentle bloom, soft vignette, restrained saturation, warm-key/cool-shadow colour split, correct auto-exposure.
- Colour harmony: every region gets a palette derived from its seed and climate (warm brick, white stucco, grey concrete, timber, terracotta, etc.), applied to buildings, roofs and fields so cities feel designed; tree-species tints harmonise with the season; no random rainbow colours.
- Variety without chaos: no identical building adjacent to another; minimum variant counts per building type; per-instance tint, scale and rotation jitter; irregular but plausible street layouts; landmarks and focal points placed by rule (towers, bridges, stadiums).
- Depth: aerial perspective, haze layers, god rays, cloud shadows moving over terrain, layered ridge lines in mountains, sun glitter on water, wet-road speculars after rain.
- Materials: PBR throughout with clearcoat on aircraft paint, subtle grime and edge-wear maps, believable roof and facade detail, crisp window detail, lane markings with wear.
- Cleanliness: no z-fighting, shimmering, texture stretching, floating or intersecting objects, bad normals, LOD popping or visible tiling. These are release-blocking defects.
- Hero views: the chase camera on the aircraft and the cockpit view must look stunning in every preset.
- Photo mode: depth of field, exposure compensation, time-of-day and cloud sliders, filters, high-resolution capture.
- Art-director review loop: after each visual milestone, a subagent acting as art director scores each scene 1–10 on sharpness, lighting, colour harmony, variety, depth and cleanliness, lists concrete defects, and you fix them. Target an average of at least 8 before moving on. Log every score and fix in `docs/VISUAL_LOG.md`. Scores are subjective, so also keep the objective metrics of §8.5.

### 8.1 Visual target
The user's reference is a Microsoft Flight Simulator screenshot (low-altitude chase view of a small single-engine aircraft over a dense suburban/urban area at golden hour). SKYFORGE must reach the SAME CLASS of sharpness and richness, using our OWN generated content. Key properties of the target look (reproduce the qualities, never the assets):
- Dense, varied autogen: individual buildings with distinct footprints, heights, roof types and facade colours (brick, concrete, glass, gabled and flat roofs, warehouse sawtooth/vaulted roofs, parking lots with cars), clearly resolved down to a few hundred feet.
- Thousands of individual trees with their own crowns, species/colour variation (autumn tints), and soft contact shadows; hedgerows; parks with paths.
- Road network: multi-lane highways with interchanges, ramps, medians, lane markings, bridges; secondary streets in a believable grid; parking areas; railways.
- Low-sun lighting: warm key light, long soft shadows from buildings and trees, atmospheric haze and aerial perspective toward a glowing horizon, subtle bloom, correct exposure adaptation.
- Distant detail: wind turbines and landmarks silhouetted at the horizon; smooth transition from sharp near-field to hazy far-field with no visible LOD popping.
- Aircraft rendered with PBR materials, correct specular, shadow on the ground, and a clean HUD (altitude tape, flaps, trim).
- Crisp texture filtering (anisotropic 8–16x), no shimmering, no crawling edges, no blurry smears.
You (the agent) cannot rely on seeing the reference. Operationalise it: if the user placed `docs/reference/msfs_target.png` locally, read it and compare against; otherwise use this description. Never commit the reference image to the public repo (it is third-party copyrighted); keep `docs/reference/` in `.gitignore`.

### 8.2 Honesty and tiers
Matching a studio's satellite-photogrammetry look from free procedural content is "achievable with substantial development" for near-field generic scenery, and "currently impractical" for exact real-world building likeness. SKYFORGE's strategy is therefore: real geography (elevation, coastlines, rivers, road and building LOCATIONS where free data exists) plus a high-quality procedural look-development pipeline for everything you see. A visual-quality ladder (Ultra/High/Medium/Low) scales instance counts, shadow cascades, texture sizes, clouds, ocean and upscaling by device tier. Document measured results per tier in PERFORMANCE.md and VISUAL_LOG.md.

### 8.3 SkyWorld: our own open world
Principle: the world is generated from (a) a real elevation skeleton (free DEM) so continents, mountains, coasts and rivers are correct, and (b) deterministic procedural layers that fill in everything visible. No imagery is required. All generators are pure Swift (CPU) with GPU-side instancing and shading, testable on Linux where CPU-only.

Layers (each its own module under `SFWorldGen`, each with a seeded, tested generator):
1. **Terrain geometry**: CDLOD quadtree over WGS84 (Strugar 2009), 65×65 nodes with geomorphing and skirts, plus procedural detail displacement (fBm and ridged noise with erosion-style shaping, bounded ±few m near the camera, flattened at airports, roads and building plots). Slope-aware normals from a compute pass. Near-field normal map detail at ~0.25–0.5 m texel equivalent through detail normals blended in the shader.
2. **Climate and biome model**: derive biome per cell from latitude, elevation, slope, aspect, distance to coast and a coarse climate model (temperature lapse rate, rainfall bands, continentality) into Whittaker/Köppen-style classes (ice, tundra, boreal, temperate forest, grassland, savanna, desert, rainforest, wetland, cropland, urban). Seasonality by date and hemisphere (autumn tints, snow lines, crop colour cycles). Optional user-initiated landcover (ESA WorldCover, only after recording its terms) refines biomes; default is the climate model alone.
3. **Hydrology**: rivers from DEM flow accumulation (D8/D-infinity), lakes from depressions and a coastline mask from elevation ≤ 0; river width from accumulated flow; water rendered with the ocean/lake shader. Where OSM water polygons are available (small Overpass queries, §10), use them and prefer them to derived water.
4. **Settlement placement**: where OSM data is available (on-demand Overpass for the airport area, ≤ 10 km radius, ≤ 1 query/min, cached) place real road/building footprints; elsewhere a procedural settlement model decides city/town/village/farm density from terrain suitability (low slope, near water, near coast, near flat valleys) and a deterministic population field. Larger cities cluster near rivers/coasts, with a downtown core of tall buildings fading to suburbs and rural land.
5. **Road networks**: tensor-field street generation (Chen et al., "Interactive Procedural Street Modeling", SIGGRAPH 2008), arterial/collector/local hierarchy, highways as splines with ramps and interchanges (cloverleaf/diamond/stack templates), bridges when crossing water or steep terrain, lane markings, medians, curbs, crosswalks. Roads are rendered as terrain-conforming ribbon meshes plus a decal/virtual-texture layer for markings and wear.
6. **Parcels and buildings**: subdivide blocks into lots (OBB subdivision), then generate buildings by a shape grammar (Müller et al., "Procedural Modeling of Buildings", SIGGRAPH 2006; CGA shape grammar). Building types: detached house, row house, apartment block, office tower, warehouse (flat/sawtooth/barrel roof), strip mall, church, school, stadium, factory, hangar. Each has parametric footprint, floors, floor height, roof (gabled, hipped, flat with parapet and HVAC, mansard), facade materials, windows as parallax-mapped or instanced detail, and per-building colour/age variation. Generate in chunks (1 km), merge meshes per material, use GPU instancing for repeated parts, and impostors/billboard-cloud LODs for the distance. Parking lots with instanced vehicles.
7. **Vegetation**: species sets per biome; density from biome, slope, moisture and distance to roads/buildings; placement by Poisson-disk/blue-noise sampling (deterministic); individual trees as GPU-instanced meshes with 3–4 LODs and camera-facing impostors at distance; wind sway in the vertex shader; per-instance colour/size variance; leaf-card shading with translucency; contact shadows via cascaded shadow maps and ambient occlusion. Grass and low shrubs as instanced blades only within a short radius, dissolving into a shaded ground texture. Forest canopies at distance as a height-field mass with detail texture.
8. **Agriculture and land patterns**: field parcels with crop-row patterns (orientation per field, colour by crop and season), orchards in grids, irrigation circles in arid regions, vineyards.
9. **Infrastructure and landmarks**: wind farms (turbines with animated rotors, sited on ridges and plains), power lines and pylons following corridors, railways, ports, quarries, solar farms, radio towers; procedural landmark generator (bridges, towers, stadiums) placed by rule. Real-world named landmarks are NOT hand-modelled in v1.
10. **Night world**: street lights along roads, lit windows by building type and time, highway headlights/taillights as animated instanced streams, airport lighting, aircraft nav lights; correct auto-exposure and sky glow over cities.
11. **Airports (visual)**: runways, taxiways, aprons, markings, lighting, signs, terminals, hangars, windsocks, vehicles; generated from OurAirports data (§10) plus the building grammar for terminals and hangars; flattened terrain with blended embankments.

All generators must be: deterministic, chunked, budgeted (record ms per chunk), cache results on disk (content-addressed), versioned (`worldgen_version`) and unit-tested (determinism hash, bounds, no overlaps with roads/water, no NaN).

### 8.4 Rendering pipeline requirements
- Deferred-lite or forward+ pipeline suited to Apple's tile-based GPUs: memoryless attachments, `storeAction .dontCare` where possible, few passes, tile-shader/programmable-blending paths where supported.
- GPU-driven rendering: culling in compute (frustum, horizon, Hi-Z occlusion), indirect command buffers; mesh shaders on capable GPUs (verify `supportsFamily` and feature checks), fallback otherwise.
- Shadows: 3–4 cascaded shadow maps (stable, texel-snapped, PCF/PCSS soft penumbra), plus contact shadows; long soft low-sun shadows must look correct.
- Lighting: physically based BRDF (GGX), sky-driven ambient via spherical harmonics from the atmosphere LUTs, GTAO/SSAO, planar/SSR water reflections, aerial-perspective froxel volume, ACES-style tonemapping, auto-exposure with smooth adaptation, bloom, subtle vignette, optional film grain off by default, colour grading tuned for golden hour and midday.
- Sky/atmosphere: Hillaire 2020 (EGSR) LUTs (transmittance, multi-scatter, sky-view, aerial perspective), Bruneton & Neyret 2008 as reference.
- Clouds: raymarched volumetrics after Schneider (SIGGRAPH 2015, Horizon Zero Dawn): weather map + Perlin-Worley 3D noise, quarter-res with temporal reprojection and blue-noise jitter, cloud shadows on terrain, god-rays. Layers from METAR and model cover.
- Ocean/water: Tessendorf FFT (64² iPhone to 256² Mac), Fresnel, SSR, foam, shoreline blending; Gerstner fallback on Low.
- Textures: procedurally authored material library (asphalt, concrete, brick, roof tiles, metal, grass, soil, rock, sand, snow, bark, leaves) generated by Swift/MSL generators at first launch or build time, tile-able, with albedo/normal/roughness/AO, mipmapped, anisotropic 8–16x; stochastic/non-repeating tiling and height-based blending for terrain materials; a terrain virtual-texture or clipmap cache for near-field ground material at ~0.25–0.5 m texel.
- Anti-aliasing and sharpness: MetalFX temporal upscaling where supported (else spatial, else our own TAA with neighbourhood clamping and velocity), plus contrast-adaptive sharpening; MSAA/analytic AA for thin geometry (wires, markings); no shimmering on thin roads, wires and tree edges (use geometric AA/dithered LOD cross-fades with temporal stability).
- Aircraft/cockpit: PBR materials, cockpit glass reflections, instrument rendering via Metal 2D at native resolution, cockpit shadows.
- LOD discipline: no visible popping; cross-fade or geomorph all transitions; budgeted generation hidden behind draw distance.

### 8.5 Visual verification (required, automated, honest)
- Offscreen renderer test renders canonical scenes at fixed camera/time/seed: (a) suburban low pass at golden hour, (b) highway interchange midday, (c) dense downtown, (d) forest and river, (e) coastline with ocean, (f) mountain valley with snow line, (g) night city, (h) cockpit view, (i) storm clouds, (j) airport final approach. Save PNGs; compare against `docs/golden/` using SSIM and a perceptual metric via `tools/visual_diff.py`; failures block commit unless the change is an intended, logged re-baseline with a screenshot review in VISUAL_LOG.md.
- Sharpness metrics: Laplacian variance and high-frequency energy of crops of near-field ground, building facades and tree crowns must stay above recorded thresholds; temporal stability test (frame-to-frame difference on a static camera under TAA must be below threshold; no shimmering).
- Visual review by a subagent: after each visual milestone a subagent examines the screenshots and writes a critique against §8.1 (list concrete deficiencies); fix before moving on. Log every iteration.
- Metal validation: `MTL_DEBUG_LAYER=1`, shader validation enabled in tests; zero validation errors.
- When no Metal device exists (this sandbox, or CI runners without a GPU), the CPU preview renders of §8.6 of the same scenes satisfy the review requirement, and the GPU-pass look is finalised on Mac day (§24). Never claim GPU rendering quality you have not seen.

### 8.6 Linux-verifiable CPU preview renderer (`SFPreview`, REQUIRED)
Because you have no GPU, build a pure-Swift software renderer that draws the SAME generated world (terrain, biomes, roads, buildings, trees, water, airport, aircraft model) so you and the user can see the result.
- Library target `SFPreview` plus an executable `sfpreview` in the package: `swift run sfpreview --scene <name> --time <preset> --seed <n> --out docs/previews/<name>.png`. It must run on Linux in ≤ 60 s per image at 1280×720.
- Features: perspective camera, z-buffer triangle rasteriser, directional sun light with a shadow map (soft PCF), Lambert plus simple specular, fog and aerial perspective, sky gradient with sun glow, instanced low-poly trees and buildings with roof and window colour variation, road ribbons with markings, water with a simple Fresnel tint, simple tonemapping and bloom, 2×2 supersampling. A pure-Swift PNG encoder (zlib stored blocks plus CRC; no external libraries).
- Scenes: the ten of §8.5 (suburban golden hour, highway interchange, dense downtown, forest and river, coastline, mountain valley, night city, cockpit/chase aircraft, storm, airport final approach). Commit the latest PNG of each to `docs/previews/` (≤ 1.5 MB each) so the user can view them in the pull request on an iPad. Overwrite rather than accumulate.
- The CPU renderer does not need to match the Metal look exactly, but it must exercise the same generators, so content defects (bad layouts, overlaps, ugly palettes, floating objects) are visible and fixable here. Keep a table in VISUAL_LOG.md of the known differences between the CPU preview and the intended GPU look.

## 9. SUBSYSTEM SPECIFICATIONS

### 9.1 Geodesy and math (SFMath)
WGS84 (a = 6378137.0 m, f = 1/298.257223563); geodetic↔ECEF with < 1 mm error; ENU/NED; Double quaternions; Karney/Vincenty geodesics; Web Mercator math (lat ≤ 85.0511°). Geoid: Phase 1 assumes geoid ≈ ellipsoid and documents ±100 m; EGM96 grid added in P3 only after verifying NGA terms. Tests: 10,000 random round trips < 1 mm, reference points.

### 9.2 Atmosphere (SFAtmosphere)
ISA/US Standard Atmosphere 1976 to 86 km (T, p, ρ, a, μ via Sutherland); QNH/OAT deviations; pressure/density altitude; CAS/EAS/TAS/Mach with compressible pitot. Tests: tabulated ISA values at 0, 1, 5, 11, 20, 32 km within 0.1%.

### 9.3 Flight dynamics (SFFlightModel): our own, Apache-2.0
- JSBSim is LGPL-2.1; static linking is effectively mandatory on iOS, and the JSBSim discussion #1171 treats App Store compliance as an open relinking question. FlightGear and YASim are GPL. The shipping binary contains NO LGPL/GPL code. JSBSim is used only as an offline validation oracle in `tools/jsbsim_oracle/` (Python `pip install jsbsim`, optional Linux CI), never distributed.
- 6-DOF rigid body, quaternion attitude, RK4 at 120 Hz (semi-implicit with 480 Hz substeps for stiff gear). Component build-up aerodynamics: CL(α, δf), CD(α, δf), Cm(α, δe), CY(β), Cl(β, p, δa), Cn(β, r, δr) plus damping derivatives; post-stall table through ±90° α. Ground effect via McCormick/Wieselsberger factors. Propeller via BEM table (CT, CP vs J) and a piston engine with density-altitude and mixture models, governor later. Gear: spring-damper per wheel with friction/braking and terrain height queries. Dryden turbulence per MIL-F-8785C / MIL-HDBK-1797 plus discrete gusts; wind-shear coupling from the weather field. P3: optional blade-element wing for spins/gliders.
- Aircraft data must be ORIGINAL (public-domain NASA/NACA reports such as NACA Report 824, and textbook estimation), no trademark names ("SF-1 Trainer", not a real type).
- Tests: trim at 100 KTAS/3,000 ft ISA with |VS| < 50 ft/min; stall speed within ±3 kt of design; energy drift < 0.1% over 60 s in a no-drag configuration; static stability signs (Cmα < 0, Cnβ > 0, Clβ < 0); determinism hash over 10 min of recorded inputs; no NaN/Inf over a 1-hour fuzzed run.
- Jets: P4. Helicopters (blade-element rotor, Pitt-Peters inflow): last, with significant compromises.

### 9.4 Systems and autopilot (SFSystems)
Data-driven component graph (electrical, fuel, vacuum/pitot-static with blockage, lights, flaps, trim); checklists as data; failure-injection API with a test per failure. Autopilot as cascaded PID with anti-windup: ROL/HDG/NAV (VOR/GPS), ALT/VS/IAS, APR (synthetic glideslope); VNAV in P4. Generic glass PFD/MFD ("SF-1000", no third-party trade dress) plus steam gauges, Metal 2D. Tests: step responses (overshoot bounds), intercept convergence.

### 9.5 Airports and navigation (SFNavData)
- OurAirports: "All data is released to the Public Domain." Files airports/runways/navaids/airport-frequencies/countries/regions CSV at `https://davidmegginson.github.io/ourairports-data/{file}.csv`. Ship a compact converted snapshot in the bundle for offline use; optional "Update airport database" action downloads, validates (size, row counts within ±20%, parse success) and swaps atomically.
- Runways generated from threshold coordinates, heading, length, width, surface; ICAO Annex 14 simplified markings; lights by type; PAPI where data allows, otherwise synthetic and labelled. Airports without geometry are listed as "no runway data".
- Navaids from OurAirports (VOR/DME/NDB/TACAN); ILS is not reliable there, so generate a synthetic 3° ILS for runways ≥ 1,200 m, clearly labelled.
- US procedures (P4): FAA CIFP (ARINC 424, 28-day cycle) downloaded on the user's device on request with the FAA error-notice agreement shown; treat US government data as presumed public domain (17 U.S.C. §105), record as assumption.
- EXCLUDED: Navigraph (paid), X-Plane navdata (restricted), OpenAIP (CC BY-NC, API key required).
- Tests: CSV parsing (quoted commas, unicode); KSFO runway lengths/headings within tolerance from fixture; navaid lookup; bearing/distance to DME.

### 9.6 Weather (SFWeather)
- aviationweather.gov Data API: keyless, e.g. `https://aviationweather.gov/api/data/metar?ids=KSFO&format=json`; rate limited to 100 requests/min and not more than 1 request/min per thread; custom User-Agent `SKYFORGE/<version> (+repo URL)`; handle 204 and 429; batch IDs; cache 10 minutes; serve stale on failure; treat history as ≤ 15 days. Credit NOAA/NWS Aviation Weather Center.
- Open-Meteo: keyless; free for non-commercial use that includes "private or non-profit websites or apps that do not have subscriptions or advertising" — SKYFORGE must stay free with no ads, IAP or subscriptions (record in DECISIONS.md). Free limits 600/min, 5,000/hour, 10,000/day; design for ≤ 1 call per 10 min per flight. Attribution "Weather data by Open-Meteo.com". Data licence CC BY 4.0 (one sub-repo says CC BY-NC 4.0: note the conflict in DATA_SOURCES.md).
- Model: full METAR/TAF parser with ≥ 200 real fixtures (CAVOK, variable winds, gusts, RVR, vertical visibility, inHg vs hPa, missing fields); 3D field: surface from ≤ 3 nearest METARs (IDW), aloft from Open-Meteo pressure levels, blended with ISA; cloud layers feed the volumetric cloud renderer; turbulence from shear/gusts into Dryden; precipitation effects; icing (P4) for OAT ∈ [−20, 0] °C in visible moisture.
- Offline: seeded procedural weather presets (clear, scattered, overcast, storm, gusty crosswind), automatic when offline. GRIB2 ingestion is P5+.

### 9.7 Storage and content (SFContent)
- User-configurable quota 1–500 GB (default 10 GB); iOS cannot guarantee 500 GB; the UI says so. Before writes check `volumeAvailableCapacityForImportantUsage`; always leave max(5 GB, 10% of capacity) free.
- Layout: `Library/Caches/Skyforge/` re-downloadable tiles and generated-world cache (purgeable); `Library/Application Support/Skyforge/content/` pinned offline regions and DBs, excluded from backup; settings, bindings and logbook in Application Support. No iCloud content.
- Content-addressable store (SHA-256 via swift-crypto), manifests (JSON), dedup, atomic install (temp → verify → rename), LRU eviction for the cache tier only, corruption detection with automatic re-fetch.
- Downloads: URLSession with caching, ≤ 8 concurrent per host, exponential backoff; user-initiated regions use background URLSession with resume data; allowed only for sources that permit prefetch (AWS Terrain Tiles, Copernicus, OurAirports). Never bulk-download OSM tile servers or EOX layers. Respect expensive/constrained network flags; Wi-Fi-only default for regions.
- Compression via Apple `Compression` (LZ4/LZFSE) behind a `Codec` protocol; identity codec on Linux.
- Optional curated packs (P5): Apple-hosted Background Assets (up to 200 GB, 200 packs, OS 26+) require manual App Store Connect upload; do not use On-Demand Resources.
- Bundle ≤ 150 MB (the cellular prompt threshold is 200 MB, measured thinned and compressed); disclose and ask before first-launch downloads (Guideline 4.2.3). The bundle must fly and look good fully offline (procedural world + bundled global DEM).
- Tests: quota, LRU, byte-flip corruption → detect → re-fetch, interrupted install recovery, offline mode via injectable transport, disk-full simulation.

### 9.8 Input (SFInput)
Actions and axes; bindings = {device class, control id, modifiers, context, aircraft id?}; multiple bindings per action; profile layering global → device → aircraft → context. Axis calibration, inner/outer dead zones, response curves (linear, exponential, 5-point spline), invert, sensitivity, smoothing, relative vs absolute modes. Conflict detection, searchable list, press-to-bind, JSON import/export (schema-versioned). Devices: touch yoke/stick/throttle/rudder/trim with haptics; CoreMotion tilt with calibrate-centre; `GCKeyboard` and AppKit key events; mouse/trackpad; `GCController` gamepads. HOTAS/generic HID sticks: not exposed on iOS/iPadOS by GameController ("dependent on restricted resources"; UI says so); macOS IOKit `IOHIDManager` adapter in P4 behind a flag after verifying sandbox/Input Monitoring behaviour. Tests: precedence, conflicts, curve maths, dead zones, JSON round trip.

### 9.9 Audio (SFAudio)
AVAudioEngine with procedural/synthesised sources (granular/additive engine from RPM and manifold pressure, wind from airspeed, rolling, gear, stall horn, avionics beeps), AVAudioEnvironmentNode spatialisation. No OpenAL Soft (LGPL), no FMOD/Wwise; no sampled copyrighted audio.

### 9.10 ATC and traffic (SFATC, P4)
Deterministic rule-based state machine (ATIS from METAR, clearance, ground, tower, departure, approach, center), simplified ICAO Doc 4444 / FAA 7110.65 phraseology. Voice out: AVSpeechSynthesizer. Voice in (optional): on-device recognition (`requiresOnDeviceRecognition = true`, or newer OS 26 Speech APIs after SDK verification) with grammar intents and a tap-menu alternative. Optional Foundation Models phrase variety (never decides clearances). AI traffic: procedural schedules from airport size, same FDM with simplified autopilot, runway by wind. Real-world traffic EXCLUDED from the shipping build (OpenSky requires a written licence for live products; adsb.lol is keyless today under ODbL but announces a future key); a `#if DEBUG` adsb.lol viewer with attribution is allowed.

### 9.11 UX (SFUI)
- Free Flight in ≤ 2 taps: Resume Last Flight or Quick Flight at the nearest airport (location by map pick, no Core Location permission).
- World map planner drawn with our own vector rendering (no third-party tiles). One in-flight overlay with tabs (Aircraft, Weather, Time, Camera, Controls, Map, Settings, Pause/Replay). Settings show measured per-option cost ("~+1.2 ms GPU on this device"). Cameras: cockpit head look, chase, orbit, tower, drone, cinematic path, photo mode.
- Accessibility: VoiceOver labels and an instrument-readout mode; Dynamic Type; colour-blind-safe palettes; labelled assist modes; hold-to-toggle and single-axis schemes; Reduce Motion respected.
- Platforms: iPhone landscape-first compact HUD; iPad split controls (external display P5); Mac resizable windows, full screen, menus and shortcuts, `LSApplicationCategoryType = public.app-category.simulation-games`.

## 10. DATA SOURCES (keyless, licence-checked) — record each in docs/DATA_SOURCES.md
- **AWS Terrain Tiles (Terrarium PNG)**: `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`, z0–15; height = (R·256 + G + B/256) − 32768 m. Per-source attribution per tilezen/joerd `docs/attribution.md`; show in-app. Throttle ≤ 8 concurrent; cache permanently.
- **Copernicus DEM GLO-30/GLO-90** (AWS Open Data `copernicus-dem-30m`/`-90m`, `--no-sign-request`, COG): free redistribution; required notice "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved" plus disclaimer. Do NOT use restricted GLO-30-R/EEA-10-R. COG reader is a P3 item; use Terrarium until then.
- **Bundled offline baseline**: a downsampled global DEM generated by the agent from GLO-90 or Terrarium z5–z6, ≤ 25 MB compressed, custom tiled binary with SHA-256 manifest.
- **Imagery**: DEFAULT is none; SkyWorld (§8) provides all surface appearance. Optional user toggle (off by default): EOX Sentinel-2 cloudless 2016 (CC BY 4.0, attribution "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017)"), streamed only for viewed tiles after verifying current WMTS terms; never enable 2018+ layers (CC BY-NC-SA). NASA GIBS/Blue Marble only after terms are verified and recorded.
- **OpenStreetMap**: NEVER use tile.openstreetmap.org or vector.openstreetmap.org (bulk and offline use prohibited). Use small on-demand Overpass queries only (≤ 10 km radius around the selected airport/region, ≤ 1/min, cached, identifying User-Agent) after verifying the current Overpass policy. Data is ODbL; show "© OpenStreetMap contributors, ODbL". Derived caches stay on device. Overture Maps: P5 research item only.
- **OurAirports**, **aviationweather.gov**, **Open-Meteo**: §9.5, §9.6.
- EXCLUDED: Google Photorealistic 3D Tiles, Cesium ion, Bing/Apple/Mapbox imagery, any Microsoft asset, Navigraph, OpenAIP, live OpenSky in shipping builds.

## 11. PERFORMANCE BUDGETS AND QUALITY GOVERNOR (smoothness is a feature)
These are targets; measure on device and record in PERFORMANCE.md. Never invent benchmark numbers.
- Device tiers from GPU family (`supportsFamily(.apple7/.apple8/.apple9…)`), `os_proc_available_memory()` and `ProcessInfo.physicalMemory`: Low (Apple6/A13, Intel Macs), Medium (Apple7–8), High (Apple9+ and M-series), Ultra (M Pro/Max/Ultra).
- Frame targets: iPhone 60 fps (16.67 ms) default, 30 fps sustained mode under thermal pressure, optional 120 Hz on ProMotion (`CADisableMinimumFrameDurationOnPhone = YES`); iPad Pro and Mac 120 fps (8.33 ms) where achievable, else 60. Pacing: p99 frame time ≤ 1.25× target; ≤ 1 hitch (> 2× target) per minute in steady cruise. Consistency beats peak FPS: use CAMetalDisplayLink/present-at-time pacing and avoid frame-time variance from generation, shader compilation or allocation.
- Sim CPU: FDM + systems ≤ 1.0 ms per 1/120 s step on Medium tier (XCTest `measure` guard on macOS CI).
- World generation: ≤ 2 ms main-thread-equivalent per frame budget; chunk generation on background queues; no generation work on the render thread.
- Memory ceilings: iPhone ≤ 1.5 GB resident on 6 GB devices (keep ≥ 400 MB headroom via `os_proc_available_memory()`), iPad ≤ 2.5 GB, Mac ≤ 4 GB; halve cache budgets on memory warnings. Increased-memory-limit entitlement is optional and needs provisioning (manual).
- Load: cold launch to interactive menu ≤ 2 s; menu to cockpit ≤ 8 s warm, ≤ 20 s cold on Medium tier (targets). Pre-warm pipelines and the world cache behind a progress screen so flight never starts with missing visuals.
- Quality governor: inputs GPU time (command buffer timestamps), CPU frame time, `ProcessInfo.thermalState`, Low Power Mode; actions in order: dynamic resolution (MetalFX), instance density/draw distance for vegetation and buildings, cloud raymarch steps, terrain SSE threshold, shadow resolution/cascades, ocean FFT size, frame-rate cap; hysteresis ≥ 3 s; changes must be visually graceful (no popping).
- Apple GPU rules: memoryless depth/MSAA, minimal passes, ASTC for authored textures, argument buffers/bindless for materials, compute for bandwidth-bound post, avoid overdraw on foliage (alpha-to-coverage or cutout with depth pre-pass where it pays off).
- Profile with Instruments (Metal System Trace, Time Profiler, Allocations) when on a Mac and document results.

## 12. TESTING AND VERIFICATION GATES
- Unit tests (Linux + macOS): every pure module; ≥ 80% line coverage target for SFMath, SFAtmosphere, SFFlightModel, SFWeather, SFContent, SFInput, SFNavData, SFWorldGen.
- Integration: scripted 10-minute flight (takeoff, climb, turn, cruise, descent, landing) on fixture terrain; no crash; touchdown VS under −600 ft/min with autopilot approach; stops on the runway.
- Determinism: input replay hash equality; WorldGen determinism hash per tile.
- Fuzzing: METAR, CSV and manifest parsers.
- Apple tests (macOS CI): shader compile test; renderer smoke test (10 offscreen frames, non-black, zero validation errors under `MTL_DEBUG_LAYER=1`); visual-regression suite (§8.5); UI test (launch → Quick Flight → in-flight menu → exit); `performAccessibilityAudit()` if available in the SDK.
- Tests never hit the live network; use an injectable `HTTPTransport` with recorded fixtures. An optional `LIVE_NETWORK=1` smoke test is allowed locally.
- A feature is done only when its tests exist and pass, the relevant gate level is green and logged, and (for visual features) screenshots are reviewed and logged.

## 13. APP STORE COMPLIANCE (maintain docs/APPSTORE_CHECKLIST.md)
- Guideline 2.5.2: no downloading or executing code that adds features. Aircraft, scenery and weather packages are DATA ONLY (JSON, glTF/USDZ, textures); shaders ship in the binary.
- 2.1: no placeholder features or crashes; offline mode works for the reviewer. 4.2: core flight works from the bundle alone; downloads disclosed with size and consent.
- Privacy: no tracking, analytics or accounts; nutrition label "Data Not Collected" (unless system crash logs opted in); `PrivacyInfo.xcprivacy` with `NSPrivacyTracking = false` and required-reason API declarations for what is used (UserDefaults CA92.1; file timestamps C617.1; disk space E174.1/85F4.1; system boot time/uptime 35F9.1). Verify every reason code against Apple's current page before finalising.
- Permission strings only for features actually used (microphone/speech for voice ATC; local network/Bonjour in P5). No location permission.
- `ITSAppUsesNonExemptEncryption = NO`. Age rating: answer Apple's updated questionnaire (expected lowest tier).
- Licences: no GPL/LGPL/AGPL in the binary; all attributions in-app (OurAirports courtesy, AWS Terrain Tiles source list, Copernicus notice, OSM ODbL, Open-Meteo, NOAA AWC, EOX if enabled).
- Trademarks: no "Microsoft", "Flight Simulator", "Cessna", "Garmin", airline names or liveries. Name "SKYFORGE" plus descriptive subtitle.
- Metadata: description states plainly what is procedural versus real data. Screenshots are captured by the user. Mac: App Sandbox with `com.apple.security.network.client`, hardened runtime.
- Honesty: approval cannot be guaranteed; the checklist covers known common rejection causes.

## 14. OPEN-SOURCE AUDIT (verify licence file and last-commit date before vendoring; record both in LICENSES_AUDIT.md)
| Candidate | Licence | Decision |
|---|---|---|
| JSBSim | LGPL-2.1 | offline oracle only, never shipped |
| FlightGear code/aircraft, YASim | GPL | excluded |
| Cesium Native | Apache-2.0 | not in v1 (heavy, tokens for main sources); revisit P5 |
| GDAL/PROJ | MIT-style | excluded on device; Swift-native geodesy |
| CGAL | GPL/LGPL | excluded |
| earcut.hpp (ISC), Clipper2 (Boost), meshoptimizer (MIT), cgltf (MIT) | permissive | allowed when needed (P3) |
| KTX-Software/Basis/Draco (Apache-2.0), zstd/lz4 (BSD) | permissive | optional P4+ (Apple Compression first) |
| FastNoise2 (MIT) / libnoise (LGPL) | | write our own noise in Swift/MSL; libnoise excluded |
| OpenAL Soft (LGPL), FMOD/Wwise (paid) | | excluded; AVAudioEngine |
| Eigen (MPL-2.0) | | unnecessary (stdlib SIMD) |
| swift-crypto | Apache-2.0 | allowed (only SPM dependency) |
| Blender | GPL (tool) | allowed as a tool only; output assets are ours |
| Unity/Unreal | proprietary EULA, accounts | excluded |
| Godot/Bevy | MIT / MIT+Apache | excluded (not Xcode-native) |
| SceneKit/RealityKit | Apple | excluded for world rendering; RealityKit possible later for a USDZ hangar viewer |
Also review and record maintenance status of any additional library before use.

## 15. AIRCRAFT PACKAGE FORMAT (data-only v1)
```
<id>.skyaircraft/ manifest.json (schemaVersion, id, name, author, license SPDX, sha256 list)
  mass.json aero.json propulsion.json gear.json systems.json autopilot.json checklists.json
  cockpit.json model/ (glTF 2.0 .glb or procedural spec) liveries/
```
Phase 1 geometry is procedural, generated in Swift from parametric dimensions (no asset-pipeline risk) and must meet the visual bar of §8 (PBR, correct shadows, clean silhouettes). A validator checks schema, physical plausibility (positive inertia, CG in envelope) and licence presence. Scope: P1 GA trainer; P4 glider, light twin, turboprop, light jet; P5+ airliner with simplified systems, vintage taildragger; helicopter last.

## 16. PHASED ROADMAP WITH ACCEPTANCE CRITERIA
Visual quality is built early and continuously, not bolted on at the end.

**P0 Bootstrap.** Hooks, `tools/setup_env.sh`, state files, scheduled resume task (§2.3), package skeleton including the `SFPreview` skeleton, minimal pbxproj, CI (or `docs/ci.yml.template`), `docs/MAC_DAY.md` and `docs/APPLE_API_LEDGER.md` stubs, draft PR. Accept: `swift test` green on Linux; CI `apple` green if readable; STATE.md reflects reality.

**P1 Vertical slice with a visual foundation.** SF-1 Trainer FDM at 120 Hz; ISA/WGS84; bundled global DEM + Terrarium streaming; CDLOD terrain with procedural detail and biome shading; Hillaire sky; cascaded shadows; PBR aircraft; first SkyWorld layers (roads, trees, simple buildings in a test region); OurAirports runway; basic PFD/steam gauges; touch/keyboard/gamepad; METAR wind/QNH; procedural weather fallback; CPU preview renderer (§8.6) producing committed PNGs of scenes (a), (d), (e), (f), and the offscreen Metal visual-regression harness written (it runs when a Metal device exists). Accept: FDM tests pass; scripted flight integration passes; renderer smoke test passes; airplane-mode flight works; screenshots of scenes (a), (d), (e), (f) reviewed and logged; CI green.

**P2 Rich world and flying depth.** Full SkyWorld layers 1–9 (hydrology, settlements, tensor-field roads and highways with interchanges, parcels and grammar buildings, instanced vegetation with impostors, agriculture, infrastructure); volumetric clouds with cloud shadows; autopilot HDG/ALT/VS/NAV; VOR/NDB/DME + synthetic ILS; flight recorder/replay; logbook; GPU-driven culling. Accept: autopilot capture tests pass; replay hash equality; WorldGen determinism tests; all ten §8.5 scenes rendered and reviewed against §8.1 with a logged critique and fixes; sharpness and temporal-stability metrics above thresholds; GPU-time regression guard passes.

**P3 Fidelity, content, polish.** OSM Overpass integration for real footprints/roads/water where available; ocean FFT; night world; MetalFX/TAA/sharpening tuned; terrain virtual texture; storage manager UI and offline regions; full key-binding UI; accessibility pass; EGM96 (if terms verified); COG reader. Accept: storage tests pass; accessibility audit passes; offline region download/resume/corruption tests pass; visual regression baseline re-approved with logged review; device-tier governor tests pass.

**P4 Simulation breadth.** ATC with speech; AI traffic; glider/twin/turboprop/light jet; failures; US CIFP procedures; icing; macOS HID sticks; lessons and challenges. Accept: ATC scenario tests pass; each aircraft passes plausibility and trim tests.

**P5 Ecosystem.** MultipeerConnectivity shared flights/formation; GameKit (needs Game Center capability, manual); Background Assets packs; Metal 4 path; external display; career/missions. Accept: tests plus documented manual verification.

Keep `main-build` green and shippable. Do not start phase N+1 until phase N is accepted (research spikes in `docs/` excepted). After P2, spend a dedicated "visual polish and performance pass" cycle before P3: iterate screenshots against §8.1 until deficiencies are exhausted or documented as blocked.

## 17. MSFS WEAKNESS → SKYFORGE IMPROVEMENT MATRIX (evidence-tagged; mark "verified" or "anecdotal"; do not invent frequencies)
| Weakness | Evidence | Cause | MS fix? | SKYFORGE approach |
|---|---|---|---|---|
| Launch overload; cannot load or install | MSFS 2024 launch Nov 19, 2024; Steam "Overwhelmingly Negative"; Microsoft/Asobo said they "underestimated how high" demand was; access problems reported after added capacity. Verified | start-up depends on servers | mitigated by capacity and patches | no servers; everything needed to fly is bundled |
| Internet dependency | reviews call cloud streaming a double-edged sword. Common | streaming design | partial offline modes | offline-first, offline regions, procedural world fills gaps |
| Stutter, memory leaks after patches | Steam forum threads (Dec 2024). Anecdotal but repeated | streaming, shader compiles, asset spikes | several patches | fixed-step sim; pre-warmed pipelines; hitch budget; memory ceilings; generation off the render thread |
| Data-driven autogen errors | The Register 20 Aug 2020: a Melbourne house tagged 212 storeys in OSM appeared as a giant tower. Verified | unvetted automated data | patched individually | height sanity clamps by building type; provenance display; local overrides |
| Price and add-ons | editions $69.99–$199.99 at launch | business model | n/a | free, open-source, open formats |
| Large install | common, subjective magnitude | huge asset libraries | partial | bundle ≤ 150 MB; user quota ≤ 500 GB; procedural generation instead of stored imagery |
| Long loads | common, reproducible | server round trips and asset volume | partial | load-time targets; pre-warm |
| ATC/AI quality | common, subjective | rules/voices | ongoing | deterministic testable state machine |
| UI depth | common, subjective | console-first UI | partial | two-tap start; measured settings costs |

## 18. TRACEABILITY MATRIX (full version in docs/ARCHITECTURE.md)
| Feature | Justification | Implementation | Licence | Perf target | Difficulty | Test | Acceptance |
|---|---|---|---|---|---|---|---|
| FDM | JSBSim LGPL ambiguity → own model | SFFlightModel RK4 120 Hz | Apache-2.0 | ≤ 1 ms/step | High | unit, oracle, determinism | §9.3 |
| Terrain | Terrarium/Copernicus keyless and redistributable | SFTerrainCore CDLOD | data attribution | ≤ 4 ms GPU High tier | High | decode, mesh, height query | P2 |
| SkyWorld | free imagery cannot reach MSFS sharpness → own world | SFWorldGen + GPU instancing | own | frame budgets §11 | Very high | determinism, visual regression | P2 scenes |
| Sky | Hillaire 2020 suits mobile | compute LUTs | own | ≤ 1 ms GPU | Medium | shader compile, smoke | P1 |
| Clouds | Schneider 2015 | quarter-res raymarch + reprojection | own | ≤ 3 ms iPhone | High | smoke, governor | P2 |
| Airports | OurAirports public domain | bundled DB + update | PD | n/a | Medium | parser, geometry | P1 |
| Weather | AWC keyless; Open-Meteo free for non-commercial apps | SFWeather + cache | PD / CC BY 4.0 | negligible | Medium | fixtures, fuzz | P1/P2 |
| Storage | 500 GB configurable, not guaranteed | SFContent CAS | Apache-2.0 | I/O off main | Medium | quota, corruption | P3 |
| Input | GameController lacks HID sticks on iOS | SFInput + adapters | own | < 0.1 ms | Medium | binding tests | P3 |
| ATC | on-device speech, no cloud | SFATC | own | low | High | scenario tests | P4 |

## 19. RISK REGISTER
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Procedural world falls short of target look | High | High | early golden scenes, subagent visual critique each milestone, tiered quality ladder, polish pass after P2 |
| Hand-written pbxproj fails in Xcode | Medium | High | minimal project, synchronized folders, CI validation, XcodeGen fallback |
| Hallucinated/deprecated Apple API | Medium | High | macOS CI compile, SDK header checks, `#if canImport` isolation, ADR per new framework |
| Metal toolchain missing at build | Medium | High | runtime shader compilation; no `.metal` files |
| Thermal throttling and jetsam on iPhone | High | High | governor, 30 fps sustained mode, memory budgeting, cache halving |
| Data source terms change | Medium | Medium | optional/offline fallbacks, configurable hosts, re-verify each phase |
| App Store rejection | Low–Medium | High | §13 checklist, data-only packages, bundled offline core |
| Licence contamination | Low | High | audit gate in `gate.sh ci` |
| Scope overrun | High | Medium | phase gates, PROGRESS.md discipline |
| Trademark/IP issues | Low | High | original names, assets and aircraft; no Microsoft assets |

## 20. FEASIBILITY CLASSIFICATION (also put in README)
- Technically achievable: 6-DOF GA flight model, ISA/WGS84, global DEM terrain, worldwide airports and runways, METAR weather, physically based sky and cascaded shadows, rebindable input, replay, offline mode, multiplatform Apple app.
- Substantial development: SkyWorld near-field autogen at high sharpness, volumetric clouds tuned for iPhone, tensor-field roads and highways, grammar buildings, instanced forests with impostors, OSM-driven real footprints, glass cockpit and NAV autopilot, rule-based ATC with speech, AI traffic, jets/turboprops, ocean FFT, Metal 4/MetalFX paths.
- Significant compromises: helicopter flight model, airliner systems depth, worldwide procedures (synthetic outside the US), exact real-world building likeness.
- Currently impractical (free and keyless): MSFS-class global photogrammetry and aerial imagery; GRIB2 weather ingestion at MSFS fidelity on device.
- Dependent on restricted resources: Navigraph-grade navdata, licensed live traffic, Google 3D Tiles, HOTAS on iOS, Game Center/Background Assets configuration.

## 21. RULES AND PHILOSOPHY (restate before each phase)
Never fake functionality; never claim untested features work; never ignore compiler or runtime errors; never sacrifice simulation accuracy for appearance, and never sacrifice smooth performance for visual quality without recording it; no paid dependencies; never violate licences or use Microsoft assets or code; never assume all Apple devices are equal; keep modules separate (rendering, physics, systems, networking, storage, UI, world generation); document decisions; write tests; profile; test offline, storage limits, corrupted downloads, input devices, aircraft and weather; look at your own screenshots; fix issues before declaring completion; work incrementally and keep `main-build` green; you are alone, so be your own reviewer.

## 22. DEFINITION OF DONE (autonomous run)
1. P0, P1 and P2 are accepted; P3 is accepted or each unaccepted item is documented with its reason in STATE.md. (Continue into P4 and P5 if time and limits allow; the wrapper keeps running.)
2. `tools/gate.sh ci` is green on Linux. CI `apple` is green on the final commit (iPhone and iPad simulators, macOS) if CI results are readable; otherwise `docs/PR_BODY.md` says exactly what remains unverified until Mac day. Links recorded in VERIFICATION_LOG.md.
3. All ten §8.5 scenes have reviewed screenshots in VISUAL_LOG.md with measured sharpness and temporal-stability metrics, and PERFORMANCE.md lists the measured (or honestly "not measurable in CI") frame-time results per tier.
4. README covers: opening `SKYFORGE.xcodeproj`, choosing a team and running; the feasibility table; data attributions and licences; known limitations; how to resume work (scheduled task or typing "continue") and the Mac-day steps in `docs/MAC_DAY.md`.
5. APPSTORE_CHECKLIST.md complete, with items needing the user explicitly listed.
6. No TODO/FIXME in shipped code paths without a linked PROGRESS.md item; no compiler warnings in our sources.
7. Then create `SKYFORGE_DONE`, update `docs/PR_BODY.md`, run `gh pr ready`.

## 23. PULL REQUEST INSTRUCTIONS
Branch `skyforge/main-build` from the default branch. Open ONE draft PR during P0: `gh pr create --draft --title "SKYFORGE: multiplatform flight simulator (SkyWorld procedural world + roadmap)" --body-file docs/PR_BODY.md` (on Claude Code on the web use whatever GitHub tool is available; if none can create a pull request, push the branch and keep `docs/PR_BODY.md` ready so the user can tap Create PR on the iPad). Keep pushing to the same PR and keep PR_BODY.md current: summary, what works (verified), what does not, test evidence (CI run links, screenshots), manual steps for the user (signing team, bundle ID, App Store Connect items), licence and attribution summary, roadmap. Never merge it yourself. Never force-push over green history except to remove an accidentally committed large file.

## 24. MAC DAY (create and maintain `docs/MAC_DAY.md`)
The user will later get a Mac, pull the branch and open it in Xcode. `docs/MAC_DAY.md` must contain, in plain steps for a non-expert:
1. Prerequisites: a Mac with Xcode 26.6 or newer, an Apple ID (a free personal team is enough to run on your own device; the paid Apple Developer Program is needed for TestFlight and the App Store).
2. Get the code: merge the PR (or check out `skyforge/main-build`), `git pull`, open `SKYFORGE.xcodeproj`, choose your Team under Signing & Capabilities, change the bundle identifier prefix, pick My Mac or an iPhone/iPad, press Run.
3. Run `tools/gate.sh full` and read `docs/APPLE_API_LEDGER.md` (the unverified APIs are the first suspects for compile errors).
4. If anything fails to build or looks wrong: start Claude Code in the repo folder on the Mac and paste this prompt: "You are on a Mac with Xcode. Repository: SKYFORGE. Read docs/MASTER_PROMPT.md, docs/STATE.md and docs/APPLE_API_LEDGER.md. Work autonomously, never ask questions. (1) Fix every compile error first, starting with the unverified ledger APIs, using xcodebuild for iOS Simulator and macOS. (2) Run tools/gate.sh full until green. (3) Run the Metal renderer and visual-regression tests, compare with docs/previews and the targets in §8, and iterate on beauty and sharpness. (4) Profile with Instruments on the Mac and, when a device is connected, on the device; update docs/PERFORMANCE.md with honest measured numbers. (5) Commit small, keep the PR updated."
5. Device testing checklist: thermals over 20 minutes, frame pacing, memory, offline mode, input devices, accessibility.
6. App Store steps that cannot be automated: App Store Connect app record, privacy nutrition label, age-rating questionnaire, screenshots, export compliance, TestFlight, submission.

START NOW: do Step 0.1, then §2 (auto-resume and environment setup), then P0. The user is away on an iPad. Do not ask questions.
