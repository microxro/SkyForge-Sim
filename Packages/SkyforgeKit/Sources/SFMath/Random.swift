// SKYFORGE — Apache-2.0
import Foundation
/// SplitMix64: seeding and hashing PRNG (Steele, Lea, Flood 2014).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Xoshiro256** (Blackman & Vigna), deterministic across platforms.
public struct Xoshiro256: RandomNumberGenerator, Sendable {
    public var s: (UInt64, UInt64, UInt64, UInt64)
    public init(seed: UInt64) {
        var sm = SplitMix64(seed: seed)
        s = (sm.next(), sm.next(), sm.next(), sm.next())
    }
    @inline(__always) static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }
    public mutating func next() -> UInt64 {
        let result = Xoshiro256.rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0; s.3 ^= s.1; s.1 ^= s.2; s.0 ^= s.3
        s.2 ^= t
        s.3 = Xoshiro256.rotl(s.3, 45)
        return result
    }
    /// Uniform Double in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
}

/// Stateless integer hashing for deterministic procedural generation.
public enum Hash {
    @inlinable public static func mix(_ a: UInt64) -> UInt64 {
        var z = a &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    @inlinable public static func combine(_ values: UInt64...) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for v in values { h = mix(h ^ v) }
        return h
    }
    @inlinable public static func int(_ x: Int, _ y: Int, seed: UInt64) -> UInt64 {
        combine(seed, UInt64(bitPattern: Int64(x)), UInt64(bitPattern: Int64(y)))
    }
    /// Uniform Double in [0,1) from a hash.
    @inlinable public static func unit(_ h: UInt64) -> Double { Double(h >> 11) * 0x1.0p-53 }
}

/// FNV-1a 64-bit, for determinism hashes over byte streams.
public struct FNV1a: Sendable {
    public private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325
    public init() {}
    public mutating func add(_ x: UInt64) {
        var v = x
        for _ in 0..<8 { value = (value ^ (v & 0xFF)) &* 0x0000_0100_0000_01B3; v >>= 8 }
    }
    public mutating func add(_ d: Double) { add(d.bitPattern) }
    public mutating func add(_ f: Float) { add(UInt64(f.bitPattern)) }
}
