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

@Suite struct ImageryGradingTests {
    static func mosaic(size: Int, centre: SIMD2<Double> = .zero, half: Double, colour: (Int, Int) -> SIMD3<UInt8>) -> ImageryMosaic {
        var rgb = [UInt8](repeating: 0, count: size * size * 3)
        for j in 0..<size { for i in 0..<size { let c = colour(i, j); let o = 3 * (j * size + i); rgb[o] = c.x; rgb[o + 1] = c.y; rgb[o + 2] = c.z } }
        return ImageryMosaic(centre: centre, halfExtent: half, size: size, rgb: rgb, coverage: [UInt8](repeating: 255, count: size * size), zoom: 15)
    }

    @Test func matchBringsNearMeanAndContrastToFar() {
        // Far: greener, lower contrast. Near: same pattern but reddish and contrasty, 8× finer.
        let far = Self.mosaic(size: 64, half: 1_000) { i, j in
            let v = 100 + ((i / 4 + j / 4) % 2) * 20
            return SIMD3(UInt8(v - 20), UInt8(v + 10), UInt8(v - 40))
        }
        var near = Self.mosaic(size: 256, half: 500) { i, j in
            // Same 125 m checker as far, contrast doubled, red cast.
            let x = -500 + (Double(i) + 0.5) * 1000 / 256, y = 500 - (Double(j) + 0.5) * 1000 / 256
            let fi = Int((x + 1_000) / 2_000 * 64), fj = Int((1_000 - y) / 2_000 * 64)
            let v = 90 + ((fi / 4 + fj / 4) % 2) * 40
            return SIMD3(UInt8(v + 30), UInt8(v - 10), UInt8(v - 30))
        }
        let p = ImageryGrading.match(&near, to: far)
        #expect(p.allSatisfy { $0.gain > 0.4 && $0.gain < 0.6 || abs($0.gain - 0.6) < 1e-9 }, "contrast halved (gain clamped at 0.6): \(p)")
        var sum = SIMD3<Double>.zero
        for k in 0..<(256 * 256) { sum += SIMD3(Double(near.rgb[3 * k]), Double(near.rgb[3 * k + 1]), Double(near.rgb[3 * k + 2])) }
        let mean = sum / Double(256 * 256)
        #expect(abs(mean.x - 90) < 4 && abs(mean.y - 120) < 4 && abs(mean.z - 70) < 4, "near mean moved to far's: \(mean)")
    }

    @Test func dehazeRemovesAVeilAndKeepsOrder() {
        var m = Self.mosaic(size: 32, half: 100) { i, j in let v = UInt8(60 + (i + j) * 2); return SIMD3(v, v &+ 5, v &+ 10) }
        let before = m.rgb
        ImageryGrading.dehaze(&m)
        #expect(m.rgb.min()! < before.min()!, "veil removed: min \(m.rgb.min()!) < \(before.min()!)")
        for k in stride(from: 3, to: m.rgb.count, by: 3) where before[k] > before[k - 3] { #expect(m.rgb[k] >= m.rgb[k - 3]) }
    }
}
