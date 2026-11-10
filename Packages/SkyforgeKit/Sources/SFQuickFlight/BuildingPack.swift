// SKYFORGE — Apache-2.0
// Offline building footprints for the showcase airports: a compact binary (`SFB1`) written by
// `tools/fetch_buildings.py` from OpenStreetMap data (as distributed in the Overture Maps buildings
// theme; only records whose primary source is OpenStreetMap are kept).
// Data © OpenStreetMap contributors, ODbL 1.0 — show `BuildingPack.attribution` whenever it is drawn.
import Foundation
import SFImagery

public enum BuildingPack {
    public static let attribution = "Buildings: © OpenStreetMap contributors, ODbL 1.0 (via Overture Maps Foundation)"
    public static let fileName = "buildings.sfb"

    public enum ParseError: Error, Equatable { case badMagic, truncated }

    /// `class`/`subtype` values in the order `fetch_buildings.py` writes them.
    static let kinds = ["yes", "house", "residential", "apartments", "commercial", "industrial", "retail", "office", "warehouse",
                        "hangar", "garage", "shed", "church", "school", "hospital", "hotel", "civic", "transportation", "roof",
                        "agricultural", "service", "religious", "education", "medical", "entertainment", "military", "outbuilding"]
    static let roofs = ["", "flat", "gabled", "hipped", "pyramidal", "skillion", "gambrel", "mansard", "dome", "round", "onion", "saltbox",
                        "half_hipped", "sawtooth", "cone", "spherical"]

    /// Buildings in metres around `origin`. `keep(centre, area, height)` filters before the footprint is
    /// built (distance rings, small far buildings); buildings without a surveyed height get an estimate
    /// from their storeys, type and footprint.
    public static func parse(_ data: Data, origin: GeoOrigin,
                             keep: (SIMD2<Double>, Double, Double) -> Bool = { _, _, _ in true }) throws -> [OSMBuilding] {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [OSMBuilding] in
            guard raw.count >= 24, raw[0] == 0x53, raw[1] == 0x46, raw[2] == 0x42, raw[3] == 0x31 else { throw ParseError.badMagic }
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
            // The pack's metres (equirectangular about lat0/lon0) → region metres: an affine map through
            // three reference points (second-order terms are centimetres over a 20 km pack).
            let mlat = 111_132.0, mlon = 111_320.0 * cos(lat0 * .pi / 180)
            func region(_ x: Double, _ y: Double) -> SIMD2<Double> {
                let p = origin.local(latitude: lat0 + y / mlat, longitude: lon0 + x / mlon)
                return SIMD2(p.east, p.north)
            }
            let p0 = region(0, 0), ex = (region(1_000, 0) - p0) / 1_000, ey = (region(0, 1_000) - p0) / 1_000
            var out: [OSMBuilding] = []
            out.reserveCapacity(count)
            var ring: [SIMD2<Double>] = []
            for i in 0..<count {
                let x0 = Int32(littleEndian: try read(Int32.self)), y0 = Int32(littleEndian: try read(Int32.self))
                let hd = UInt16(littleEndian: try read(UInt16.self)), mh = UInt16(littleEndian: try read(UInt16.self))
                let kind = Int(try read(UInt8.self)), roof = Int(try read(UInt8.self))
                let floors = Int(try read(UInt8.self)), flags = try read(UInt8.self)
                let rr = try read(UInt8.self), rg = try read(UInt8.self), rb = try read(UInt8.self)
                let wr = try read(UInt8.self), wg = try read(UInt8.self), wb = try read(UInt8.self)
                let n = Int(UInt16(littleEndian: try read(UInt16.self)))
                guard o + 4 * (n - 1) <= raw.count, n >= 3 else { throw ParseError.truncated }
                var x = Double(x0), y = Double(y0)
                ring.removeAll(keepingCapacity: true)
                ring.append(SIMD2(x, y))
                for _ in 1..<n {
                    x += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self)))
                    y += Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 2, as: Int16.self)))
                    o += 4
                    ring.append(SIMD2(x, y))
                }
                // Decimetres → metres; signed area and centroid in pack metres decide the filter.
                var area2 = 0.0, c = SIMD2<Double>.zero
                for k in 0..<n { let a = ring[k], b = ring[(k + 1) % n]; area2 += a.x * b.y - a.y * b.x; c += a }
                let area = abs(area2) * 0.5 * 0.01
                c = c / Double(n) * 0.1
                let centre = p0 + ex * c.x + ey * c.y
                let kindName = kind < kinds.count ? kinds[kind] : "yes"
                var height = Double(hd) / 10
                if flags & 1 == 0 || height < 2 {
                    height = floors > 0 ? Double(floors) * 3.2 + 1 : estimatedHeight(kind: kindName, area: area, seed: UInt64(truncatingIfNeeded: i))
                }
                guard area >= 12, keep(centre, area, height) else { continue }
                var fp = ring.map { p0 + ex * ($0.x * 0.1) + ey * ($0.y * 0.1) }
                if area2 < 0 { fp.reverse() }
                func colour(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD3<Float>? {
                    guard r != 0 || g != 0 || b != 0 else { return nil }
                    func lin(_ v: UInt8) -> Float { let s = Float(v) / 255; return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4) }
                    return SIMD3(lin(r), lin(g), lin(b))
                }
                var tags: [String: String] = [:]
                if roof > 0 && roof < roofs.count { tags["roof:shape"] = roofs[roof] }
                out.append(OSMBuilding(id: Int64(i + 1), footprint: fp, heightMetres: height, minHeightMetres: Double(mh) / 10,
                                       levels: floors > 0 ? floors : nil, kind: kindName, isPart: false,
                                       roofColour: colour(rr, rg, rb), wallColour: colour(wr, wg, wb), tags: tags))
            }
            return out
        }
    }

    /// Height for a footprint with no surveyed height: by type, with large footprints read as low sheds
    /// and a little deterministic variation so a street is not one flat roof line.
    static func estimatedHeight(kind: String, area: Double, seed: UInt64) -> Double {
        let u = Double((seed &* 0x9E37_79B9_7F4A_7C15) >> 40) / Double(1 << 24)
        switch kind {
        case "house", "garage", "shed", "outbuilding": return kind == "house" ? 5.5 + 2.5 * u : 3.2
        case "apartments", "hotel": return 11 + 6 * u
        case "commercial", "office", "retail": return area > 3_000 ? 8 + 3 * u : 7 + 6 * u
        case "industrial", "warehouse", "hangar": return 8 + 4 * u
        case "church", "religious": return 11 + 4 * u
        case "school", "hospital", "education", "medical", "civic": return 8 + 5 * u
        default:
            if area < 60 { return 3.2 }
            if area < 320 { return 5.5 + 2.5 * u }
            return area > 2_500 ? 8 + 3 * u : 7 + 4 * u
        }
    }
}

extension Showcase {
    /// The bundled building footprints for a showcase airport (nil when its pack has none).
    public static func buildingData(for ident: String) -> Data? {
        guard let dir = Bundle.module.url(forResource: ident, withExtension: nil, subdirectory: "Showcase") else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(BuildingPack.fileName), options: .mappedIfSafe)
    }
}
