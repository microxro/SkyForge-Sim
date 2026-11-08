// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender
import SFQuickFlight
import SFImagery
import SFContent
import SFPreview
#if canImport(simd)
import simd
#endif

/// Serves the USGS fixture JPEG for imagery hosts; elevation is offline (bundled global DEM). No network.
actor FixtureImageryTransport: HTTPTransport {
    let jpeg: Data
    init() throws {
        jpeg = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/imagery/usgs_15_13676_9038.jpg"))
    }
    func get(_ url: URL) async throws -> Data {
        if url.host == "basemap.nationalmap.gov" || url.host == "tiles.maps.eox.at" { return jpeg }
        throw TransportError.offline
    }
}

@Suite struct RealWorldRenderTests {
    static let detail = RealWorldDetail(nearHalf: 1_500, nearStep: 30, midHalf: 5_000, midStep: 150, farHalf: 12_000, farStep: 800,
                                        imageryNearSize: 512, imageryFarSize: 256, treeRadius: 700, maxTrees: 4_000)

    static func region() async throws -> RealWorldRegion {
        try await RealWorldRegion.load(airport: "KCOI", detail: detail, transport: try FixtureImageryTransport(), cache: nil)
    }

    @Test func regionConvertsToRenderData() async throws {
        let r = try await Self.region()
        let d = RealWorldRenderData(region: r, chunkQuads: 16)
        #expect(d.chunks.count == r.terrainChunks(quads: 16).count)
        #expect(d.trees.count == r.trees().count && !d.trees.isEmpty)
        let near = try #require(d.near)
        #expect(near.rgb.count == near.size * near.size * 3)
        let mask = try #require(d.waterMask)
        #expect(mask.values.count == mask.size * mask.size)
        #expect(d.far != nil)
    }

    #if canImport(Metal)
    @Test(.enabled(if: SkyRegressionTests.hasDevice, "no Metal device on this host"))
    func realWorldFrameRenders() async throws {
        let region = try await Self.region()
        let data = RealWorldRenderData(region: region, chunkQuads: 32)
        let session = QuickFlightSession(world: region, start: .final)
        let cam = session.chaseCamera()
        let lighting = LightingSetup.physicalPreset(.midday, azimuthDegrees: 200, cameraHeightMetres: cam.position.z)
        let r = try WorldRenderer(lighting: lighting)
        try r.setRealWorld(data)
        try r.setAircraft(QuickFlightWorld.aircraftMesh())
        let c = session.bodyToENUColumns
        let w = 320, h = 180
        let img = try r.render(width: w, height: h, camera: WorldCamera(position: cam.position, target: cam.target),
                               aircraftPosition: session.positionENU, aircraftBodyToENU: simd_double3x3(columns: (c.0, c.1, c.2)))
        _ = VisualRegression.check(name: "metal_realworld_320x180", rgb: img, width: w, height: h, goldenDir: goldenDir)
        func px(_ x: Int, _ y: Int) -> SIMD3<Int> { let i = 3 * (y * w + x); return SIMD3(Int(img[i]), Int(img[i + 1]), Int(img[i + 2])) }
        let top = px(w / 4, 3), bottom = px(w / 4, h - 3)
        #expect(top.z > top.x, "sky at top is blue: \(top)")
        #expect(bottom.z < bottom.x || bottom.z < bottom.y, "imagery ground at bottom: \(bottom)")
        #expect(r.lastDrawnChunks > 0 && r.lastDrawnChunks < data.chunks.count,
                "frustum culling drew \(r.lastDrawnChunks) of \(data.chunks.count) chunks")
        // The lower half is textured photo ground, not a flat fill.
        var lo = Int.max, hi = 0
        for y in (h / 2)..<h { for x in 0..<(w / 3) { let s = px(x, y).x + px(x, y).y + px(x, y).z; lo = min(lo, s); hi = max(hi, s) } }
        #expect(hi - lo > 40, "ground contrast \(hi - lo)")
    }
    #endif
}
