// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFPreview
import SFImagery
import SFContent

actor TileFixtureTransport: HTTPTransport {
    let data: Data
    init(_ d: Data) { data = d }
    func get(_ url: URL) async throws -> Data { data }
}

@Suite struct RealWorldTests {
    static let tile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/imagery/usgs_15_13676_9038.jpg")

    func mosaic() async throws -> ImageryMosaic {
        let s = ImageryStreamer(provider: USGSImageryProvider(maxZoom: 15), transport: TileFixtureTransport(try Data(contentsOf: Self.tile)), cache: nil)
        return await ImageryMosaic.build(origin: GeoOrigin(latitude: 28.34, longitude: -80.68), centre: .zero, halfExtent: 400, size: 256,
                                         provider: USGSImageryProvider(maxZoom: 15), streamer: s)
    }

    @Test func imageryBecomesPlausibleAlbedo() async throws {
        let g = ImageryGround(near: try await mosaic(), far: nil)
        var maxA: Float = 0, n = 0
        for x in stride(from: -350.0, to: 350, by: 25) {
            for y in stride(from: -350.0, to: 350, by: 25) {
                guard let s = g.ground(x, y) else { continue }
                maxA = max(maxA, s.albedo.max()); n += 1
                #expect(s.water >= 0 && s.water <= 1)
            }
        }
        #expect(n > 700)
        #expect(maxA < 0.8)          // photo exposure removed: no surface brighter than fresh snow-ish
        #expect(g.ground(5_000, 0) == nil)
    }

    @Test func waterMaskIsSmooth() async throws {
        let g = ImageryGround(near: try await mosaic(), far: nil)
        // Neighbouring samples 1 m apart never jump by more than the 16 m mask allows.
        var worst: Float = 0
        for x in stride(from: -300.0, to: 300, by: 7) {
            let a = g.water(x, 10) ?? 0, b = g.water(x + 1, 10) ?? 0
            worst = max(worst, abs(a - b))
        }
        #expect(worst < 0.25)
    }
}
