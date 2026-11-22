# Owner-only steps (need your Apple account or devices)

Nothing here can be done from the repository. In order:

1. Enrol in the Apple Developer Program (paid) if not already.
2. Pick a unique bundle identifier. `org.skyforge.SKYFORGE` is a placeholder and must belong to a domain or name you control. Change `PRODUCT_BUNDLE_IDENTIFIER` in `SKYFORGE.xcodeproj` (and `project.yml`).
3. Set `DEVELOPMENT_TEAM` to your Team ID (Signing & Capabilities in Xcode).
4. Create the app record in App Store Connect (iOS and macOS under one bundle ID) and fill in `docs/appstore/METADATA.md`.
5. Host `PRIVACY_POLICY.md` at a public URL and enter it.
6. Answer the App Privacy ("Data Not Collected"), age rating and export compliance forms.
7. Take screenshots (iPhone, iPad, Mac) on real hardware or simulators.
8. Replace the app icon if you want different artwork: `App/Assets.xcassets/AppIcon.appiconset`.
9. Verify on a real iPhone, iPad and Mac: frame rate, thermals, memory (see `docs/MAC_DAY.md`). This repo's CI has not run on-device.
10. For CI builds on TestFlight (no Mac needed): follow `docs/TESTFLIGHT.md`. It covers the bundle ID variable, the App Store Connect API key, the distribution certificate, the `release` environment and secrets, and the manual "Release archive" run with TestFlight upload. Test in TestFlight, then submit for review.
11. Re-check the privacy manifest reason codes against Apple's current required-reason API list.

Note on privacy reason codes: no first-party source calls UserDefaults, file timestamp or disk-space APIs directly (grepped 2026-11-22). The manifest declares CA92.1, C617.1 and E174.1 defensively because Apple frameworks and SwiftPM resources may use them. Trim the manifest if Xcode's privacy report on the archive shows they are unused.
