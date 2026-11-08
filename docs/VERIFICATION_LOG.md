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
- 2026-11-08T13:27:58Z gate fast on Linux x86_64: PASS (HEAD 601145b)
- 2026-11-08T13:37:23Z gate fast on Linux x86_64: PASS (HEAD 22a7b05)
- 2026-11-08T13:47:20Z gate fast on Linux x86_64: PASS (HEAD 4197c63)
- 2026-11-08T13:56:52Z gate fast on Linux x86_64: PASS (HEAD 8a14c05)
- 2026-11-08T14:09:21Z gate fast on Linux x86_64: PASS (HEAD fbe424d)
- 2026-11-08T14:20:35Z gate fast on Linux x86_64: PASS (HEAD a1edd3a)
- 2026-11-08T14:27:18Z gate fast on Linux x86_64: PASS (HEAD 7f5d86b)
- 2026-11-08T14:29:27Z gate fast on Linux x86_64: PASS (HEAD 7f5d86b)
- 2026-11-08T14:35:07Z gate fast on Linux x86_64: PASS (HEAD 6b84662)
- 2026-11-08T14:51:46Z gate fast on Linux x86_64: PASS (HEAD 7e449cd)
- 2026-11-08T15:02:26Z gate fast on Linux x86_64: PASS (HEAD 16be5ae)
- 2026-11-08T15:10:40Z gate fast on Linux x86_64: PASS (HEAD 62d3dab)
- 2026-11-08T15:18:38Z gate fast on Linux x86_64: PASS (HEAD d8f16dc)
- 2026-11-08T15:39:28Z gate fast on Linux x86_64: PASS (HEAD dedf69a)
2026-11-08T15:47:33Z compaction; last commit a037dcf
- 2026-11-08T15:50:31Z gate fast on Linux x86_64: PASS (HEAD a037dcf)
- 2026-11-08T16:12:03Z gate fast on Linux x86_64: PASS (HEAD 6fdcf2d)
- 2026-11-08T16:17:51Z gate fast on Linux x86_64: PASS (HEAD 4312654)
- 2026-11-08T16:25:34Z gate fast on Linux x86_64: PASS (HEAD d6cc313)
- 2026-11-08T16:34:53Z gate fast on Linux x86_64: PASS (HEAD 4876bc2)
- 2026-11-08T16:59:48Z gate fast on Linux x86_64: PASS (HEAD 7ba1a62)
- 2026-11-08T17:13:48Z gate fast on Linux x86_64: PASS (HEAD 42d95de)
- 2026-11-08T17:32:08Z gate fast on Linux x86_64: PASS (HEAD ee36845)
- 2026-11-08T17:38:35Z gate fast on Linux x86_64: PASS (HEAD c1b7148)
- 2026-11-08T17:41:57Z gate fast on Linux x86_64: PASS (HEAD a7811ae)
- 2026-11-08T17:46:31Z gate fast on Linux x86_64: PASS (HEAD d7d0402)
- 2026-11-08T17:50:01Z gate fast on Linux x86_64: PASS (HEAD b01526f)
- 2026-11-08T17:54:12Z gate fast on Linux x86_64: PASS (HEAD ae6d560)
- 2026-11-08T18:02:39Z gate fast on Linux x86_64: PASS (HEAD de17bc4)
- 2026-11-08T18:04:55Z gate fast on Linux x86_64: PASS (HEAD 9b28780)
- 2026-11-08T18:08:42Z gate fast on Linux x86_64: PASS (HEAD 8baafbe)
- 2026-11-08T18:11:29Z gate fast on Linux x86_64: PASS (HEAD 6988cd8)
- 2026-11-08T18:16:30Z gate fast on Linux x86_64: PASS (HEAD 14442a8)

## 2026-11-08 GPU frame times on the CI Metal device (virtual macOS GPU; not a phone or Mac — device numbers unverified)
Method: `FrameTimeTests`, 30 frames after 3 warm-up frames; command-buffer GPU timestamps; fixed final-approach camera.
- Run 42506926611 (before tier presets):
  - SkyWorld: low 1280×720, median 9.41 ms; high 1920×1080, 22.93 ms.
  - KMRY: low 10.01 ms; high 31.94 ms.
- Run 42508494805 (high preset 0.85 scale, third-resolution 56-step clouds):
  - SkyWorld: low 8.39 ms; high 17.04 ms (clouds 4.63, shadows 2.38, bloom 0.74 ms).
  - KMRY: low 10.38 ms; high 23.49 ms (shadows 11.83: every tree instance drawn into both cascades).
- Fix: tree instances are binned into 400 m cells and culled per view and per cascade; terrain chunks are culled per cascade. The high preset is now 0.8 scale with 48 cloud steps.
- 2026-11-08T20:39:27Z gate fast on Linux x86_64: PASS (HEAD c536a22)
- 2026-11-08T20:46:24Z gate fast on Linux x86_64: PASS (HEAD f9f7904)
2026-11-08T20:46:58Z compaction; last commit cba2288
- 2026-11-08T21:25:10Z gate fast on Linux x86_64: PASS (HEAD cba2288)
- 2026-11-08T21:38:33Z gate fast on Linux x86_64: PASS (HEAD 54a8841)

## 2026-11-08 CI run 42525189171 (54a8841, macos-26 virtual GPU) — frame times
- SkyWorld low 1280×720: median 9.22 ms (budget 33.3). High 1920×1080: median 16.14 ms (budget 16.7); clouds 5.30, shadows 3.66, bloom 1.13, SSAO 1.23.
- KMRY low: median 8.55 ms. High: median 14.83 ms; clouds 3.19, shadows 3.36, bloom 0.34, SSAO 0.45.
- Diagnostic: real-terrain chunks drawn with `baseVertex` came out wrong on this GPU (fixed in debba5b with absolute indices).
- Device numbers: unverified (no hardware run).
- 2026-11-08T21:46:31Z gate fast on Linux x86_64: PASS (HEAD 850bcad)
- 2026-11-08T21:53:11Z gate fast on Linux x86_64: PASS (HEAD 873eaf5)
- 2026-11-08T21:55:27Z gate fast on Linux x86_64: PASS (HEAD 873eaf5)
- 2026-11-08T21:59:23Z gate fast on Linux x86_64: PASS (HEAD 4618a1c)

## 2026-11-08 CI run 42526879763 (873eaf5) — isolated GPU frame-time step
- SkyWorld low 8.19 ms, high 15.72 ms (budget 16.7): pass.
- KMRY low 9.62 ms; high 18.99 ms: over budget. The near terrain ring is now actually drawn (before debba5b the CI GPU dropped it).
- Fix in the next commit: desktop real-terrain mesh 8 → 12 m (mid 48 m, far 240 m), trees capped at 120k and thinned with distance.
