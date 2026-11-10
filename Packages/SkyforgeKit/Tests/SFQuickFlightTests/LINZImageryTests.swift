// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

@Suite struct LINZImageryTests {
    /// Queenstown from the bundled pack: the LINZ aerial survey replaces Sentinel-2 for the near and
    /// middle layers, and Lake Wakatipu's Frankton Arm is water in the near mask.
    @Test func queenstownUsesBundledAerialImagery() async throws {
        let ident = "NZQN"
        var d = RealWorldDetail(nearHalf: 1_200, nearStep: 40, midHalf: 3_000, midStep: 200, farHalf: 8_000, farStep: 1_000,
                                imageryNearSize: 1_024, imageryFarSize: 256, treeRadius: 300, maxTrees: 1_000,
                                imageryDetailHalf: 200, imageryDetailSize: 512)
        d.imageryMidSize = 512; d.imageryMidHalf = 3_000
        let region = try await RealWorldRegion.load(airport: ident, detail: d, transport: Showcase.transport(for: ident, fallback: nil), cache: nil)
        let linz = LINZAerialProvider()
        #expect(region.attribution.contains(linz.attribution))
        #expect(region.attribution.contains(LandCoverGrid.attribution))
        #expect(region.ground.near.zoom >= 16, "near layer zoom \(region.ground.near.zoom)")
        #expect(region.ground.near.coverage.allSatisfy { $0 > 0 }, "the pack's tiles cover the whole near layer")
        #expect(region.ground.detail != nil && region.detailProvider?.id == linz.id)
        #expect((region.midImagery?.zoom ?? 0) >= 14, "middle layer from the survey")
        // The lake south-west of the field: water by land cover, and so in the near mask.
        let cover = try #require(region.landCover)
        var lake: SIMD2<Double>?
        search: for y in stride(from: -1_100.0, through: 1_100, by: 100) { for x in stride(from: -1_100.0, through: 1_100, by: 100) {
            if cover.waterRange(x, y).min >= 1 { lake = SIMD2(x, y); break search }
        } }
        if let lake { #expect((region.ground.water(lake.x, lake.y) ?? 0) > 0.9) }
    }
}

@Suite struct RoadPackTests {
    /// Two roads: a residential street and a tunnel (dropped).
    static func sample() -> Data {
        var d = Data("SFR1".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(47.5.bitPattern.littleEndian); put((-122.3).bitPattern.littleEndian); put(UInt32(2).littleEndian)
        put(UInt8(6)); put(UInt8(0)); put(UInt16(3).littleEndian); put(Int32(1_000).littleEndian); put(Int32(2_000).littleEndian)
        put(Int16(500).littleEndian); put(Int16(0).littleEndian); put(Int16(0).littleEndian); put(Int16(-250).littleEndian)
        put(UInt8(0)); put(UInt8(4)); put(UInt16(2).littleEndian); put(Int32(0).littleEndian); put(Int32(0).littleEndian)
        put(Int16(100).littleEndian); put(Int16(100).littleEndian)
        return d
    }

    @Test func parsesPointsInMetresAndDropsTunnels() throws {
        let roads = try RoadPack.parse(Self.sample(), origin: GeoOrigin(latitude: 47.5, longitude: -122.3))
        #expect(roads.count == 1)
        let r = try #require(roads.first)
        #expect(r.highway == .residential && r.points.count == 3)
        #expect(abs(r.points[0].x - 100) < 0.5 && abs(r.points[0].y - 200) < 0.5)
        #expect(abs(r.points[1].x - 150) < 0.5 && abs(r.points[2].y - 175) < 0.5)
    }

    @Test func rejectsBadData() {
        #expect(throws: RoadPack.ParseError.badMagic) { try RoadPack.parse(Data("nope and more bytes here ....".utf8), origin: GeoOrigin(latitude: 0, longitude: 0)) }
        var cut = Self.sample(); cut.removeLast(6)
        #expect(throws: RoadPack.ParseError.truncated) { try RoadPack.parse(cut, origin: GeoOrigin(latitude: 47.5, longitude: -122.3)) }
    }

    @Test(arguments: ["KMRY", "KBFI", "KASE", "LSZS", "NZQN", "KCOI"])
    func showcasePacksCarryRoads(ident: String) throws {
        let d = try #require(Showcase.roadData(for: ident))
        let roads = try RoadPack.parse(d, origin: GeoOrigin(latitude: 0, longitude: 0)) { _, _ in true }
        #expect(roads.count > 1_000, "\(ident): \(roads.count) roads")
        #expect(roads.allSatisfy { $0.points.count >= 2 })
    }

    /// Roads with a centre line carry the across coordinate in the field channel; service roads carry none.
    @Test func roadMeshCarriesTheAcrossCoordinate() {
        let street = OSMRoad(id: 1, points: [SIMD2(0, 0), SIMD2(50, 0)], highway: .residential)
        let lane = OSMRoad(id: 2, points: [SIMD2(0, 30), SIMD2(50, 30)], highway: .service)
        let a = OSMMeshBuilder.roads([street]) { _, _ in 0 }, b = OSMMeshBuilder.roads([lane]) { _, _ in 0 }
        #expect(Set(a.vertexField) == [-1, 1])
        #expect(b.vertexField.allSatisfy { $0 == 0 })
    }
}
