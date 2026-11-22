// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

@Suite struct AirportPackTests {
    static let origin = GeoOrigin(latitude: 47.5, longitude: -122.3)

    /// A boundary square (±200 m), an apron square (20…60 m), and a runway line x = 0 from y = −150 to 150 m.
    static func sample() -> Data {
        var d = Data("SFA1".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        func record(_ surface: UInt8, line: Bool, width: UInt16, unpaved: Bool = false, _ pts: [(Int, Int)]) {   // decimetres
            put(surface); put(UInt8((line ? 1 : 0) | (unpaved ? 2 : 0))); put(width.littleEndian); put(UInt16(pts.count).littleEndian)
            put(Int32(pts[0].0).littleEndian); put(Int32(pts[0].1).littleEndian)
            for i in 1..<pts.count { put(Int16(pts[i].0 - pts[i - 1].0).littleEndian); put(Int16(pts[i].1 - pts[i - 1].1).littleEndian) }
        }
        put(47.5.bitPattern.littleEndian); put((-122.3).bitPattern.littleEndian); put(UInt32(3).littleEndian)
        record(0, line: false, width: 0, [(-2000, -2000), (2000, -2000), (2000, 2000), (-2000, 2000)])
        record(1, line: false, width: 0, [(200, 200), (600, 200), (600, 600), (200, 600)])
        record(3, line: true, width: 0, [(0, -1500), (0, 1500)])
        return d
    }

    @Test func unpavedRunwayIsInfieldNotPavement() throws {
        var d = Data("SFA1".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(47.5.bitPattern.littleEndian); put((-122.3).bitPattern.littleEndian); put(UInt32(2).littleEndian)
        // Boundary square ±200 m, then an unpaved (flag bit 1) runway line along x = 0.
        for (surface, geom, pts) in [(UInt8(0), UInt8(0), [(-2000, -2000), (2000, -2000), (2000, 2000), (-2000, 2000)]),
                                     (UInt8(3), UInt8(1 | 2), [(0, -1500), (0, 1500)])] {
            put(surface); put(geom); put(UInt16(0).littleEndian); put(UInt16(pts.count).littleEndian)
            put(Int32(pts[0].0).littleEndian); put(Int32(pts[0].1).littleEndian)
            for i in 1..<pts.count { put(Int16(pts[i].0 - pts[i - 1].0).littleEndian); put(Int16(pts[i].1 - pts[i - 1].1).littleEndian) }
        }
        let a = try AirportPack.parse(d, origin: Self.origin)
        #expect(a.features[1].unpaved && a.features[1].isLine)
        let r = try #require(a.rasterise())
        #expect(Self.texel(r, 0, 0) == (0, 26), "grass runway: infield class, no pavement coverage")
    }

    /// (coverage, class) bytes at a region point.
    static func texel(_ r: AirportMaskRaster, _ x: Double, _ y: Double) -> (UInt8, UInt8) {
        let px = 2 * r.halfExtent / Double(r.size)
        let i = Int((x - (r.centre.x - r.halfExtent)) / px), j = Int(((r.centre.y + r.halfExtent) - y) / px)
        let n = (j * r.size + i) * 2
        return (r.texels[n], r.texels[n + 1])
    }

    @Test func parsesFeaturesInMetres() throws {
        let a = try AirportPack.parse(Self.sample(), origin: Self.origin)
        #expect(a.features.count == 3)
        #expect(a.features[2].surface == .runway && a.features[2].isLine)
        #expect(abs(a.features[1].points[2].x - 60) < 0.5 && abs(a.features[1].points[2].y - 60) < 0.5)
    }

    @Test func rejectsBadData() {
        #expect(throws: AirportPack.ParseError.badMagic) { try AirportPack.parse(Data("nope and more bytes here ....".utf8), origin: Self.origin) }
        var cut = Self.sample(); cut.removeLast(5)
        #expect(throws: AirportPack.ParseError.truncated) { try AirportPack.parse(cut, origin: Self.origin) }
    }

    @Test func rasterisesClassesAndRunwayWidth() throws {
        let a = try AirportPack.parse(Self.sample(), origin: Self.origin)
        let r = try #require(a.rasterise())
        #expect(r.texels.count == 2 * r.size * r.size)
        #expect(Self.texel(r, 0, 0) == (255, 255), "runway centre: full coverage, class 1.0")
        #expect(Self.texel(r, 40, 40) == (255, 84), "apron")
        #expect(Self.texel(r, 120, -120) == (0, 26), "infield inside the boundary")
        #expect(Self.texel(r, 12, 0).0 == 255, "default 30 m runway covers x = 12")
        // Outside the boundary, beyond the margin: nothing.
        #expect(Self.texel(r, 250, 250).1 == 0)
        // The primary runway's own 20 m width replaces the default.
        let p = AirportSurfaces.PrimaryRunway(threshold: SIMD2(0, -150), direction: SIMD2(0, 1), width: 20)
        let r2 = try #require(a.rasterise(primary: p))
        #expect(Self.texel(r2, 12, 0).0 == 0 && Self.texel(r2, 8, 0).0 == 255)
    }

    @Test(arguments: ["KMRY", "KBFI", "KASE", "LSZS", "NZQN", "KCOI"])
    func showcasePacksCarryAirportSurfaces(ident: String) throws {
        let d = try #require(Showcase.airportData(for: ident))
        let a = try AirportPack.parse(d, origin: GeoOrigin(latitude: 0, longitude: 0))
        #expect(a.features.contains { $0.surface == .runway } && a.features.contains { $0.surface == .taxiway })
    }
}
