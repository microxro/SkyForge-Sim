// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery
import SFContent
import SFTerrainCore

@Suite struct ShowcaseTests {
    @Test func everyShowcaseAirportShipsAnIntactPack() throws {
        for a in Showcase.airports {
            let pack = try #require(Showcase.pack(for: a.ident), "pack for \(a.ident)")
            #expect(pack.manifest.files.count > 50, "\(a.ident): \(pack.manifest.files.count) tiles")
            #expect(pack.manifest.attribution.contains { $0.contains("Terrarium") })
            #expect(pack.manifest.attribution.contains { $0.contains("Sentinel-2") || $0.contains("USGS") })
            // Every body matches its SHA-256 (TilePack.data verifies); a sample of each kind decodes.
            var decodedPNG = 0, decodedJPEG = 0
            for (urlString, _) in pack.manifest.files.sorted(by: { $0.key < $1.key }) {
                let url = try #require(URL(string: urlString))
                let body = try #require(try pack.data(for: url))
                if urlString.hasSuffix(".png") {
                    if decodedPNG < 2 { _ = try Terrarium.decode(png: [UInt8](body)); decodedPNG += 1 }
                } else if decodedJPEG < 3 { _ = try JPEGDecoder.decode([UInt8](body)); decodedJPEG += 1 }
            }
            #expect(decodedPNG == 2 && decodedJPEG == 3)
        }
    }

    /// The default start flies with no network at all: imagery and elevation come from the bundle.
    @Test func defaultShowcaseAirportLoadsOffline() async throws {
        let a = Showcase.defaultAirport
        let transport = Showcase.transport(for: a.ident, fallback: nil)
        // Same metres per pixel (so the same zoom levels) as the packed phone tier, over a smaller area.
        let p = RealWorldDetail.phone
        let d = RealWorldDetail(nearHalf: 600, nearStep: 40, midHalf: 2_000, midStep: 200, farHalf: 8_000, farStep: 1_000,
                                imageryNearSize: Int(Double(p.imageryNearSize) * 600 / p.nearHalf),
                                imageryFarSize: Int(Double(p.imageryFarSize) * 8_000 / p.farHalf), treeRadius: 300, maxTrees: 1_000,
                                imageryDetailHalf: 300, imageryDetailSize: p.imageryDetailSize / 2)
        let region = try await RealWorldRegion.load(airport: a.ident, detail: d, transport: transport, cache: nil)
        // The sharp layer around the start view (z18 USGS export tiles) is in the pack too, and streaming
        // it again around the same centre is served offline.
        let det = try #require(region.ground.detail)
        #expect(det.zoom == 18 && Double(det.coverage.filter { $0 > 0 }.count) / Double(det.coverage.count) > 0.99)
        let again = try #require(await region.streamDetail(around: det.centre, transport: transport, cache: nil))
        #expect(again.zoom == 18 && again.centre == det.centre)
        // Ahead of an aircraft flying east at 60 m/s: 75 % of the half extent ahead.
        let c = region.detailCentre(position: SIMD3(100, 200, 300), velocity: SIMD3(60, 0, 0))
        #expect(abs(c.x - (100 + 300 * 0.75)) < 1e-9 && abs(c.y - 200) < 1e-9)
        let nearM = region.ground.near, farM = try #require(region.ground.far)
        let near = nearM.coverage.filter { $0 > 0 }.count, far = farM.coverage.filter { $0 > 0 }.count
        #expect(Double(near) / Double(nearM.coverage.count) > 0.99)
        #expect(Double(far) / Double(farM.coverage.count) > 0.99)
        // Real relief from the packed Terrarium tiles, not the coarse baseline.
        #expect(abs(region.runwayElevation - 50) < 30, "KMRY field elevation \(region.runwayElevation) m")
        #expect(region.attribution.contains { $0.contains("USGS") })
        // The mid height mosaic (z12) comes from the pack too, and is what the terrain uses between the
        // near square and the far ring.
        let mid = try #require(region.midHeights, "z12 mid heights served offline")
        #expect(mid.metresPerSample < 5)
        let q = SIMD2(1_500.0, -1_200.0)                       // outside the 600 m near square, inside the mid one
        #expect(abs(region.outerHeight(q.x, q.y) - mid.height(q.x, q.y)) < 1e-9)
    }

    @Test func packTransportServesHitsAndRefusesMissesOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-pack-\(UUID().uuidString)")
        let u1 = URL(string: "https://example.invalid/a.png")!, u2 = URL(string: "https://example.invalid/b.png")!
        try TilePack.write(name: "t", responses: [u1: Data([1, 2, 3])], attribution: ["x"], to: dir)
        let t = TilePackTransport(packs: [try TilePack(root: dir)], fallback: nil)
        #expect(try await t.get(u1) == Data([1, 2, 3]))
        await #expect(throws: TransportError.offline) { _ = try await t.get(u2) }
        // A tampered body is detected.
        let hex = try TilePack(root: dir).manifest.files[u1.absoluteString]!
        try Data([9]).write(to: dir.appendingPathComponent(hex))
        await #expect(throws: TilePackError.self) { _ = try await t.get(u1) }
    }
}

/// Serves imagery only at zoom ≤ `maxZoom` (like a pack built for a lower tier, offline).
actor CoarseImageryTransport: HTTPTransport {
    let jpeg: Data, maxZoom: Int
    init(maxZoom: Int) throws {
        jpeg = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/imagery/usgs_15_13676_9038.jpg"))
        self.maxZoom = maxZoom
    }
    func get(_ url: URL) async throws -> Data {
        // USGS URLs end in /tile/z/y/x.
        let parts = url.path.split(separator: "/")
        guard url.host == "basemap.nationalmap.gov", parts.count >= 3, let z = Int(parts[parts.count - 3]), z <= maxZoom else { throw TransportError.offline }
        return jpeg
    }
}

@Suite struct ImageryFallbackTests {
    @Test func missingTilesFallBackToCoarserAncestors() async throws {
        let origin = GeoOrigin(latitude: 28.34, longitude: -80.68)
        let provider = USGSImageryProvider()
        let s = ImageryStreamer(provider: provider, transport: try CoarseImageryTransport(maxZoom: 14), cache: nil)
        // 1 m/px asks for z17; only z14 exists, three levels up.
        let m = await ImageryMosaic.build(origin: origin, centre: .zero, halfExtent: 300, size: 600, provider: provider, streamer: s)
        #expect(m.zoom >= 16)
        let cov = m.coverage.filter { $0 > 0 }.count
        #expect(cov == m.coverage.count, "covered \(cov)/\(m.coverage.count) from ancestors")
    }
}
