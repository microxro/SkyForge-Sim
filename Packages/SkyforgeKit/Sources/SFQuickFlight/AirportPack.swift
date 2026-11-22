// SKYFORGE — Apache-2.0
// Offline airport surface polygons and lines for the showcase airports: a compact binary (`SFA1`) written by
// `tools/fetch_airport_surfaces.py` from OpenStreetMap data (as distributed in the Overture Maps base
// infrastructure theme; only records whose primary source is OpenStreetMap are kept).
// Data © OpenStreetMap contributors, ODbL 1.0 — show `OSMData.attribution` whenever it is drawn.
import Foundation
import SFImagery

/// Airport pavement and boundary geometry in region metres.
public struct AirportSurfaces: Sendable, Equatable {
    /// Surface classes in the order `fetch_airport_surfaces.py` writes them.
    public enum Surface: UInt8, Sendable { case boundary = 0, apron = 1, taxiway = 2, runway = 3 }

    public struct Feature: Sendable, Equatable {
        public var surface: Surface
        public var isLine: Bool
        /// Line width (m); 0 = the default for the surface (15 m taxiway, 30 m runway).
        public var widthMetres: Double
        public var points: [SIMD2<Double>]
        /// Natural or unpaved surface (grass, dirt, gravel): kept in the data but drawn as infield, not pavement.
        public var unpaved: Bool = false
    }

    public var features: [Feature]
    public var isEmpty: Bool { features.isEmpty }

    /// Value written to the r8 mask for pavement classes (see `AirportSurfaceShaders`).
    static func maskValue(_ s: Surface) -> UInt8 {
        switch s {
        case .boundary: return 26      // 0.10 infield
        case .apron: return 84         // 0.33
        case .taxiway: return 168      // 0.66
        case .runway: return 255       // 1.00
        }
    }
}

public enum AirportPack {
    public static let fileName = "airport.sfa"

    /// Smallest possible record in bytes (fixed fields plus a 2-point line), as BuildingPack.minRecordSize.
    static let minRecordSize = 18

    public enum ParseError: Error, Equatable { case badMagic, truncated }

    /// Features in metres around `origin`. Layout: "SFA1" | f64 lat0 | f64 lon0 | u32 count | records, record =
    /// u8 surface | u8 geometry (bit 0: 0 polygon, 1 line; bit 1: unpaved) | u16 width_dm | u16 n | i32 x_dm, i32 y_dm | (n−1) × (i16 dx, i16 dy).
    public static func parse(_ data: Data, origin: GeoOrigin) throws -> AirportSurfaces {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> AirportSurfaces in
            guard raw.count >= 24, raw[0] == 0x53, raw[1] == 0x46, raw[2] == 0x41, raw[3] == 0x31 else { throw ParseError.badMagic }
            var o = 4
            func read<T>(_: T.Type) throws -> T {
                let n = MemoryLayout<T>.size
                guard o + n <= raw.count else { throw ParseError.truncated }
                defer { o += n }
                return raw.loadUnaligned(fromByteOffset: o, as: T.self)
            }
            let lat0 = Double(bitPattern: UInt64(littleEndian: try read(UInt64.self)))
            let lon0 = Double(bitPattern: UInt64(littleEndian: try read(UInt64.self)))
            guard lat0.isFinite, lon0.isFinite, abs(lat0) <= 90, abs(lon0) <= 180 else { throw ParseError.truncated }
            let count = Int(UInt32(littleEndian: try read(UInt32.self)))
            // The pack's metres (equirectangular about lat0/lon0) → region metres, as RoadPack and BuildingPack.
            let mlat = 111_132.0, mlon = 111_320.0 * cos(lat0 * .pi / 180)
            func region(_ x: Double, _ y: Double) -> SIMD2<Double> {
                let p = origin.local(latitude: lat0 + y / mlat, longitude: lon0 + x / mlon)
                return SIMD2(p.east, p.north)
            }
            let p0 = region(0, 0), ex = (region(1_000, 0) - p0) / 1_000, ey = (region(0, 1_000) - p0) / 1_000
            var out: [AirportSurfaces.Feature] = []
            // Smallest record: 14-byte header plus a 2-point line (one 4-byte delta).
            guard count <= (raw.count - o) / minRecordSize else { throw ParseError.truncated }
            out.reserveCapacity(count)
            for _ in 0..<count {
                let sRaw = try read(UInt8.self), geom = try read(UInt8.self)
                let width = Double(UInt16(littleEndian: try read(UInt16.self))) * 0.1
                let n = Int(UInt16(littleEndian: try read(UInt16.self)))
                let x0 = Int32(littleEndian: try read(Int32.self)), y0 = Int32(littleEndian: try read(Int32.self))
                guard n >= 2, o + 4 * (n - 1) <= raw.count else { throw ParseError.truncated }
                var x = Double(x0), y = Double(y0)
                var pts: [SIMD2<Double>] = [p0 + ex * (x * 0.1) + ey * (y * 0.1)]
                for _ in 1..<n {
                    x += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self)))
                    y += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 2, as: Int16.self)))
                    o += 4
                    pts.append(p0 + ex * (x * 0.1) + ey * (y * 0.1))
                }
                guard let s = AirportSurfaces.Surface(rawValue: sRaw) else { continue }
                out.append(.init(surface: s, isLine: geom & 1 == 1, widthMetres: width, points: pts, unpaved: geom & 2 != 0))
            }
            return AirportSurfaces(features: out)
        }
    }
}

extension Showcase {
    /// The bundled airport surface geometry for a showcase airport (nil when its pack has none).
    public static func airportData(for ident: String) -> Data? {
        guard let dir = Bundle.module.url(forResource: ident, withExtension: nil, subdirectory: "Showcase") else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(AirportPack.fileName), options: .mappedIfSafe)
    }
}
