// SKYFORGE — Apache-2.0. See LICENSE at the repository root.
// Turns a stream of remote snapshots into a smooth pose for rendering. Interpolates between
// snapshots and extrapolates briefly with velocity when packets are late.

import Foundation

public struct RemotePose: Equatable, Sendable {
    public var positionECEF: SIMD3<Double>
    public var orientation: SIMD4<Float>
    /// True when the pose is predicted past the newest snapshot.
    public var extrapolated: Bool
}

public struct RemoteAircraftBuffer: Sendable {
    public static let capacity = 16

    /// Render this far behind the newest snapshot, in seconds.
    public var interpolationDelay: Double
    /// Longest prediction past the newest snapshot, in seconds. Beyond this the pose holds still.
    public var maxExtrapolation: Double

    private struct Sample: Sendable {
        let snapshot: AircraftSnapshot
        /// Local clock time when the packet arrived.
        let arrival: Double
    }

    private var samples: [Sample] = []
    private var lastSequence: UInt32?

    public init(interpolationDelay: Double = 0.1, maxExtrapolation: Double = 0.5) {
        self.interpolationDelay = interpolationDelay
        self.maxExtrapolation = maxExtrapolation
    }

    /// Adds a snapshot. Returns false when it is a duplicate or older than the newest one.
    @discardableResult
    public mutating func insert(_ snapshot: AircraftSnapshot, arrival: Double) -> Bool {
        if let last = lastSequence {
            // Wrap-aware comparison of 32-bit sequence numbers.
            let diff = Int32(bitPattern: snapshot.sequence &- last)
            guard diff > 0 else { return false }
        }
        lastSequence = snapshot.sequence
        samples.append(Sample(snapshot: snapshot, arrival: arrival))
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
        return true
    }

    /// Pose at local render time `now`, in seconds. Nil until the first snapshot arrives.
    public func pose(at now: Double) -> RemotePose? {
        guard let first = samples.first, let latest = samples.last else { return nil }
        // Map the local clock onto the sender's clock using the newest sample, then step back by the delay.
        let offset = latest.arrival - latest.snapshot.simTime
        let t = now - offset - interpolationDelay

        if t <= first.snapshot.simTime {
            return RemotePose(positionECEF: first.snapshot.positionECEF,
                              orientation: first.snapshot.orientation,
                              extrapolated: false)
        }

        let newest = latest.snapshot
        if t >= newest.simTime {
            let dt = min(t - newest.simTime, maxExtrapolation)
            let v = newest.velocityECEF
            let p = newest.positionECEF + SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) * dt
            return RemotePose(positionECEF: p, orientation: newest.orientation, extrapolated: true)
        }

        for i in 1..<samples.count {
            let a = samples[i - 1].snapshot
            let b = samples[i].snapshot
            if t <= b.simTime {
                let span = b.simTime - a.simTime
                let u = span > 0 ? (t - a.simTime) / span : 0
                let p = a.positionECEF + (b.positionECEF - a.positionECEF) * u
                let q = Self.slerp(a.orientation, b.orientation, Float(u))
                return RemotePose(positionECEF: p, orientation: q, extrapolated: false)
            }
        }
        return RemotePose(positionECEF: newest.positionECEF, orientation: newest.orientation, extrapolated: false)
    }

    /// Spherical linear interpolation of unit quaternions, with a linear fallback for near-equal ones.
    static func slerp(_ a: SIMD4<Float>, _ b0: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        var b = b0
        var d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
        if d < 0 {
            b = -b
            d = -d
        }
        if d > 0.9995 {
            let r = a + (b - a) * t
            let len = (r.x * r.x + r.y * r.y + r.z * r.z + r.w * r.w).squareRoot()
            return len > 0 ? r / len : a
        }
        let theta = Float(acos(Double(min(d, 1))))
        let s = Float(sin(Double(theta)))
        return (Float(sin(Double((1 - t) * theta))) / s) * a + (Float(sin(Double(t * theta))) / s) * b
    }
}
