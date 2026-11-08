# Verification log
Every gate run, CI run and manual verification. Newest at the bottom.

- 2026-11-07 Linux: `swift build` (SkyforgeKit, Swift 6.3.3) PASS, no warnings in our sources.
- 2026-11-07 Linux: `swift test` 18 tests / 7 suites PASS.
- 2026-11-07 Linux: PNG encoder output decoded by Python zlib with valid CRCs.
- 2026-11-07 Linux: `tools/lint_pbxproj.py` OK (19 objects).
- 2026-11-07T22:07:26Z gate ci on Linux x86_64: PASS (HEAD 496a206)
- 2026-11-07T22:17:15Z gate fast on Linux x86_64: PASS (HEAD 8e8e74b)
- 2026-11-07 GitHub Actions run 42419165830 (PR #1, 8e8e74b): linux PASS; apple FAIL at `swift test` (macOS): link error, SFPreview/sfpreview case collision. Fix: rename CLI target to SFPreviewCLI.
- 2026-11-07 Linux: gate fast PASS, 30 tests / 8 suites (includes 1-hour fuzz, ~60 s in debug).
- 2026-11-07 Found and fixed during P1.1: elevator/rudder sign convention inverted; thrust model too weak at cruise; stall blend too wide. Each now covered by a test (ControlSenseTests, trim throttle bounds, stall speed).
- 2026-11-07T22:19:16Z gate fast on Linux x86_64: PASS (HEAD 8e8e74b)
- 2026-11-07 Linux: SFTerrainCore tests 9/9 PASS (inflate stored/fixed/dynamic, Terrarium Rainier fixture max 4370 m matches Python reference, tile math, CDLOD coverage and neighbour LOD ≤ 1).
- 2026-11-07T22:23:31Z gate fast on Linux x86_64: PASS (HEAD 7006d81)
- 2026-11-07 GitHub Actions run 42420061164 (7006d81): linux PASS; apple: macOS `swift test` PASS, iOS Simulator xcodebuild FAIL only at `import SkyforgeUI` in App (module name is SFUI). All SkyforgeKit modules compiled for iOS Simulator (arm64 + x86_64), including SFRender and SFUI.
- 2026-11-07 Linux: WorldGen tests (determinism, placement, river bed below water) and renderer tests PASS.
- 2026-11-07T22:41:29Z gate fast on Linux x86_64: PASS (HEAD 0dc207a)
- 2026-11-07 Linux: METAR tests 9/9 (230 real fixtures; 5,000 fuzzed mutations) and WeatherState tests 2/2 PASS.
- 2026-11-07T22:46:06Z gate fast on Linux x86_64: PASS (HEAD f5fe3da)
- 2026-11-07 GitHub Actions run 42421809423 (f5fe3da): linux PASS; apple PASS — macOS swift test, xcodebuild iOS Simulator (generic) and macOS app builds all succeeded with the hand-written project.
- 2026-11-07 Linux: Vincenty geodesic tests (Flinders Peak reference within 1 cm; 500 direct/inverse round trips < 1 mm) and NavData tests 6/6 PASS.
- 2026-11-07T22:50:03Z gate fast on Linux x86_64: PASS (HEAD 00b1324)
- 2026-11-07 Linux: SFInput tests 7/7 PASS.
- 2026-11-07T22:53:15Z gate fast on Linux x86_64: PASS (HEAD 85fef52)
- 2026-11-07 Linux: scripted circuit integration PASS (595 s flight; touchdown −252 fpm at 268 m past threshold; stop at 449 m, on centre-line; max bank 28.6°); crosswind 8 kt variant PASS; PID anti-windup PASS.
- 2026-11-07T22:56:32Z gate fast on Linux x86_64: PASS (HEAD be24179)
- 2026-11-07T23:00:00Z gate fast on Linux x86_64: PASS (HEAD c0e3a7e)
- 2026-11-07T23:04:21Z gate fast on Linux x86_64: PASS (HEAD ba272ae)
- 2026-11-07 Linux: bundled OurAirports snapshot loads (counts match manifest), updater rejects ±20 % mismatches and installs atomically; runway geometry tests PASS. CI run 42423187878: linux PASS, apple package tests + iOS Simulator build PASS (GameController adapter compiled).
- 2026-11-07T23:07:39Z gate ci on Linux x86_64: PASS (HEAD 1a25cce)
- 2026-11-07 Linux: GlobalDEM tests PASS (SHA-256 matches manifest; Himalaya > 4.5 km, Dead Sea < −200 m, Pacific < −2 km, Denver 1.4–1.9 km).
- 2026-11-07T23:10:58Z gate fast on Linux x86_64: PASS (HEAD 8890222)
2026-11-07T23:45:04Z compaction; last commit 765faf4
2026-11-08T01:37:28Z compaction; last commit 765faf4
2026-11-08T01:37:29Z compaction; last commit 765faf4
2026-11-08T01:37:31Z compaction; last commit 765faf4
2026-11-08T01:37:32Z compaction; last commit 765faf4
2026-11-08T02:31:39Z compaction; last commit 765faf4
- 2026-11-08T02:35:15Z gate fast on Linux x86_64: PASS (HEAD 50fdfb9)
- 2026-11-08T02:48:57Z gate fast on Linux x86_64: PASS (HEAD 35ffabc)
- 2026-11-08T02:52:22Z gate fast on Linux x86_64: PASS (HEAD ccad711)
- 2026-11-08T02:56:19Z gate fast on Linux x86_64: PASS (HEAD 0b7fa70)
- 2026-11-08T03:01:24Z gate fast on Linux x86_64: PASS (HEAD cabd42a)
- 2026-11-08T03:07:12Z gate fast on Linux x86_64: PASS (HEAD 0e3abf5)
- 2026-11-08T03:14:37Z gate fast on Linux x86_64: PASS (HEAD 7a9c9de)
- 2026-11-08T03:15:25Z CI run 42441371307 (7a9c9de) apple job failed: macOS Swift type-checker timeout in VisualRegressionTests.swift:85 (closure max over Int sums); Linux compiled it. Fixed by an explicit loop.
- 2026-11-08T03:26:41Z gate fast on Linux x86_64: PASS (HEAD 153f54f)
- 2026-11-08 CI run 42441951368 (153f54f): green. macOS runner has a Metal device; `metalOffscreenSkyMatchesCPUReference` passed (31 s incl. pipeline compile). First execution of SKYFORGE Metal code.
- 2026-11-08T03:30:30Z gate fast on Linux x86_64: PASS (HEAD 4a2ec0b)
- 2026-11-08T03:33:20Z gate fast on Linux x86_64: PASS (HEAD e7ec488)
- 2026-11-08T03:43:47Z gate fast on Linux x86_64: PASS (HEAD 26b9136)
- 2026-11-08T03:50:38Z gate fast on Linux x86_64: PASS (HEAD 13988f3)
- 2026-11-08T03:52:21Z gate fast on Linux x86_64: PASS (HEAD 6af186e)
- 2026-11-08T03:54:46Z gate fast on Linux x86_64: PASS (HEAD dc6f294)
- 2026-11-08T04:01:39Z gate fast on Linux x86_64: PASS (HEAD c5bf988)
- 2026-11-08T04:13:29Z gate fast on Linux x86_64: PASS (HEAD 28f80d3)
- 2026-11-08T04:29:44Z gate fast on Linux x86_64: PASS (HEAD b52fdf2)
- 2026-11-08T04:57:12Z gate fast on Linux x86_64: PASS (HEAD ac9bd29)
2026-11-08T05:01:33Z compaction; last commit b7c85a7
- 2026-11-08T05:04:34Z gate fast on Linux x86_64: PASS (HEAD b7c85a7)
- 2026-11-08T05:09:15Z gate fast on Linux x86_64: PASS (HEAD b3c7fc1)
- 2026-11-08T05:18:25Z gate fast on Linux x86_64: PASS (HEAD 07fa249)
- 2026-11-08T05:23:12Z gate fast on Linux x86_64: PASS (HEAD 0f54823)
- 2026-11-08T10:38:05Z gate fast on Linux x86_64: PASS (HEAD ba49bb5)
- 2026-11-08T10:40:13Z gate fast on Linux x86_64: PASS (HEAD 1c3a32d)
- 2026-11-08T10:43:01Z gate fast on Linux x86_64: PASS (HEAD 20f9dfe)
- 2026-11-08T10:47:07Z gate fast on Linux x86_64: PASS (HEAD 54bc981)
- 2026-11-08T10:51:04Z gate fast on Linux x86_64: PASS (HEAD caee43d)
- 2026-11-08T11:06:29Z gate fast on Linux x86_64: PASS (HEAD 9a01b94)
- 2026-11-08T11:15:28Z gate fast on Linux x86_64: PASS (HEAD 5aee5ff)
- 2026-11-08T11:17:14Z gate fast on Linux x86_64: PASS (HEAD 3ddd2f2)
- 2026-11-08T11:30:39Z gate fast on Linux x86_64: PASS (HEAD 29a7c98)
- 2026-11-08T11:41:21Z gate fast on Linux x86_64: PASS (HEAD 6881210)
- 2026-11-08T11:56:28Z gate fast on Linux x86_64: PASS (HEAD 2574a29)
- 2026-11-08T12:01:28Z gate fast on Linux x86_64: PASS (HEAD 4ce0195)
- 2026-11-08T12:10:10Z gate fast on Linux x86_64: PASS (HEAD 1fa781b)
- 2026-11-08T12:13:21Z gate fast on Linux x86_64: PASS (HEAD 2fd78fd)
- 2026-11-08T12:18:11Z gate fast on Linux x86_64: PASS (HEAD f78185b)
- 2026-11-08T12:29:11Z gate fast on Linux x86_64: PASS (HEAD cc8a44e)
- 2026-11-08T12:36:46Z gate fast on Linux x86_64: PASS (HEAD 6366c4d)
- 2026-11-08T12:47:37Z gate fast on Linux x86_64: PASS (HEAD 3ec8ed6)
- 2026-11-08T12:54:08Z gate fast on Linux x86_64: PASS (HEAD bb86f49)
- 2026-11-08T12:57:24Z gate fast on Linux x86_64: FAIL (HEAD 3ee4868)
- 2026-11-08T12:57:46Z gate fast on Linux x86_64: FAIL (HEAD 3ee4868)
- 2026-11-08T13:03:15Z gate fast on Linux x86_64: PASS (HEAD 3ee4868)
- 2026-11-08T13:14:31Z gate fast on Linux x86_64: PASS (HEAD db3311a)
