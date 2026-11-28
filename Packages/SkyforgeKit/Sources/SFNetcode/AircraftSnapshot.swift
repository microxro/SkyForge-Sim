// SKYFORGE — Apache-2.0. See LICENSE at the repository root.

/// One aircraft's state as sent over the network. Position is ECEF metres, velocity ECEF metres per second.
public struct AircraftSnapshot: Equatable, Sendable {
    public static let wireVersion: UInt8 = 1
    /// Encoded size in bytes: version, sequence, time, position, velocity, orientation, flags.
    public static let encodedSize = 66

    // Anti-cheat bounds. Packets outside them are dropped before they reach gameplay.
    public static let maxSpeed: Float = 1_000        // m/s, above any civil or military jet in the sim
    public static let minRadius: Double = 6_000_000   // m from Earth centre, below the surface is invalid
    public static let maxRadius: Double = 100_000_000 // m from Earth centre

    public var sequence: UInt32
    /// Sender's session clock, seconds.
    public var simTime: Double
    public var positionECEF: SIMD3<Double>
    public var velocityECEF: SIMD3<Float>
    /// Unit quaternion (x, y, z, w), body to ECEF.
    public var orientation: SIMD4<Float>
    public var flags: UInt8

    public init(
        sequence: UInt32,
        simTime: Double,
        positionECEF: SIMD3<Double>,
        velocityECEF: SIMD3<Float>,
        orientation: SIMD4<Float>,
        flags: UInt8
    ) {
        self.sequence = sequence
        self.simTime = simTime
        self.positionECEF = positionECEF
        self.velocityECEF = velocityECEF
        self.orientation = orientation
        self.flags = flags
    }

    public func encode() -> [UInt8] {
        var w = WireWriter()
        w.u8(Self.wireVersion)
        w.u32(sequence)
        w.f64(simTime)
        w.f64(positionECEF.x)
        w.f64(positionECEF.y)
        w.f64(positionECEF.z)
        w.f32(velocityECEF.x)
        w.f32(velocityECEF.y)
        w.f32(velocityECEF.z)
        w.f32(orientation.x)
        w.f32(orientation.y)
        w.f32(orientation.z)
        w.f32(orientation.w)
        w.u8(flags)
        return w.bytes
    }

    /// Decodes and validates a packet. Throws on truncation, unknown version or out-of-bounds values.
    public static func decode(_ bytes: [UInt8]) throws -> AircraftSnapshot {
        var r = WireReader(bytes)
        let version = try r.u8()
        guard version == wireVersion else { throw WireError.badVersion(version) }
        let seq = try r.u32()
        let t = try r.f64()
        let px = try r.f64()
        let py = try r.f64()
        let pz = try r.f64()
        let vx = try r.f32()
        let vy = try r.f32()
        let vz = try r.f32()
        let qx = try r.f32()
        let qy = try r.f32()
        let qz = try r.f32()
        let qw = try r.f32()
        let flags = try r.u8()
        let snap = AircraftSnapshot(
            sequence: seq,
            simTime: t,
            positionECEF: SIMD3(px, py, pz),
            velocityECEF: SIMD3(vx, vy, vz),
            orientation: SIMD4(qx, qy, qz, qw),
            flags: flags
        )
        try snap.validate()
        return snap
    }

    /// Rejects non-finite values, impossible positions, impossible speeds and non-unit orientations.
    public func validate() throws {
        let p = positionECEF
        let v = velocityECEF
        let q = orientation
        let finite = simTime.isFinite
            && p.x.isFinite && p.y.isFinite && p.z.isFinite
            && v.x.isFinite && v.y.isFinite && v.z.isFinite
            && q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite
        guard finite else { throw WireError.invalidValue }

        let radius = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        guard radius >= Self.minRadius && radius <= Self.maxRadius else { throw WireError.invalidValue }

        let speed = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard speed <= Self.maxSpeed else { throw WireError.invalidValue }

        let normSq = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
        guard (0.9...1.1).contains(normSq) else { throw WireError.invalidValue }
    }
}
