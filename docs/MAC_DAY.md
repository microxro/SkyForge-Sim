# Mac day

Plain steps for the day you have a Mac with Xcode.

## 1. Prerequisites
- A Mac with Xcode 26.6 or newer (Xcode 27 is fine).
- An Apple ID. A free personal team is enough to run on your own Mac, iPhone or iPad. The paid Apple Developer Program is needed for TestFlight and the App Store.

## 2. Get the code and run it
1. On GitHub, merge the SKYFORGE pull request (or check out branch `claude/ecstatic-davinci-tjahz4`).
2. In Terminal: `git clone <repo URL>` (or `git pull` if you already have it), then `cd SkyForge-Sim`.
3. Open `SKYFORGE.xcodeproj` (double-click it).
4. Click the SKYFORGE project in the left sidebar → target SKYFORGE → Signing & Capabilities → choose your Team.
5. Change the bundle identifier prefix from `org.skyforge` to something unique to you (for example `com.yourname.SKYFORGE`).
6. Pick a run destination at the top: My Mac, or a connected iPhone/iPad, or a simulator.
7. Press Run (⌘R).

## 3. Check everything
- In Terminal: `tools/gate.sh full`.
- Read `docs/APPLE_API_LEDGER.md`. APIs marked "unverified" are the first suspects for compile errors.

## 4. If something fails to build or looks wrong
Start Claude Code in the repository folder on the Mac and paste:

> You are on a Mac with Xcode. Repository: SKYFORGE. Read docs/MASTER_PROMPT.md, docs/STATE.md and docs/APPLE_API_LEDGER.md. Work autonomously, never ask questions. (1) Fix every compile error first, starting with the unverified ledger APIs, using xcodebuild for iOS Simulator and macOS. (2) Run tools/gate.sh full until green. (3) Run the Metal renderer and visual-regression tests, compare with docs/previews and the targets in §8, and iterate on beauty and sharpness. (4) Profile with Instruments on the Mac and, when a device is connected, on the device; update docs/PERFORMANCE.md with honest measured numbers. (5) Commit small, keep the PR updated.

## 5. Device testing checklist
- Thermals over a 20-minute flight (does the frame rate stay steady?).
- Frame pacing (Instruments → Metal System Trace).
- Memory (Instruments → Allocations; stay under the ceilings in MASTER_PROMPT §11).
- Offline mode (airplane mode, then start a flight).
- Input devices (touch, keyboard, gamepad).
- Accessibility (VoiceOver, Dynamic Type, Reduce Motion).

## 6. App Store steps that cannot be automated
App Store Connect app record, privacy nutrition label, age-rating questionnaire, screenshots, export compliance, TestFlight, submission.
