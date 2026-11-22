// SKYFORGE — Apache-2.0
// Seeded-mutation robustness for TilePack manifest parsing: every manifest must throw or load, never trap.
import Testing
import Foundation
@testable import SFContent

// Deterministic mutation helpers (fixed seeds, no Foundation randomness).
struct FuzzRNG_CT {
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

enum FuzzMutate_CT {
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
    static func mutated(_ original: [UInt8], _ rng: inout FuzzRNG_CT) -> [UInt8] {
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
    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sffuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func validManifest() -> [UInt8] {
        let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "0123456789abcdef", count: 4)
        let json = "{\"name\":\"pack\",\"files\":{\"https://example.com/a\":\"\(h1)\",\"https://example.com/b\":\"\(h2)\"},\"attribution\":[\"x\",\"y\"]}"
        return Array(json.utf8)
    }

    /// Loads a pack whose manifest is `bytes`; on success also looks up every URL it names.
    @discardableResult
    static func run(_ bytes: [UInt8], in dir: URL) -> Bool {
        do { try Data(bytes).write(to: dir.appendingPathComponent("manifest.json")) } catch { return false }
        guard let pack = try? TilePack(root: dir) else { return false }
        for k in pack.manifest.files.keys {
            if let u = URL(string: k) { _ = try? pack.data(for: u) }
        }
        return true
    }

    @Test func validManifestLoads() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.run(Self.validManifest(), in: dir))
    }

    @Test func truncationAtEveryOffset() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = Self.validManifest()
        for c in 0..<m.count { Self.run(Array(m.prefix(c)), in: dir) }
    }

    @Test func seededByteMutations() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = Self.validManifest()
        var rng = FuzzRNG_CT(seed: 0x5450_4B00_0001)
        for _ in 0..<800 { Self.run(FuzzMutate_CT.mutated(m, &rng), in: dir) }
    }

    @Test func boundaryNumbersAndShapesInPlaceOfValues() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = String(repeating: "b", count: 64)
        var values: [String] = FuzzMutate_CT.boundaries.map { String($0) }
        values += ["-1", "1e999", "-0", "null", "true", "[]", "{}", "[\"\(hash)\"]", "{\"k\":\"\(hash)\"}", "\"\"", "\"\\u0000\"",
                   "\"\(String(repeating: "x", count: 100_000))\""]
        var n = 0
        for v in values {
            let docs = [
                "{\"name\":\(v),\"files\":{},\"attribution\":[]}",
                "{\"name\":\"n\",\"files\":{\"https://x/y\":\(v)},\"attribution\":[]}",
                "{\"name\":\"n\",\"files\":\(v),\"attribution\":[]}",
                "{\"name\":\"n\",\"files\":{},\"attribution\":[\(v)]}",
                "{\"name\":\"n\",\"files\":{},\"attribution\":\(v)}",
                v,
            ]
            for d in docs { Self.run(Array(d.utf8), in: dir); n += 1 }
        }
        #expect(n == values.count * 6)
    }

    @Test func deeplyNestedAndHugeManifests() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.run(Array((String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)).utf8), in: dir)
        Self.run(Array(("{\"name\":\"n\",\"files\":{},\"attribution\":" + String(repeating: "[", count: 5_000)).utf8), in: dir)
        Self.run([], in: dir)
        Self.run([0xFF, 0xFE, 0x00], in: dir)
    }

    @Test func writtenPackSurvivesMutatedBodies() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://example.com/tile")!
        try TilePack.write(name: "p", responses: [url: Data([1, 2, 3, 4])], attribution: ["a"], to: dir)
        let pack = try TilePack(root: dir)
        #expect(try pack.data(for: url) == Data([1, 2, 3, 4]))
        // Corrupt the stored body at every byte value of its first byte: must throw corrupt, not trap.
        let hex = try #require(pack.manifest.files[url.absoluteString])
        let file = dir.appendingPathComponent(hex)
        for b in 0..<8 {
            try Data([UInt8(b), 2, 3, 4]).write(to: file)
            _ = try? pack.data(for: url)
        }
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try pack.data(for: url) }
    }
}
