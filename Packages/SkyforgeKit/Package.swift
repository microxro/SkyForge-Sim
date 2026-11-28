// swift-tools-version: 6.2
// SKYFORGE — Apache-2.0. See LICENSE and THIRD_PARTY_NOTICES.md at the repository root.
import PackageDescription

let package = Package(
    name: "SkyforgeKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SkyforgeUI", targets: ["SFUI"]),
        .library(name: "SkyforgeCore", targets: ["SFMath", "SFAtmosphere", "SFFlightModel", "SFSim"]),
        .library(name: "SkyforgeGameplay", targets: ["SFGameplay", "SFGameplayUI"]),
        .executable(name: "sfpreview", targets: ["SFPreviewCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.2"),
    ],
    targets: [
        // Pure Swift (Linux-testable)
        .target(name: "SFMath"),
        .target(name: "SFAtmosphere", dependencies: ["SFMath"]),
        .target(name: "SFFlightModel", dependencies: ["SFMath", "SFAtmosphere"]),
        .target(name: "SFSystems", dependencies: ["SFMath"]),
        .target(name: "SFPerf"),
        .target(name: "SFNavData", dependencies: ["SFMath", "SFTerrainCore", "SFContent"], resources: [.copy("Resources")]),
        .target(name: "SFWeather", dependencies: ["SFMath", "SFAtmosphere", "SFContent"]),
        .target(name: "SFTerrainCore", dependencies: ["SFMath", "SFContent"], resources: [.copy("Resources")]),
        .target(name: "SFWorldGen", dependencies: ["SFMath", "SFTerrainCore"]),
        .target(name: "SFOriginalWorld", dependencies: ["SFMath"]),
        .target(name: "SFPreview", dependencies: ["SFMath", "SFTerrainCore", "SFWorldGen", "SFAtmosphere", "SFImagery"]),
        .target(name: "SFContent", dependencies: ["SFMath", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.define("SCENERY_BACKGROUND_ASSETS")]),
        .target(name: "SFInput", dependencies: ["SFMath"]),
        // Settings model: graphics, performance, audio, controls, gameplay, HUD, units, accessibility. Pure Swift.
        .target(name: "SFSettings"),
        .target(name: "SFImagery", dependencies: ["SFMath", "SFContent", "SFTerrainCore"]),
        .target(name: "SFInstruments", dependencies: ["SFMath", "SFAtmosphere", "SFFlightModel"]),
        .target(name: "SFQuickFlight", dependencies: ["SFMath", "SFAtmosphere", "SFWeather", "SFFlightModel", "SFInstruments", "SFInput", "SFWorldGen", "SFPreview", "SFImagery", "SFNavData", "SFTerrainCore", "SFContent"], resources: [.copy("Resources")]),
        .target(name: "SFCareer", dependencies: ["SFMath"]),
        // Multiplayer core: transport protocol, wire format, remote aircraft interpolation. Pure Swift.
        .target(name: "SFNetcode"),
        // First-flight lessons for new players. Pure Swift; the UI overlays the prompts and feeds the checks.
        .target(name: "SFTutorial"),
        // Missions, aircraft selection and military flight. Pure Swift on top of the flight model and Quick Flight worlds.
        .target(name: "SFGameplay", dependencies: ["SFMath", "SFAtmosphere", "SFFlightModel", "SFQuickFlight", "SFTraffic", "SFATC"]),
        .target(name: "SFGameplayUI", dependencies: ["SFGameplay"]),
        // Carrier operations: deck motion, catapult launch, arrested landing with LSO grading, qualification. Pure Swift.
        .target(name: "SFCarrier"),
        // AI traffic (point-mass arrivals and departures, wake shedding) and rule-based ATC on top of it.
        .target(name: "SFTraffic", dependencies: ["SFAtmosphere", "SFFlightModel"]),
        .target(name: "SFATC", dependencies: ["SFTraffic"]),
        // Photo mode, flight recording and replay. Pure Swift, no Apple frameworks, so it runs on Linux CI.
        .target(name: "SFReplay"),
        .target(name: "SFSim", dependencies: ["SFMath", "SFAtmosphere", "SFFlightModel", "SFSystems", "SFWeather", "SFInput"]),
        // Apple-only code inside #if canImport(...) so these compile empty on Linux
        .target(name: "SFRender", dependencies: ["SFPerf", "SFMath", "SFSim", "SFWeather", "SFTerrainCore", "SFWorldGen", "SFAtmosphere", "SFPreview", "SFQuickFlight"]),
        .target(name: "SFAudio", dependencies: ["SFSim", "SFMath", "SFFlightModel", "SFWeather"]),
        .target(name: "SFPlatform", dependencies: ["SFSim", "SFInput"]),
        .target(name: "SFUI", dependencies: ["SFSim", "SFRender", "SFWorldGen", "SFPerf", "SFAudio", "SFPlatform", "SFNavData", "SFContent", "SFInstruments", "SFInput", "SFSettings", "SFQuickFlight", "SFAtmosphere", "SFWeather", "SFImagery", "SFFlightModel", "SFGameplay", "SFGameplayUI", "SFCareer", "SFTraffic", "SFATC", "SFTutorial"]),
        .executableTarget(name: "SFPreviewCLI", dependencies: ["SFPreview", "SFInstruments", "SFAtmosphere", "SFQuickFlight", "SFImagery", "SFContent", "SFWorldGen", "SFTerrainCore", "SFMath"]),
        // Tests (Swift Testing)
        .testTarget(name: "SFCareerTests", dependencies: ["SFCareer", "SFMath"]),
        .testTarget(name: "SFNetcodeTests", dependencies: ["SFNetcode"]),
        .testTarget(name: "SFTutorialTests", dependencies: ["SFTutorial"]),
        .testTarget(name: "SFMathTests", dependencies: ["SFMath"]),
        .testTarget(name: "SFAtmosphereTests", dependencies: ["SFAtmosphere"]),
        .testTarget(name: "SFFlightModelTests", dependencies: ["SFFlightModel"]),
        .testTarget(name: "SFPerfTests", dependencies: ["SFPerf"]),
        .testTarget(name: "SFSimTests", dependencies: ["SFSim"]),
        .testTarget(name: "SFContentTests", dependencies: ["SFContent"]),
        .testTarget(name: "SFWorldGenTests", dependencies: ["SFWorldGen", "SFTerrainCore"]),
        .testTarget(name: "SFOriginalWorldTests", dependencies: ["SFOriginalWorld"]),
        .testTarget(name: "SFPreviewTests", dependencies: ["SFPreview", "SFImagery", "SFContent"]),
        .testTarget(name: "SFTerrainCoreTests", dependencies: ["SFTerrainCore", "SFContent"]),
        .testTarget(name: "SFWeatherTests", dependencies: ["SFWeather", "SFContent"]),
        .testTarget(name: "SFNavDataTests", dependencies: ["SFNavData", "SFContent"]),
        .testTarget(name: "SFInputTests", dependencies: ["SFInput"]),
        .testTarget(name: "SFSettingsTests", dependencies: ["SFSettings"]),
        .testTarget(name: "SFImageryTests", dependencies: ["SFImagery", "SFContent"]),
        .testTarget(name: "SFInstrumentsTests", dependencies: ["SFInstruments", "SFFlightModel", "SFAtmosphere", "SFPreview"]),
        .testTarget(name: "SFQuickFlightTests", dependencies: ["SFQuickFlight", "SFWeather", "SFAtmosphere", "SFFlightModel", "SFInput", "SFPreview", "SFImagery", "SFContent"]),
        .testTarget(name: "SFGameplayTests", dependencies: ["SFGameplay", "SFQuickFlight", "SFFlightModel", "SFAtmosphere", "SFMath"]),
        .testTarget(name: "SFCarrierTests", dependencies: ["SFCarrier"]),
        .testTarget(name: "SFAudioTests", dependencies: ["SFAudio", "SFFlightModel", "SFWeather"]),
        .testTarget(name: "SFTrafficTests", dependencies: ["SFTraffic", "SFFlightModel", "SFAtmosphere", "SFMath"]),
        .testTarget(name: "SFATCTests", dependencies: ["SFATC", "SFTraffic", "SFFlightModel"]),
        .testTarget(name: "SFReplayTests", dependencies: ["SFReplay"]),
        .testTarget(name: "SFRenderTests", dependencies: ["SFRender", "SFPreview", "SFAtmosphere", "SFQuickFlight", "SFImagery", "SFContent"]),
    ],
    swiftLanguageModes: [.v6]
)
