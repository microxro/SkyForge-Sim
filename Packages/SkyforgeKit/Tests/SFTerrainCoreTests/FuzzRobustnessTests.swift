// SKYFORGE — Apache-2.0
// Seeded-mutation robustness for PNGDecoder, Inflate (zlib) and GlobalDEM: every input must throw or
// return, never trap.
import Testing
import Foundation
@testable import SFTerrainCore

// Deterministic mutation helpers (fixed seeds, no Foundation randomness).
struct FuzzRNG_TC {
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

enum FuzzMutate_TC {
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
    static func mutated(_ original: [UInt8], _ rng: inout FuzzRNG_TC) -> [UInt8] {
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
    // MARK: Fixtures

    static var terrariumPNG: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/terrarium/rainier_10_165_360.png")
    }

    static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for v in d { a = (a + UInt32(v)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }

    /// zlib stream made of stored blocks.
    static func zlibStored(_ payload: [UInt8]) -> [UInt8] {
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65_535, payload.count - i)
            let final: UInt8 = i + n >= payload.count ? 1 : 0
            z.append(final)
            z.append(UInt8(n & 0xFF)); z.append(UInt8(n >> 8))
            z.append(UInt8(~n & 0xFF)); z.append(UInt8((~n >> 8) & 0xFF))
            z.append(contentsOf: payload[i..<(i + n)])
            i += n
        } while i < payload.count
        let ad = adler32(payload)
        z.append(contentsOf: [UInt8(ad >> 24), UInt8((ad >> 16) & 0xFF), UInt8((ad >> 8) & 0xFF), UInt8(ad & 0xFF)])
        return z
    }

    static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Small 8-bit RGB PNG (CRCs are zero: the decoder does not verify them). Rows use filters 0...4.
    static func smallPNG(width: Int = 8, height: Int = 6) -> [UInt8] {
        var raw: [UInt8] = []
        for y in 0..<height {
            raw.append(UInt8(y % 5))
            for x in 0..<(width * 3) { raw.append(UInt8(truncatingIfNeeded: x * 7 + y * 13)) }
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(body.count) + Array(type.utf8) + body + [0, 0, 0, 0] }
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", be32(width) + be32(height) + [8, 2, 0, 0, 0])
        png += chunk("IDAT", zlibStored(raw))
        png += chunk("IEND", [])
        return png
    }

    /// Concatenated IDAT payload of a PNG (the zlib stream, dynamic Huffman for real files).
    static func idat(of png: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 8
        while i + 8 <= png.count {
            let len = Int(png[i]) << 24 | Int(png[i + 1]) << 16 | Int(png[i + 2]) << 8 | Int(png[i + 3])
            let type = String(decoding: png[(i + 4)..<(i + 8)], as: UTF8.self)
            guard len >= 0, i + 12 + len <= png.count else { break }
            if type == "IDAT" { out.append(contentsOf: png[(i + 8)..<(i + 8 + len)]) }
            i += 12 + len
        }
        return out
    }

    @discardableResult
    static func runPNG(_ b: [UInt8]) -> Bool { do { _ = try PNGDecoder.decode(b); return true } catch { return false } }

    @discardableResult
    static func runInflate(_ b: [UInt8], expected: Int = 0, maxOutput: Int = 1 << 22) -> Bool {
        do { _ = try Inflate.zlib(b, expectedSize: expected, maxOutput: maxOutput); return true } catch { return false }
    }

    // MARK: PNGDecoder

    @Test func pngFixtureDecodes() {
        #expect(Self.runPNG(Self.smallPNG()))
    }

    @Test func pngTruncationAtEveryOffset() {
        let png = Self.smallPNG()
        for c in 0..<png.count { Self.runPNG(Array(png.prefix(c))) }
        #expect(!Self.runPNG(Array(png.prefix(png.count - 20))))
    }

    @Test func pngSeededByteMutations() {
        let png = Self.smallPNG()
        var rng = FuzzRNG_TC(seed: 0x504E_4700_0001)
        for _ in 0..<1500 { Self.runPNG(FuzzMutate_TC.mutated(png, &rng)) }
    }

    @Test func pngBoundaryHeaderFields() {
        let png = Self.smallPNG()
        // Layout: signature(8) length(4) "IHDR"(4) width(4)@16 height(4)@20 depth@24 colour@25 compression@26 filter@27 interlace@28.
        // Also the IHDR length field @8 and the IDAT length field @33+13... (found by scanning below).
        var fields: [(Int, Int)] = [(8, 4), (16, 4), (20, 4), (24, 1), (25, 1), (26, 1), (27, 1), (28, 1)]
        // First IDAT chunk length sits right after the IHDR chunk: 8 + 12 + 13 = 33.
        fields.append((33, 4))
        var n = 0
        for f in fields {
            for v in FuzzMutate_TC.boundaries {
                var b = png
                FuzzMutate_TC.put(&b, at: f.0, width: f.1, value: v, bigEndian: true)
                Self.runPNG(b)
                n += 1
            }
        }
        #expect(n == fields.count * FuzzMutate_TC.boundaries.count)
    }

    @Test func pngRealFixtureMutations() throws {
        let png = try [UInt8](Data(contentsOf: Self.terrariumPNG))
        var rng = FuzzRNG_TC(seed: 0x504E_4700_0002)
        // Only the first 64 bytes (signature, IHDR, start of IDAT) are mutated; the deflate body is covered by the Inflate tests.
        let head = Array(png.prefix(64))
        let rest = Array(png.dropFirst(64))
        for _ in 0..<40 { Self.runPNG(FuzzMutate_TC.mutated(head, &rng) + rest) }
    }

    // MARK: Inflate

    @Test func inflateStoredTruncationAtEveryOffset() {
        let z = Self.zlibStored((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        #expect(Self.runInflate(z))
        for c in 0..<z.count { Self.runInflate(Array(z.prefix(c))) }
    }

    @Test func inflateStoredSeededMutations() {
        let z = Self.zlibStored((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var rng = FuzzRNG_TC(seed: 0x5A4C_4942_0001)
        for _ in 0..<1500 { Self.runInflate(FuzzMutate_TC.mutated(z, &rng)) }
    }

    @Test func inflateDynamicHuffmanTruncationAndMutations() throws {
        let png = try [UInt8](Data(contentsOf: Self.terrariumPNG))
        let z = Self.idat(of: png)
        #expect(z.count > 100)
        // Cap output so mutated streams that expand a lot stay cheap.
        for c in FuzzMutate_TC.cutLengths(count: z.count, dense: 256, maxCuts: 200) {
            Self.runInflate(Array(z.prefix(c)), maxOutput: 1 << 20)
        }
        var rng = FuzzRNG_TC(seed: 0x5A4C_4942_0002)
        for _ in 0..<300 { Self.runInflate(FuzzMutate_TC.mutated(z, &rng), maxOutput: 1 << 20) }
        // Header-heavy mutations (the first bytes hold the block type and Huffman table sizes).
        let head = Array(z.prefix(48))
        for _ in 0..<600 {
            let m = FuzzMutate_TC.mutated(head, &rng)
            Self.runInflate(m + z.dropFirst(48), maxOutput: 1 << 20)
        }
    }

    @Test func inflateBoundaryParameters() {
        let z = Self.zlibStored([1, 2, 3, 4, 5])
        for e in [0, 1, 5, 1 << 31, Int(UInt32.max), Int.max, Int.min, -1] {
            for m in [0, 1, 5, 1 << 31, Int.max] { Self.runInflate(z, expected: e, maxOutput: m) }
        }
    }

    @Test func inflateBoundaryStoredLengthFields() {
        let z = Self.zlibStored((0..<64).map { UInt8($0) })
        // Stored header: 78 01 | BFINAL/BTYPE @2 | LEN @3 | NLEN @5.
        for (off, w) in [(2, 1), (3, 2), (5, 2), (3, 4)] {
            for v in FuzzMutate_TC.boundaries {
                for big in [false, true] {
                    var b = z
                    FuzzMutate_TC.put(&b, at: off, width: w, value: v, bigEndian: big)
                    Self.runInflate(b)
                }
            }
        }
    }

    // MARK: GlobalDEM

    /// 2x1 tiles of 4x4 Int16 samples (8x4 grid).
    static func demBytes(tilesX: Int = 2, tilesY: Int = 1, tileSize: Int = 4) -> [UInt8] {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        func le64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        var bodies: [[UInt8]] = []
        for t in 0..<(tilesX * tilesY) {
            var raw: [UInt8] = []
            for i in 0..<(tileSize * tileSize) {
                let v = Int16(truncatingIfNeeded: t * 100 + i * 3 - 20)
                raw.append(UInt8(truncatingIfNeeded: v)); raw.append(UInt8(truncatingIfNeeded: v >> 8))
            }
            bodies.append(zlibStored(raw))
        }
        var out: [UInt8] = Array("SFDEM1".utf8) + [0, 0]
        out += le32(tilesX * tileSize) + le32(tilesY * tileSize) + le32(tileSize) + le32(tilesX) + le32(tilesY)
        var offset = 28 + bodies.count * 12
        for b in bodies { out += le64(offset) + le32(b.count); offset += b.count }
        for b in bodies { out += b }
        return out
    }

    /// Builds a GlobalDEM and, on success, samples it everywhere including out-of-range pixels.
    @discardableResult
    static func runDEM(_ b: [UInt8]) -> Bool {
        guard let dem = try? GlobalDEM(data: Data(b)) else { return false }
        for (c, r) in [(0, 0), (1, 1), (-1, -1), (dem.width, dem.height), (dem.width - 1, dem.height - 1), (Int(Int32.max), -5)] {
            _ = dem.sample(column: c, row: r)
        }
        for (la, lo) in [(0.0, 0.0), (90.0, 180.0), (-90.0, -180.0), (47.5, -122.3), (89.999, 179.999)] {
            _ = dem.elevation(latitude: la, longitude: lo)
        }
        return true
    }

    @Test func demValidInputLoads() {
        #expect(Self.runDEM(Self.demBytes()))
    }

    @Test func demTruncationAtEveryOffset() {
        let d = Self.demBytes()
        for c in 0..<d.count { Self.runDEM(Array(d.prefix(c))) }
    }

    @Test func demSeededByteMutations() {
        let d = Self.demBytes()
        var rng = FuzzRNG_TC(seed: 0x4445_4D00_0001)
        for _ in 0..<1500 { Self.runDEM(FuzzMutate_TC.mutated(d, &rng)) }
    }

    @Test func demBoundaryHeaderAndTableFields() {
        let d = Self.demBytes()
        // width@8 height@12 tileSize@16 tilesX@20 tilesY@24 (u32 LE); table: offset u64 @28, length u32 @36 (+12 per tile).
        let fields: [(Int, Int)] = [(8, 4), (12, 4), (16, 4), (20, 4), (24, 4), (28, 8), (36, 4), (40, 8), (48, 4), (28, 4), (32, 4)]
        var n = 0
        for f in fields {
            for v in FuzzMutate_TC.boundaries {
                var b = d
                FuzzMutate_TC.put(&b, at: f.0, width: f.1, value: v, bigEndian: false)
                Self.runDEM(b)
                n += 1
            }
        }
        #expect(n == fields.count * FuzzMutate_TC.boundaries.count)
    }
}
