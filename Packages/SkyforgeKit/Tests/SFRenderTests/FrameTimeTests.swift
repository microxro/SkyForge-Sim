// SKYFORGE — Apache-2.0
#if canImport(Metal)
import Testing
import Foundation
import Metal
import simd
@testable import SFRender
import SFQuickFlight
import SFContent
import SFPreview

/// GPU frame time per device tier on the CI Metal device (C10). Times come from command-buffer GPU
/// timestamps over 30 frames after warm-up; the median is asserted against the tier budget and every
/// number is printed as `SKYFORGE_FRAMETIME` for VERIFICATION_LOG. The CI runner's GPU is a virtual
/// macOS GPU, not a phone or Mac: device frame times stay unverified until measured on hardware.
@Suite(.serialized) struct FrameTimeTests {
    struct Tier { let name: String; let width: Int; let height: Int; let sky: QuickFlightDetail; let real: RealWorldDetail
        let cloudSteps: Int; let budgetMs: Double }
    /// Budgets: 30 fps for low (33.3 ms), 60 fps for high (16.7 ms) at the tier's render size.
    static let tiers = [
        Tier(name: "low", width: 1_280, height: 720, sky: .phone, real: .phone, cloudSteps: 40, budgetMs: 33.3),
        Tier(name: "high", width: 1_920, height: 1_080, sky: .desktop, real: .desktop, cloudSteps: 80, budgetMs: 16.7),
    ]

    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }

    func report(_ scene: String, _ t: Tier, _ ms: [Double]) {
        let s = ms.sorted()
        print(String(format: "SKYFORGE_FRAMETIME scene=%@ tier=%@ %dx%d median=%.2fms p95=%.2fms min=%.2fms budget=%.1fms",
                     scene, t.name, t.width, t.height, Self.median(ms), s[Int(Double(s.count) * 0.95)], s[0], t.budgetMs))
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func skyWorldFrameTimeWithinTierBudget() throws {
        let world = QuickFlightWorld()
        for t in Self.tiers {
            let session = QuickFlightSession(world: world, start: .final)
            let cam = session.chaseCamera()
            let r = try WorldRenderer(lighting: .physicalPreset(.goldenHour, azimuthDegrees: 255, cameraHeightMetres: cam.position.z))
            try r.setEnvironment(world.buildEnvironment(detail: t.sky))
            try r.setAircraft(QuickFlightWorld.aircraftMesh())
            r.clouds = .fairWeather; r.cloudSteps = t.cloudSteps
            let c = session.bodyToENUColumns
            let ms = try r.benchmark(width: t.width, height: t.height, camera: WorldCamera(position: cam.position, target: cam.target), frames: 30,
                                     aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
            report("skyworld", t, ms)
            #expect(Self.median(ms) < t.budgetMs, "SkyWorld \(t.name): median \(Self.median(ms)) ms over \(t.budgetMs) ms")
        }
    }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func realWorldFrameTimeWithinTierBudget() async throws {
        let a = Showcase.defaultAirport
        for t in Self.tiers {
            let region = try await RealWorldRegion.load(airport: a.ident, detail: t.real, transport: Showcase.transport(for: a.ident, fallback: nil), cache: nil)
            let session = QuickFlightSession(world: region, start: .final)
            let cam = session.chaseCamera()
            let r = try WorldRenderer(lighting: .physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
            try r.setRealWorld(RealWorldRenderData(region: region))
            try r.setAircraft(QuickFlightWorld.aircraftMesh())
            r.clouds = .fairWeather(fieldElevation: Float(region.runwayElevation)); r.cloudSteps = t.cloudSteps
            let c = session.bodyToENUColumns
            let ms = try r.benchmark(width: t.width, height: t.height, camera: WorldCamera(position: cam.position, target: cam.target), frames: 30,
                                     aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
            report("real-\(a.ident)", t, ms)
            #expect(Self.median(ms) < t.budgetMs, "\(a.ident) \(t.name): median \(Self.median(ms)) ms over \(t.budgetMs) ms")
        }
    }
}
#endif
