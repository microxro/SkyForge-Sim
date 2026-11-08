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

/// Metal frames of the bundled showcase airports, loaded fully offline from their tile packs
/// (art-director review frames; logged as SKYFORGE_PNG in CI).
@Suite struct ShowcaseRenderTests {
    /// The packed phone tier (what a phone flies).
    static var detail: RealWorldDetail { .phone }

    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"),
          arguments: ["KMRY", "KASE", "KBFI", "LSZS", "NZQN"])
    func showcaseFrame(ident: String) async throws {
        let region = try await RealWorldRegion.load(airport: ident, detail: Self.detail,
                                                    transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z)
        let r = try WorldRenderer(lighting: lighting)
        try r.setRealWorld(data)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .fairWeather(fieldElevation: Float(region.runwayElevation))
        let c = session.bodyToENUColumns
        let w = 1280, h = 720
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        _ = VisualRegression.check(name: "metal_real_\(ident)_1280x720", rgb: img, width: w, height: h, goldenDir: goldenDir)
        // Textured photo ground in the lower half (not a flat fill or the missing-imagery colour).
        var lo = Int.max, hi = 0
        for y in (h * 2 / 3)..<h { for x in stride(from: 0, to: w, by: 4) {
            let i = 3 * (y * w + x); let s = Int(img[i]) + Int(img[i + 1]) + Int(img[i + 2]); lo = min(lo, s); hi = max(hi, s)
        } }
        #expect(hi - lo > 60, "\(ident) ground contrast \(hi - lo)")
    }

    /// SkyWorld (the offline fallback) at the same size and phone detail, for the same review.
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func skyWorldFrame() throws {
        let world = QuickFlightWorld()
        let session = QuickFlightSession(world: world, start: .final)
        let cam = session.chaseCamera()
        let r = try WorldRenderer(lighting: LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z))
        try r.setEnvironment(world.buildEnvironment(detail: .phone))
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        r.clouds = .fairWeather
        let c = session.bodyToENUColumns
        let w = 1280, h = 720
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        _ = VisualRegression.check(name: "metal_skyworld_1280x720", rgb: img, width: w, height: h, goldenDir: goldenDir)
        #expect(r.lastDrawnEnvironmentCells > 0)
    }
}
#endif
