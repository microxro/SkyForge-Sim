# Round 5: scenery and lighting (brief for workers)

Rules for every worker:
- Swift 6 + Metal, Apache-2.0, free/open assets only (procedural preferred). Keep repo growth under 200 KB per feature.
- No Swift toolchain in the cloud. Write carefully; CI compiles. Check MSL with `python3 tools/msl_check/check_msl.py <YourShaders>.swift`.
- ONLY create new files (Sources/SFRender/..., Sources/SFRender/Shaders/..., Tests/..., docs/rounds/ROUND5_<area>.md). Do NOT edit WorldShaders.swift, WorldRenderer.swift or other existing files: another thread owns them. Instead write docs/rounds/ROUND5_<area>.md with exact old/new edit snippets for integration.
- Each feature: pure-Swift CPU reference/params (testable on Linux), MSL source in a `public enum XShaders { public static let source = """ ... """ }`, XCTest/swift-testing tests matching neighbouring test style, tier knobs (low/medium/high/ultra).
- Do not git commit or push; the lead does that. Report files written, in under 120 words.
