LAST_UPDATE: 2026-11-07T22:05:33Z

# SKYFORGE state

## Phase
P0 Bootstrap — in progress (see PROGRESS.md CURRENT).

## Environment facts (recorded at session start)
- Host: Linux x86_64, Ubuntu 24.04.5 LTS, 4 CPUs, 15 GB RAM (Claude Code on the web sandbox).
- Swift: 6.3.3-RELEASE installed by `tools/setup_env.sh` into `~/.skyforge-toolchain` (download.swift.org reachable).
- No Mac, no Xcode, no Metal device. Apple-only code is author-only until CI or Mac day.
- GitHub: `gh` CLI present but GitHub access goes through the session's GitHub tools; the GitHub MCP plugin failed to connect at session start (proxy 403). Pushing over git works through the session proxy.
- Workflow push permission: unknown until tried (see VERIFICATION_LOG.md).
- Branch: work happens on `claude/ecstatic-davinci-tjahz4` (the branch this session is required to use), not `skyforge/main-build`. See ADR-0001.

## Auto-resume
- Project hooks installed in `.claude/settings.json` (SessionStart, Stop guard, StopFailure, PreCompact).
- `autoContinueAtUsageLimit: true` is set in the session's user settings (`~/.claude/settings.json`); the user asked for this instead of a scheduled task, so no "SKYFORGE resume" scheduled task was created (ADR-0002).
- Fallback: send the message "continue" to resume.

## What works (verified on Linux)
- `swift build` and `swift test` for SkyforgeKit (see VERIFICATION_LOG.md).
- SFMath: WGS84 geodetic/ECEF/ENU (<1 mm round trip over 10k points), quaternions, Xoshiro256/SplitMix64, gradient noise.
- SFAtmosphere: USSA-76 to 86 km within 0.1% of tables; CAS/TAS/EAS.
- SFSim: fixed-step clock (1/120 s, 8 substep cap), triple buffer.
- SFContent: SHA-256 content store with atomic install and corruption detection.
- SFPreview: PNG encoder; procedural app icon.
- Xcode project passes the Linux lint (`tools/lint_pbxproj.py`).

## What is unverified
- Everything Apple-only: SFRender (sky pipeline), SFUI, SFPlatform, the Xcode project, Info.plist, asset catalog. First compile happens in CI (if readable) or on Mac day.

## Broken
- Nothing known.

## Last green SHA
- (updated after each green commit)
