// SKYFORGE — Apache-2.0
// Offline road centrelines for the showcase airports: a compact binary (`SFR1`) written by
// `tools/fetch_roads.py` from OpenStreetMap data (as distributed in the Overture Maps transportation
// theme; only records whose primary source is OpenStreetMap are kept).
// Data © OpenStreetMap contributors, ODbL 1.0 — show `OSMData.attribution` whenever it is drawn.
import Foundation
import SFImagery

public enum RoadPack {
    public static let fileName = "roads.sfr"

    public enum ParseError: Error, Equatable { case badMagic, truncated }

    /// Road classes in the order `fetch_roads.py` writes them.
    static let classes: [OSMHighway] = [.motorway, .trunk, .primary, .secondary, .tertiary, .unclassified, .residential,
                                        .livingStreet, .service, .track]
    static let links: [OSMHighway: OSMHighway] = [.motorway: .motorwayLink, .trunk: .trunkLink, .primary: .primaryLink,
                                                  .secondary: .secondaryLink, .tertiary: .tertiaryLink]

    /// Roads in metres around `origin`. `keep(class, midpoint)` filters before the points are converted
    /// (distance rings, minor roads far out). Tunnels are dropped.
    public static func parse(_ data: Data, origin: GeoOrigin,
                             keep: (OSMHighway, SIMD2<Double>) -> Bool = { _, _ in true }) throws -> [OSMRoad] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [OSMRoad] in
            guard raw.count >= 24, raw[0] == 0x53, raw[1] == 0x46, raw[2] == 0x52, raw[3] == 0x31 else { throw ParseError.badMagic }
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
            // The pack's metres (equirectangular about lat0/lon0) → region metres, as BuildingPack.
            let mlat = 111_132.0, mlon = 111_320.0 * cos(lat0 * .pi / 180)
            func region(_ x: Double, _ y: Double) -> SIMD2<Double> {
                let p = origin.local(latitude: lat0 + y / mlat, longitude: lon0 + x / mlon)
                return SIMD2(p.east, p.north)
            }
            let p0 = region(0, 0), ex = (region(1_000, 0) - p0) / 1_000, ey = (region(0, 1_000) - p0) / 1_000
            var out: [OSMRoad] = []
            out.reserveCapacity(count)
            var line: [SIMD2<Double>] = []
            for i in 0..<count {
                let cls = Int(try read(UInt8.self)), flags = try read(UInt8.self)
                let n = Int(UInt16(littleEndian: try read(UInt16.self)))
                let x0 = Int32(littleEndian: try read(Int32.self)), y0 = Int32(littleEndian: try read(Int32.self))
                guard n >= 2, o + 4 * (n - 1) <= raw.count else { throw ParseError.truncated }
                var x = Double(x0), y = Double(y0)
                line.removeAll(keepingCapacity: true)
                line.append(SIMD2(x, y))
                for _ in 1..<n {
                    x += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self)))
                    y += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 2, as: Int16.self)))
                    o += 4
                    line.append(SIMD2(x, y))
                }
                guard cls < classes.count, flags & 4 == 0 else { continue }
                var highway = classes[cls]
                if flags & 1 != 0, let l = links[highway] { highway = l }
                let mid = line[n / 2] * 0.1
                guard keep(highway, p0 + ex * mid.x + ey * mid.y) else { continue }
                var tags: [String: String] = [:]
                if flags & 2 != 0 { tags["bridge"] = "yes" }
                out.append(OSMRoad(id: Int64(i + 1), points: line.map { p0 + ex * ($0.x * 0.1) + ey * ($0.y * 0.1) }, highway: highway,
                                   surface: flags & 8 != 0 ? "unpaved" : nil, tags: tags))
            }
            return out
        }
    }
}

extension Showcase {
    /// The bundled road centrelines for a showcase airport (nil when its pack has none).
    public static func roadData(for ident: String) -> Data? {
        guard let dir = Bundle.module.url(forResource: ident, withExtension: nil, subdirectory: "Showcase") else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(RoadPack.fileName), options: .mappedIfSafe)
    }
}
