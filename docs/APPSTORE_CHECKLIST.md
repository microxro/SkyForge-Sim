# App Store checklist

| Item | Status | Needs the user? |
|---|---|---|
| Built with Xcode 26+ / iOS 26 SDK | pending Mac day | yes (build machine) |
| PrivacyInfo.xcprivacy: NSPrivacyTracking false; UserDefaults CA92.1, FileTimestamp C617.1, DiskSpace E174.1 | present; reason codes to re-verify against Apple's current page before submission | no |
| No tracking/analytics/accounts; nutrition label "Data Not Collected" | by design | yes (App Store Connect form) |
| ITSAppUsesNonExemptEncryption = NO | present in Info.plist | no |
| No placeholder features (2.1) | unavailable items are labelled "not yet available" | no |
| Data-only packages, no downloaded code (2.5.2) | by design | no |
| Offline core flight from bundle (4.2) | pending P1 | no |
| macOS App Sandbox + network.client, hardened runtime | entitlements present | no |
| No trademarks (Microsoft, Flight Simulator, Cessna, Garmin, airlines) | by design | no |
| In-app attributions | pending P1 UI | no |
| Age rating questionnaire, screenshots, export compliance, TestFlight | — | yes |
