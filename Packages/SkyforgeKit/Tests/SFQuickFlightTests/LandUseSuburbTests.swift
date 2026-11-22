// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

@Suite struct LandUsePackTests {
    /// One residential 100 m square (paved flag set), written the way `tools/fetch_landuse.py` writes it.
    static func pack() -> Data {
        var d = Data("SFL1".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(47.53.bitPattern.littleEndian); put((-122.30).bitPattern.littleEndian); put(UInt32(1).littleEndian)
        d.append(contentsOf: [1, 1]); put(UInt16(4).littleEndian)
        put(Int32(0).littleEndian); put(Int32(0).littleEndian)
        for (dx, dy) in [(1_000, 0), (0, 1_000), (-1_000, 0)] { put(Int16(dx).littleEndian); put(Int16(dy).littleEndian) }
        return d
    }

    @Test func parsesCategoryFlagsAndRing() throws {
        let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)
        let p = try LandUsePack.parse(Self.pack(), origin: origin)
        #expect(p.count == 1)
        #expect(p[0].category == .residential && p[0].paved)
        #expect(p[0].ring.count == 4)
        #expect(abs(OSMGeometry.signedArea(p[0].ring) - 10_000) < 100, "area \(OSMGeometry.signedArea(p[0].ring))")
    }

    @Test func filterAndCorruptData() throws {
        let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)
        #expect(try LandUsePack.parse(Self.pack(), origin: origin) { c, _ in c != .residential }.isEmpty)
        #expect(throws: LandUsePack.ParseError.badMagic) { try LandUsePack.parse(Data("nope".utf8) + Data(count: 40), origin: origin) }
        #expect(throws: LandUsePack.ParseError.truncated) { try LandUsePack.parse(Self.pack().prefix(30), origin: origin) }
    }
}

@Suite struct SuburbMaskTests {
    static func ring(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [SIMD2<Double>] {
        [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    }
    /// 128 m square at 2 m per pixel; an east–west street through y = 0, a residential block north of it.
    static func mask(extraLandUse: [LandUsePolygon] = [], highway: OSMHighway = .residential) -> [UInt8] {
        let road = OSMRoad(id: 1, points: [SIMD2(-64, 0), SIMD2(64, 0)], highway: highway, widthMetres: 7)
        let block = LandUsePolygon(category: .residential, ring: ring(-50, 10, 50, 50))
        return SuburbMask.build(size: 64, centre: .zero, halfExtent: 64, landUse: [block] + extraLandUse, roads: [road])
    }
    /// RGBA at row j, column i.
    static func px(_ m: [UInt8], _ i: Int, _ j: Int) -> [Int] { (0..<4).map { Int(m[(j * 64 + i) * 4 + $0]) } }

    @Test func encodesRoadFrameInsideResidentialBlocks() {
        let m = Self.mask()
        // Row 22 is y = 19 m, column 32 is x = 1 m: 19 m from the street, inside the block.
        let a = Self.px(m, 32, 22)
        #expect(a[0] == 255, "parcel weight \(a[0])")
        #expect(a[1] <= 1, "an east–west street has tangent angle 0 (got \(a[1]))")
        #expect(abs(a[2] - Int((19.0 / 60 * 255).rounded())) <= 2, "distance \(a[2])")
        #expect(a[3] == 14, "half width 3.5 m = 14 quarter-metres (got \(a[3]))")
        // South of the street, still within reach but outside the block: distance set, no parcel weight.
        let b = Self.px(m, 32, 47)
        #expect(b[0] == 0 && abs(b[2] - Int((31.0 / 60 * 255).rounded())) <= 2)
        // Beyond reach: no road, distance 255.
        let c = Self.px(m, 32, 63)
        #expect(c[0] == 0 && c[2] == 255 && c[3] == 0)
    }

    @Test func parksPunchOutAndMotorwaysDoNotFrontParcels() {
        let park = LandUsePolygon(category: .park, ring: Self.ring(-50, 10, 50, 30))
        let m = Self.mask(extraLandUse: [park])
        #expect(Self.px(m, 32, 22)[0] == 0, "y = 19 m is inside the park")
        #expect(Self.px(m, 32, 11)[0] == 255, "y = 41 m is still residential")   // 41 m is within 60 m reach
        let hw = Self.mask(highway: .motorway)
        #expect(Self.px(hw, 32, 22)[0] == 0 && Self.px(hw, 32, 22)[2] == 255)
    }
}
