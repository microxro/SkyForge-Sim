// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery
import SFContent
import SFInput

/// Serves the USGS fixture JPEG for imagery URLs; everything else (elevation) is offline,
/// so heights come from the bundled global DEM. Never touches the network.
actor OfflineImageryTransport: HTTPTransport {
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

@Suite struct RealWorldRegionTests {
    static let detail = RealWorldDetail(nearHalf: 1_200, nearStep: 40, midHalf: 4_000, midStep: 200, farHalf: 10_000, farStep: 1_000,
                                        imageryNearSize: 256, imageryFarSize: 128, treeRadius: 600, maxTrees: 3_000)

    static func load() async throws -> RealWorldRegion {
        try await RealWorldRegion.load(airport: "KCOI", detail: detail, transport: try OfflineImageryTransport(), cache: nil)
    }

    @Test func kcoiRunwayComesFromOurAirports() async throws {
        let r = try await Self.load()
        let hdg = r.runwayHeading * 180 / .pi
        #expect(abs(hdg - 109) < 2, "runway 11 true heading \(hdg)")
        #expect(abs(r.runwayLengthMetres - 1_097) < 40, "threshold separation \(r.runwayLengthMetres)")
        #expect(abs(r.runwayWidthMetres - 22.9) < 0.5)
        // The origin is the runway midpoint, so the thresholds sit ≈ ±550 m from it.
        #expect(abs((r.runwayThreshold * r.runwayThreshold).sum().squareRoot() - r.runwayLengthMetres / 2) < 5)
        #expect(r.attribution.contains { $0.contains("public domain") })
    }

    @Test func runwayIsFlatAndTerrainIsFinite() async throws {
        let r = try await Self.load()
        let mid = r.runwayThreshold + r.runwayDirection * (r.runwayLengthMetres / 2)
        #expect(abs(r.height(mid.x, mid.y) - r.runwayElevation) < 1e-9)
        for x in stride(from: -9_000.0, through: 9_000, by: 1_500) { #expect(r.height(x, 1_000).isFinite) }
    }

    @Test func chunksCoverRingsWithSharedVertices() async throws {
        let r = try await Self.load()
        let chunks = r.terrainChunks(quads: 16)
        #expect(chunks.count > 10)
        for c in chunks {
            #expect(c.positions.count == 17 * 17 && c.indices.count == 16 * 16 * 6)
            #expect(c.indices.allSatisfy { Int($0) < c.positions.count })
            #expect(c.boundsMin.x <= c.boundsMax.x && c.boundsMin.z <= c.boundsMax.z)
        }
    }

    @Test func treesAvoidRunwayAndWater() async throws {
        let r = try await Self.load()
        let trees = r.trees()
        #expect(trees.count <= Self.detail.maxTrees)
        for t in trees.prefix(500) {
            #expect(!r.nearRunway(Double(t.position.x), Double(t.position.y)))
            #expect(t.height >= 9 && t.height <= 19)
        }
    }

    @Test func sessionRestsOnTheRealRunway() async throws {
        let r = try await Self.load()
        var s = QuickFlightSession(world: r, start: .runway)
        for _ in 0..<(5 * 60) { s.update(realDt: 1.0 / 60, device: .init()) }
        #expect(!s.crashed)
        #expect(s.heightAboveGround > 1.0 && s.heightAboveGround < 1.4)
        #expect(abs(s.data.headingDeg - r.runwayHeading * 180 / .pi) < 2)
    }
}

@Suite struct TreeThinningTests {
    /// A dense 2 km forest capped at 5,000 trees keeps every tree near the centre and still reaches the edge.
    @Test func thinningKeepsNearDenseAndReachesFar() {
        var trees: [TreeInstance] = []
        var y = -1_000.0
        while y < 1_000 { var x = -1_000.0; while x < 1_000 {
            if x * x + y * y < 1_000 * 1_000 { trees.append(TreeInstance(position: SIMD3(Float(x), Float(y), 0), height: 10, conifer: true, colour: .one)) }
            x += 7 }; y += 7 }
        func d2(_ t: TreeInstance) -> Float { (SIMD2(t.position.x, t.position.y) * SIMD2(t.position.x, t.position.y)).sum() }
        trees.sort { d2($0) < d2($1) }
        let kept = RealWorldRegion.thin(trees, max: 5_000, d2: d2)
        #expect(kept.count <= 5_000 && kept.count > 4_800, "\(kept.count)")
        let far = kept.filter { d2($0) > 900 * 900 }.count, farAll = trees.filter { d2($0) > 900 * 900 }.count
        #expect(far > 0 && far < farAll / 2, "far ring thinned, not empty: \(far) of \(farAll)")
        let nearKept = kept.filter { d2($0) < 100 * 100 }.count, nearAll = trees.filter { d2($0) < 100 * 100 }.count
        #expect(nearKept == nearAll, "near trees all kept")
        #expect(RealWorldRegion.thin(trees, max: 5_000, d2: d2).count == kept.count, "deterministic")
    }
}
