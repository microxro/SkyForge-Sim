# Xcode setup, step by step

For someone who has never opened this project. Takes about 15 minutes plus the first build.

## What you need
- A Mac running macOS 26 or newer with **Xcode 26.6 or newer** (free in the Mac App Store).
- An Apple ID. A free account runs the app on your own Mac, simulator, iPhone or iPad. The paid Apple Developer Program is only needed for TestFlight and the App Store.
- About 10 GB of free disk space.

## 1. Clone
In Terminal:
```
git clone https://github.com/microxro/SkyForge-Sim.git
cd SkyForge-Sim
```
To try a pull request branch instead: `git checkout <branch-name>`.

## 2. Open the project
```
open SKYFORGE.xcodeproj
```
Open the `.xcodeproj`, not the `Packages/SkyforgeKit` folder. The project already links the local Swift package `SkyforgeKit` (all game code lives there) and the only external dependency, swift-crypto, downloads by itself on first open (watch the progress at the top of Xcode: "Fetching" then "Resolving"). There are no CocoaPods, no other setup scripts, and no API keys.

If Xcode shows a package error, use File > Packages > Reset Package Caches, then File > Packages > Resolve Package Versions.

## 3. Choose a team (signing)
1. Click the blue **SKYFORGE** project at the top of the left sidebar.
2. Select the **SKYFORGE** target, then the **Signing & Capabilities** tab.
3. Tick **Automatically manage signing**.
4. Under **Team**, choose your Apple ID (Xcode > Settings > Accounts > + to add one).
5. Change **Bundle Identifier** from `org.skyforge.SKYFORGE` to something unique to you, for example `com.yourname.skyforge`. Apple rejects identifiers that someone else already owns.

## 4. Run
- **Mac:** pick **My Mac** at the top, press Run (Cmd+R).
- **Simulator:** pick any iPhone or iPad simulator, press Run. The simulator's GPU is slower than a real device, so judge speed on hardware.
- **iPhone or iPad:** connect with a cable, unlock it, tap Trust. On the device turn on Settings > Privacy & Security > Developer Mode (it restarts the device). Pick the device at the top and press Run. The first time, on the device open Settings > General > VPN & Device Management and trust your developer certificate.

In the app, tap **Fly now: Monterey**. The six bundled airports work offline.

## 5. Run the tests
- In Xcode: choose the SKYFORGE scheme, then Product > Test (Cmd+U) runs what the scheme includes.
- The full suite lives in the Swift package. In Terminal:
  ```
  swift test -c release -Xswiftc -enable-testing --package-path Packages/SkyforgeKit --skip ShowcaseRenderTests
  tools/gate.sh full        # build, tests, project lint, iOS Simulator and macOS builds
  ```
- Rendered review frames: `swift test -c release -Xswiftc -enable-testing --package-path Packages/SkyforgeKit --filter ShowcaseRenderTests` (needs a Mac with a GPU).

## 6. Archive for TestFlight or the App Store
You need the paid Apple Developer Program and an app record in App Store Connect. The owner-only list is in `docs/appstore/OWNER_TODO.md` and the store text in `docs/appstore/METADATA.md`.
1. Set the **Team** and a unique **Bundle Identifier** (step 3).
2. Raise the version in the target's General tab: **Version** (marketing) and **Build** (must grow with every upload).
3. Pick **Any iOS Device (arm64)** (or **My Mac**) at the top.
4. Product > Archive. When the Organizer opens, choose **Distribute App > App Store Connect > Upload**.
5. In App Store Connect, wait for processing, add the build to TestFlight, test, then submit for review.

No Mac handy? The manual GitHub Actions workflow `release-archive.yml` builds the archives in the cloud (unsigned unless you add the signing secrets it lists).

## If something goes wrong
| Symptom | Fix |
|---|---|
| "Signing requires a development team" | Step 3. |
| "No such module" or package errors | File > Packages > Reset Package Caches, then Resolve. |
| Deployment target error | You need Xcode 26.6 or newer; the app targets iOS and macOS 26. |
| Black screen in the simulator | Try a physical device or My Mac. Metal in the simulator is limited. |
| Compile error in Metal or SwiftUI code | The Apple-only code is verified by macOS CI, not by the people who write it. Copy the first error into a GitHub issue, or run Claude Code in the repo folder and paste it. See `docs/MAC_DAY.md` section 4. |
