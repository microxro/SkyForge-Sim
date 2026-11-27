// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
// Minimal little-endian binary reader and writer for multiplayer packets. No Foundation needed.

public enum WireError: Error, Equatable, Sendable {
    case truncated
    case badVersion(UInt8)
    case invalidValue
}

public struct WireWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { appendLE(UInt64(v), count: 2) }
    public mutating func u32(_ v: UInt32) { appendLE(UInt64(v), count: 4) }
    public mutating func u64(_ v: UInt64) { appendLE(v, count: 8) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }

    private mutating func appendLE(_ v: UInt64, count: Int) {
        for i in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))))
        }
    }
}

public struct WireReader: Sendable {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        let v = bytes[offset]
        offset += 1
        return v
    }
    public mutating func u16() throws -> UInt16 { UInt16(truncatingIfNeeded: try readLE(count: 2)) }
    public mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try readLE(count: 4)) }
    public mutating func u64() throws -> UInt64 { try readLE(count: 8) }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    private mutating func readLE(count: Int) throws -> UInt64 {
        guard remaining >= count else { throw WireError.truncated }
        var v: UInt64 = 0
        for i in 0..<count {
            v |= UInt64(bytes[offset + i]) << (8 * UInt64(i))
        }
        offset += count
        return v
    }
}
