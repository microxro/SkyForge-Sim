// SKYFORGE — Apache-2.0
// Offline land-use polygons for the showcase airports: a compact binary (`SFL1`) written by
// `tools/fetch_landuse.py` from the Overture Maps base theme (records whose primary source is OpenStreetMap only).
// Data © OpenStreetMap contributors, ODbL 1.0 — show `LandUsePack.attribution` whenever it is drawn.
import Foundation
import SFImagery

/// Land-use category in the order `fetch_landuse.py` writes them (`CATEGORIES`).
public enum LandUseCategory: UInt8, Sendable, CaseIterable {
    case other, residential, commercial, industrial, park, agricultural, airport, institutional, cemetery, golf, natural, transport
}

public struct LandUsePolygon: Sendable, Equatable {
    public var category: LandUseCategory
    /// Surface tag said paved (parking, aprons).
    public var paved: Bool
    /// Region metres (x east, y north), outer ring only, no repeated last point.
    public var ring: [SIMD2<Double>]
    public init(category: LandUseCategory, paved: Bool = false, ring: [SIMD2<Double>]) {
        self.category = category; self.paved = paved; self.ring = ring
    }
}

public enum LandUsePack {
    public static let attribution = "Land use: © OpenStreetMap contributors, ODbL 1.0 (via Overture Maps Foundation)"
    public static let fileName = "landuse.sfl"

    public enum ParseError: Error, Equatable { case badMagic, truncated }

    /// Polygons in metres around `origin`; `keep(category, centre)` filters before the ring is converted.
    public static func parse(_ data: Data, origin: GeoOrigin,
                             keep: (LandUseCategory, SIMD2<Double>) -> Bool = { _, _ in true }) throws -> [LandUsePolygon] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [LandUsePolygon] in
            guard raw.count >= 24, raw[0] == 0x53, raw[1] == 0x46, raw[2] == 0x4C, raw[3] == 0x31 else { throw ParseError.badMagic }
            var o = 4
            func read<T>(_: T.Type) throws -> T {
                let n = MemoryLayout<T>.size
                guard o + n <= raw.count else { throw ParseError.truncated }
                defer { o += n }
                return raw.loadUnaligned(fromByteOffset: o, as: T.self)
            }
            let lat0 = Double(bitPattern: UInt64(littleEndian: try read(UInt64.self)))
            let lon0 = Double(bitPattern: UInt64(littleEndian: try read(UInt64.self)))
            let count = Int(UInt32(littleEndian: try read(UInt32.self)))
            // Same affine pack-metres → region-metres map as BuildingPack / RoadPack.
            let mlat = 111_132.0, mlon = 111_320.0 * cos(lat0 * .pi / 180)
            func region(_ x: Double, _ y: Double) -> SIMD2<Double> {
                let p = origin.local(latitude: lat0 + y / mlat, longitude: lon0 + x / mlon)
                return SIMD2(p.east, p.north)
            }
            let p0 = region(0, 0), ex = (region(1_000, 0) - p0) / 1_000, ey = (region(0, 1_000) - p0) / 1_000
            var out: [LandUsePolygon] = []
            out.reserveCapacity(min(count, raw.count / 12))
            for _ in 0..<count {
                let cat = try read(UInt8.self), flags = try read(UInt8.self)
                let n = Int(UInt16(littleEndian: try read(UInt16.self)))
                let x0 = Int32(littleEndian: try read(Int32.self)), y0 = Int32(littleEndian: try read(Int32.self))
                guard n >= 3, o + 4 * (n - 1) <= raw.count else { throw ParseError.truncated }
                var x = Double(x0), y = Double(y0)
                var pts: [SIMD2<Double>] = [SIMD2(x, y)]
                pts.reserveCapacity(n)
                for _ in 1..<n {
                    x += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self)))
                    y += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 2, as: Int16.self)))
                    o += 4
                    pts.append(SIMD2(x, y))
                }
                let category = LandUseCategory(rawValue: cat) ?? .other
                let c = pts.reduce(.zero, +) / Double(n) * 0.1
                guard keep(category, p0 + ex * c.x + ey * c.y) else { continue }
                var ring = pts.map { p0 + ex * ($0.x * 0.1) + ey * ($0.y * 0.1) }
                if OSMGeometry.signedArea(ring) < 0 { ring.reverse() }
                out.append(LandUsePolygon(category: category, paved: flags & 1 != 0, ring: ring))
            }
            return out
        }
    }
}

extension Showcase {
    /// The bundled land-use polygons for a showcase airport (nil until its pack carries `landuse.sfl`).
    public static func landUseData(for ident: String) -> Data? {
        guard let dir = Bundle.module.url(forResource: ident, withExtension: nil, subdirectory: "Showcase") else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(LandUsePack.fileName), options: .mappedIfSafe)
    }
}
