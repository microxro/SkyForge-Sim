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
