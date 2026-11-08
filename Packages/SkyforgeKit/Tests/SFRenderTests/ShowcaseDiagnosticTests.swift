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

/// Isolation frames for the showcase ground (which layer is missing or wrong on the GPU): full, no trees,
/// near ring only, no near imagery. Logged as SKYFORGE_PNG `diag_<IDENT>_<variant>`.
@Suite struct ShowcaseDiagnosticTests {
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"), arguments: ["LSZS", "KMRY"])
    func isolate(ident: String) async throws {
        let region = try await RealWorldRegion.load(airport: ident, detail: .phone,
                                                    transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let full = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let nc = region.nearHeights.centre, nh = Float(region.detail.nearHalf)
        func nearOnly(_ c: RealWorldRenderData.Chunk) -> Bool {
            c.boundsMin.x >= Float(nc.x) - nh - 1 && c.boundsMin.y >= Float(nc.y) - nh - 1
                && c.boundsMax.x <= Float(nc.x) + nh + 600 && c.boundsMax.y <= Float(nc.y) + nh + 600
        }
        var noTrees = full; noTrees.trees = []
        var nearRing = full; nearRing.chunks = full.chunks.filter(nearOnly); nearRing.trees = []
        var noNearImg = full; noNearImg.near = nil
        print("SKYFORGE_DIAG \(ident) chunks \(full.chunks.count) near \(nearRing.chunks.count) cam \(cam.position) nc \(nc)")
        for (name, data) in [("full", full), ("notrees", noTrees), ("nearring", nearRing), ("nonearimg", noNearImg)] {
            let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z)
            let r = try WorldRenderer(lighting: lighting)
            try r.setRealWorld(data)
            try r.setAircraft(QuickFlightWorld.aircraftMesh())
            let c = session.bodyToENUColumns
            let w = 320, h = 180
            let img = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                                   aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
            print("SKYFORGE_DIAG \(ident) \(name) drewChunks \(r.lastDrawnChunks)/\(data.chunks.count)")
            _ = VisualRegression.check(name: "diag_\(ident)_\(name)", rgb: img, width: w, height: h, goldenDir: goldenDir)
        }
    }
}
#endif
