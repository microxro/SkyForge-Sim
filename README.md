# SKYFORGE

A free, open-source (Apache-2.0) flight simulator for iOS, iPadOS and macOS, written in Swift 6 with a custom Metal renderer. The world ("SkyWorld") is generated procedurally on top of real elevation data, so it works offline and needs no accounts, API keys or paid services.

**Status: early development (Phase 0 bootstrap).** The app currently shows a menu and a renderer preview; flight is not available yet. See `PROGRESS.md` and `docs/STATE.md`.

## Open and run
1. Open `SKYFORGE.xcodeproj` in Xcode 26.6 or newer.
2. Choose your Team under Signing & Capabilities and change the bundle identifier prefix.
3. Pick My Mac, an iPhone or an iPad and press Run.
Full steps for a first Mac: `docs/MAC_DAY.md`.

## Develop on Linux
```
sh tools/setup_env.sh      # installs Swift 6.3.3 if needed
tools/gate.sh fast         # build, test, project lint
```

## Feasibility
- Technically achievable: 6-DOF GA flight model, ISA/WGS84, global DEM terrain, worldwide airports and runways, METAR weather, physically based sky and cascaded shadows, rebindable input, replay, offline mode, multiplatform Apple app.
- Substantial development: SkyWorld near-field autogen at high sharpness, volumetric clouds tuned for iPhone, tensor-field roads and highways, grammar buildings, instanced forests with impostors, OSM-driven real footprints, glass cockpit and NAV autopilot, rule-based ATC with speech, AI traffic, jets/turboprops, ocean FFT, Metal 4/MetalFX paths.
- Significant compromises: helicopter flight model, airliner systems depth, worldwide procedures (synthetic outside the US), exact real-world building likeness.
- Currently impractical (free and keyless): global photogrammetry and aerial imagery at commercial-simulator fidelity; GRIB2 weather ingestion at that fidelity on device.
- Dependent on restricted resources: commercial-grade navdata, licensed live traffic, Google 3D Tiles, HOTAS on iOS, Game Center/Background Assets configuration.

## Data and licences
Code: Apache-2.0 (`LICENSE`, `NOTICE`). Dependencies: `THIRD_PARTY_NOTICES.md`. Data sources and attribution text: `docs/DATA_SOURCES.md`. No GPL/LGPL code is shipped.

## Known limitations
No flight model, terrain or world generation yet. All Apple-only code (Metal, SwiftUI) has not been compiled yet; the first build happens in macOS CI or on a Mac.

## Resuming autonomous work
The Claude Code session is set to continue automatically after a usage limit resets. If a session has ended, send the message: **continue**.
