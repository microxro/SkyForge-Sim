## Summary
SKYFORGE bootstrap (Phase 0): auto-resume hooks, a Swift 6 package with all 17 modules, a hand-written multiplatform Xcode project, CI, and the documentation set. Built and tested on Linux; Apple-only code has not been compiled yet.

## What works (verified on Linux, Swift 6.3.3)
- `swift build` with no warnings in our sources; `swift test`: 30 tests pass.
- WGS84 geodesy (<1 mm round trip over 10,000 random points), quaternions, deterministic PRNG and noise.
- US Standard Atmosphere 1976 within 0.1% of reference tables; CAS/TAS/EAS conversions.
- Fixed 120 Hz simulation clock and triple buffer.
- SHA-256 content store with atomic install and corruption detection.
- Pure-Swift PNG encoder and procedurally generated app icon.
- SF-1 Trainer flight model: 6-DOF at 120 Hz with trim, stall, energy, determinism and 1-hour fuzz tests.
- Xcode project passes a Linux structural lint.

## Not done / unverified
- Apple-only code (Metal sky renderer, SwiftUI menu, device tiers, Xcode project, asset catalog) has never been compiled. It will be checked by the macOS CI job if it runs, otherwise on Mac day (`docs/MAC_DAY.md`).
- No flight model, terrain or SkyWorld yet (Phase 1).

## Test evidence
`docs/VERIFICATION_LOG.md`.

## For you (nothing needed now)
- If CI fails, paste the failing log as a message and it will be fixed.
- If `.github/workflows/ci.yml` is missing on GitHub, add it (Add file → Create new file) by pasting `docs/ci.yml.template`.
- To resume after a session ends, send: continue
- Later: choose a signing team and bundle ID prefix in Xcode (`docs/MAC_DAY.md`).

## Licences
Apache-2.0. Only dependency: apple/swift-crypto (Apache-2.0). No GPL/LGPL code.

## Roadmap
P1 vertical slice (flight model, terrain, CPU previews, first SkyWorld layers) → P2 rich world → P3 fidelity → P4 breadth → P5 ecosystem. See `docs/MASTER_PROMPT.md` §16.
