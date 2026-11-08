// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFImagery

@Suite struct JPEGDecoderTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/imagery")

    func check(_ name: String) throws {
        let jpg = try [UInt8](Data(contentsOf: Self.dir.appendingPathComponent(name)))
        let ref = try [UInt8](Data(contentsOf: Self.dir.appendingPathComponent(name + ".pillow.rgb")))
        let img = try JPEGDecoder.decode(jpg)
        #expect(img.width == 256 && img.height == 256)
        #expect(img.rgb.count == ref.count)
        var sum = 0, mx = 0
        for (a, b) in zip(img.rgb, ref) { let d = abs(Int(a) - Int(b)); sum += d; mx = max(mx, d) }
        let mean = Double(sum) / Double(ref.count)
        // Pillow (libjpeg) uses fancy chroma upsampling and integer IDCT; we use nearest + float.
        #expect(mean < 3.0, "\(name): mean abs diff \(mean)")
        #expect(mx < 80, "\(name): max diff \(mx)")
    }

    @Test func decodesUSGSOrthoimageryTile() throws { try check("usgs_15_13676_9038.jpg") }
    @Test func decodesSentinel2CloudlessTile() throws { try check("s2c2016_10_284_435.jpg") }

    @Test func rejectsNonJPEGAndTruncatedData() throws {
        #expect(throws: JPEGError.notJPEG) { try JPEGDecoder.decode([0x89, 0x50, 0x4E, 0x47, 0, 0]) }
        let jpg = try [UInt8](Data(contentsOf: Self.dir.appendingPathComponent("usgs_15_13676_9038.jpg")))
        #expect(throws: (any Error).self) { try JPEGDecoder.decode(Array(jpg.prefix(300))) }
    }
}

import SFContent
import SFTerrainCore

actor FixtureTransport: HTTPTransport {
    let data: Data
    private(set) var requests: [URL] = []
    init(_ d: Data) { data = d }
    func get(_ url: URL) async throws -> Data { requests.append(url); return data }
}

@Suite struct ImageryPipelineTests {
    @Test func providerURLsAndCoverage() {
        let t = TileCoord(z: 15, x: 9038, y: 13676)
        #expect(USGSImageryProvider().url(t).absoluteString.hasSuffix("/tile/15/13676/9038"))
        #expect(Sentinel2CloudlessProvider().url(t).absoluteString.contains("s2cloudless_3857/default/g/15/13676/9038.jpg"))
        #expect(USGSImageryProvider().covers(latitude: 28.34, longitude: -80.68))
        #expect(!USGSImageryProvider().covers(latitude: 48.85, longitude: 2.35))     // Paris → Sentinel-2
        #expect(Sentinel2CloudlessProvider().attribution.contains("CC BY 4.0"))
    }

    @Test func geoOriginRoundTripsAndScales() {
        let o = GeoOrigin(latitude: 28.34, longitude: -80.68)
        for (x, y) in [(0.0, 0.0), (10_000.0, -7_500.0), (-30_000.0, 25_000.0)] {
            let ll = o.coordinate(east: x, north: y)
            let back = o.local(latitude: ll.latitude, longitude: ll.longitude)
            #expect(abs(back.east - x) < 0.5 && abs(back.north - y) < 0.5)
        }
        let oneKmNorth = o.coordinate(east: 0, north: 1_000)
        #expect(abs((oneKmNorth.latitude - 28.34) * 110_800 - 1_000) < 10)   // ≈ 110.8 km per degree at 28°
    }

    @Test func zoomSelectionMatchesGroundResolution() {
        #expect(ImageryMosaic.zoom(for: 2.5, latitude: 28.3, maxZoom: 16) == 16)
        #expect(ImageryMosaic.zoom(for: 30, latitude: 28.3, maxZoom: 16) == 13)
        #expect(ImageryMosaic.tileResolution(zoom: 16, latitude: 0) < 2.4)
    }

    @Test func mosaicSamplesTilesAndCachesOnDisk() async throws {
        let jpg = try Data(contentsOf: JPEGDecoderTests.dir.appendingPathComponent("usgs_15_13676_9038.jpg"))
        let transport = FixtureTransport(jpg)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let streamer = ImageryStreamer(provider: USGSImageryProvider(maxZoom: 15), transport: transport, cache: try KeyedCache(root: dir))
        let o = GeoOrigin(latitude: 28.34, longitude: -80.68)
        let m = await ImageryMosaic.build(origin: o, centre: .zero, halfExtent: 600, size: 512,   // 2.3 m/px → z15 (capped)
                                          provider: USGSImageryProvider(maxZoom: 15), streamer: streamer)
        #expect(m.zoom == 15)
        #expect(m.coverage.allSatisfy { $0 == 255 })
        #expect(m.sample(0, 0) != nil && m.sample(5_000, 0) == nil)
        let firstRun = await transport.requests.count
        #expect(firstRun >= 1 && firstRun <= 9)
        // A second streamer over the same disk cache needs no network.
        let s2 = ImageryStreamer(provider: USGSImageryProvider(maxZoom: 15), transport: transport, cache: try KeyedCache(root: dir))
        _ = await ImageryMosaic.build(origin: o, centre: .zero, halfExtent: 600, size: 512, provider: USGSImageryProvider(maxZoom: 15), streamer: s2)
        #expect(await transport.requests.count == firstRun)
    }

    @Test func landCoverSeparatesWaterForestAndConcrete() {
        let water = LandCover.classify(SIMD3(0.10, 0.18, 0.24))
        let forest = LandCover.classify(SIMD3(0.12, 0.20, 0.10))
        let road = LandCover.classify(SIMD3(0.62, 0.62, 0.60))
        #expect(water.water > 0.6 && water.forest < 0.2)
        #expect(forest.forest > 0.6 && forest.water < 0.2)
        #expect(road.urban > 0.6 && road.water < 0.1)
    }
}
