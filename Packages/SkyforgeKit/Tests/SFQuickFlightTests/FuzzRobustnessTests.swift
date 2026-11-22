// SKYFORGE — Apache-2.0
// Seeded-mutation robustness for BuildingPack (SFB1) and RoadPack (SFR1): every input must throw or
// return, never trap.
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

// Deterministic mutation helpers (fixed seeds, no Foundation randomness).
struct FuzzRNG_QF {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
}

enum FuzzMutate_QF {
    /// 0, 1, 2^31-1, 2^31, 2^32-1, 2^63.
    static let boundaries: [UInt64] = [0, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, UInt64(1) << 63]

    /// Overwrites `width` bytes at `offset` with the low bytes of `value` (no-op when out of range).
    static func put(_ b: inout [UInt8], at offset: Int, width: Int, value: UInt64, bigEndian: Bool) {
        guard offset >= 0, width > 0, width <= 8, offset + width <= b.count else { return }
        for i in 0..<width {
            let shift = UInt64(bigEndian ? (width - 1 - i) * 8 : i * 8)
            b[offset + i] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    /// 1...4 random edits (bit flip, random byte, 0x00, 0xFF); half of them land in the first 64 bytes.
    static func mutated(_ original: [UInt8], _ rng: inout FuzzRNG_QF) -> [UInt8] {
        var b = original
        guard !b.isEmpty else { return b }
        let edits = 1 + rng.below(4)
        for _ in 0..<edits {
            let head = min(64, b.count)
            let i = rng.below(2) == 0 ? rng.below(head) : rng.below(b.count)
            switch rng.below(4) {
            case 0: b[i] ^= UInt8(1) << UInt8(rng.below(8))
            case 1: b[i] = UInt8(truncatingIfNeeded: rng.next())
            case 2: b[i] = 0x00
            default: b[i] = 0xFF
            }
        }
        return b
    }

    /// Every cut length in `0..<dense`, then an even stride so that at most about `maxCuts` cuts are made.
    static func cutLengths(count: Int, dense: Int, maxCuts: Int) -> [Int] {
        var out: [Int] = []
        let d = min(dense, count)
        if d > 0 { out.append(contentsOf: 0..<d) }
        if count > d {
            let step = max(1, (count - d) / max(1, maxCuts))
            var c = d
            while c < count { out.append(c); c += step }
        }
        return out
    }
}

@Suite struct FuzzRobustnessTests {
    static let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)

    static func le(_ v: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: v >> UInt64($0 * 8)) } }

    static func header(_ magic: String, count: Int) -> [UInt8] {
        Array(magic.utf8) + le(47.53.bitPattern, 8) + le((-122.30).bitPattern, 8) + le(UInt64(count), 4)
    }

    /// Three buildings (3-, 4- and 5-point rings, 10 m squares in decimetres). Record = 24 fixed bytes + 4 per extra point.
    static func buildingPack() -> [UInt8] {
        var d = header("SFB1", count: 3)
        for (k, n) in [3, 4, 5].enumerated() {
            d += le(UInt64(bitPattern: Int64(100 * k)), 4) + le(UInt64(bitPattern: Int64(-50 * k)), 4)   // x0, y0
            d += le(65, 2) + le(0, 2)                                                                  // height dm, min height dm
            d += [UInt8(1 + k), UInt8(k), UInt8(2), 1]                                                  // kind, roof, floors, flags
            d += [200, 40, 30, 220, 220, 210]                                                           // roof / wall RGB
            d += le(UInt64(n), 2)
            let deltas: [(Int, Int)] = [(100, 0), (0, 100), (-100, 0), (0, -100)]
            for j in 0..<(n - 1) {
                let dx = j < 4 ? deltas[j].0 : 0, dy = j < 4 ? deltas[j].1 : 0
                d += le(UInt64(bitPattern: Int64(dx)), 2) + le(UInt64(bitPattern: Int64(dy)), 2)
            }
        }
        return d
    }

    /// Three roads (class, flags, point count u16, x0 i32, y0 i32, then 4 bytes per extra point).
    static func roadPack() -> [UInt8] {
        var d = header("SFR1", count: 3)
        for (k, n) in [2, 3, 4].enumerated() {
            d += [UInt8(k), UInt8(k)] + le(UInt64(n), 2)
            d += le(UInt64(bitPattern: Int64(200 * k)), 4) + le(UInt64(bitPattern: Int64(-100 * k)), 4)
            for j in 1..<n { d += le(UInt64(bitPattern: Int64(300 + j)), 2) + le(UInt64(bitPattern: Int64(-40 * j)), 2) }
        }
        return d
    }

    @discardableResult
    static func runBuildings(_ b: [UInt8]) -> Bool {
        do { _ = try BuildingPack.parse(Data(b), origin: origin); return true } catch { return false }
    }

    @discardableResult
    static func runRoads(_ b: [UInt8]) -> Bool {
        do { _ = try RoadPack.parse(Data(b), origin: origin); return true } catch { return false }
    }

    @Test func validPacksParse() throws {
        #expect(try BuildingPack.parse(Data(Self.buildingPack()), origin: Self.origin).count == 3)
        #expect(try RoadPack.parse(Data(Self.roadPack()), origin: Self.origin).count >= 1)
    }

    @Test func truncationAtEveryOffset() {
        let b = Self.buildingPack(), r = Self.roadPack()
        for c in 0..<b.count { Self.runBuildings(Array(b.prefix(c))) }
        for c in 0..<r.count { Self.runRoads(Array(r.prefix(c))) }
    }

    @Test func seededByteMutations() {
        let b = Self.buildingPack(), r = Self.roadPack()
        var rng = FuzzRNG_QF(seed: 0x5346_4231_0001)
        for _ in 0..<1000 { Self.runBuildings(FuzzMutate_QF.mutated(b, &rng)) }
        for _ in 0..<1000 { Self.runRoads(FuzzMutate_QF.mutated(r, &rng)) }
    }

    @Test func boundaryHeaderFieldsBuildings() {
        let b = Self.buildingPack()
        // lat0@4 lon0@12 (f64 bit patterns), count@20, then first record: x0@24 y0@28 hd@32 mh@34 ... n@46.
        let fields: [(Int, Int)] = [(4, 8), (12, 8), (20, 4), (24, 4), (28, 4), (32, 2), (34, 2), (38, 1), (46, 2),
                                    (4, 4), (12, 4), (20, 8), (46, 1)]
        var n = 0
        for f in fields {
            for v in FuzzMutate_QF.boundaries {
                var m = b
                FuzzMutate_QF.put(&m, at: f.0, width: f.1, value: v, bigEndian: false)
                Self.runBuildings(m)
                n += 1
            }
        }
        #expect(n == fields.count * FuzzMutate_QF.boundaries.count)
    }

    @Test func boundaryHeaderFieldsRoads() {
        let r = Self.roadPack()
        // lat0@4 lon0@12, count@20, first record: class@24 flags@25 n@26 x0@28 y0@32.
        let fields: [(Int, Int)] = [(4, 8), (12, 8), (20, 4), (24, 1), (25, 1), (26, 2), (28, 4), (32, 4),
                                    (4, 4), (12, 4), (20, 8), (26, 1)]
        var n = 0
        for f in fields {
            for v in FuzzMutate_QF.boundaries {
                var m = r
                FuzzMutate_QF.put(&m, at: f.0, width: f.1, value: v, bigEndian: false)
                Self.runRoads(m)
                n += 1
            }
        }
        #expect(n == fields.count * FuzzMutate_QF.boundaries.count)
    }

    @Test func extremeOriginsDoNotTrap() {
        let b = Self.buildingPack(), r = Self.roadPack()
        for o in [GeoOrigin(latitude: 90, longitude: 180), GeoOrigin(latitude: -90, longitude: -180),
                  GeoOrigin(latitude: 0, longitude: 0), GeoOrigin(latitude: 89.9999, longitude: 0)] {
            _ = try? BuildingPack.parse(Data(b), origin: o)
            _ = try? RoadPack.parse(Data(r), origin: o)
        }
    }
}
