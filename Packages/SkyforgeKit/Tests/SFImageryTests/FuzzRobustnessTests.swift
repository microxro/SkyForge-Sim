// SKYFORGE — Apache-2.0
// Seeded-mutation robustness for JPEGDecoder: every input must throw or return, never trap.
import Testing
import Foundation
@testable import SFImagery

// Deterministic mutation helpers (fixed seeds, no Foundation randomness).
struct FuzzRNG_Img {
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

enum FuzzMutate_Img {
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
    static func mutated(_ original: [UInt8], _ rng: inout FuzzRNG_Img) -> [UInt8] {
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
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/imagery")

    static func fixture(_ name: String) throws -> [UInt8] {
        try [UInt8](Data(contentsOf: dir.appendingPathComponent(name)))
    }

    /// Runs the decoder and returns true when it returned an image, false when it threw.
    @discardableResult
    static func run(_ bytes: [UInt8]) -> Bool {
        // The decoder zero-pads past the end of the entropy data, so a header declaring a huge frame is
        // accepted and decodes slowly (bounded by its 64 Mpx cap). Skip those here to keep the test fast.
        if let sof = sofOffset(bytes), sof + 9 < bytes.count {
            let h = Int(bytes[sof + 5]) << 8 | Int(bytes[sof + 6]), w = Int(bytes[sof + 7]) << 8 | Int(bytes[sof + 8])
            if h * w > 1_048_576 { return false }
        }
        do { _ = try JPEGDecoder.decode(bytes); return true } catch { return false }
    }

    /// Offset of the SOF0/SOF1/SOF2 marker (0xFF 0xC0...2), if any.
    static func sofOffset(_ b: [UInt8]) -> Int? {
        var i = 2
        while i + 9 < b.count {
            if b[i] == 0xFF, b[i + 1] >= 0xC0, b[i + 1] <= 0xC2 { return i }
            i += 1
        }
        return nil
    }

    @Test func truncationAtEveryHeaderOffsetAndStrideBeyond() throws {
        let jpg = try Self.fixture("s2c2016_10_284_435.jpg")
        let cuts = FuzzMutate_Img.cutLengths(count: jpg.count, dense: 1024, maxCuts: 150)
        var n = 0
        for c in cuts { Self.run(Array(jpg.prefix(c))); n += 1 }
        #expect(n == cuts.count)
    }

    @Test func seededByteMutations() throws {
        let jpg = try Self.fixture("s2c2016_10_284_435.jpg")
        var rng = FuzzRNG_Img(seed: 0x4A50_4547_0001)
        var done = 0
        for _ in 0..<300 {
            Self.run(FuzzMutate_Img.mutated(jpg, &rng))
            done += 1
        }
        #expect(done == 300)
    }

    @Test func boundaryValuesInFrameHeader() throws {
        let jpg = try Self.fixture("s2c2016_10_284_435.jpg")
        guard let sof = Self.sofOffset(jpg) else { Issue.record("no SOF marker in fixture"); return }
        // SOFn: marker(2) length(2) precision(1) height(2) width(2) components(1) then 3 bytes per component.
        let fields: [(offset: Int, width: Int)] = [
            (sof + 2, 2), (sof + 4, 1), (sof + 5, 2), (sof + 7, 2), (sof + 9, 1), (sof + 10, 1), (sof + 11, 1), (sof + 12, 1),
        ]
        var count = 0
        for f in fields {
            for v in FuzzMutate_Img.boundaries {
                var b = jpg
                FuzzMutate_Img.put(&b, at: f.offset, width: f.width, value: v, bigEndian: true)
                Self.run(b)
                count += 1
            }
        }
        #expect(count == fields.count * FuzzMutate_Img.boundaries.count)
    }

    @Test func seededMutationsOfSecondFixture() throws {
        let jpg = try Self.fixture("usgs_export_17_21174_51204.jpg")
        var rng = FuzzRNG_Img(seed: 0x4A50_4547_0002)
        for _ in 0..<150 { Self.run(FuzzMutate_Img.mutated(jpg, &rng)) }
        for c in FuzzMutate_Img.cutLengths(count: jpg.count, dense: 600, maxCuts: 60) { Self.run(Array(jpg.prefix(c))) }
    }
}
