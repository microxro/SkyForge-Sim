// SKYFORGE — Apache-2.0
// Countermeasures: flares that decoy heat seekers and chaff that decoys radar. Deterministic: no wall clock,
// and the capture roll is supplied by the caller. NED axes throughout: x north, y east, z down.
import Foundation
import SFMath
import SFAtmosphere

public struct Decoy: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case flare, chaff }
    public var kind: Kind
    public var position: SIMD3<Double>      // NED, m
    public var velocity: SIMD3<Double>      // NED, m/s
    public var age: Double                  // s

    public init(kind: Kind, position: SIMD3<Double>, velocity: SIMD3<Double>, age: Double = 0) {
        self.kind = kind; self.position = position; self.velocity = velocity; self.age = age
    }

    /// Flare 4 s, chaff 6 s.
    public var life: Double {
        switch kind {
        case .flare: return 4.0
        case .chaff: return 6.0
        }
    }

    /// A NaN age counts as expired, so corrupt data cannot make an immortal decoy.
    public var expired: Bool { !(age < life) }
}

public struct CountermeasureInput: Sendable, Equatable {
    public var flare: Bool
    public var chaff: Bool
    public init(flare: Bool = false, chaff: Bool = false) {
        self.flare = flare; self.chaff = chaff
    }
}

public enum CountermeasureEvent: Sendable, Equatable {
    case deployed(Decoy.Kind)
    case exhausted(Decoy.Kind)
}

public struct CountermeasureSystem: Sendable {
    public static let defaultFlares = 30
    public static let defaultChaff = 30
    /// Probability that a flare captures a heat seeker that can see it.
    public static let flareCaptureChance = 0.6
    /// Flares only capture seekers that are within this range of the flare (m).
    public static let flareCaptureRange = 4_000.0

    public private(set) var flares: Int
    public private(set) var chaff: Int
    public private(set) var decoys: [Decoy]
    private var flareHeld: Bool = false
    private var chaffHeld: Bool = false

    public init(flares: Int = CountermeasureSystem.defaultFlares, chaff: Int = CountermeasureSystem.defaultChaff) {
        self.flares = max(0, flares)
        self.chaff = max(0, chaff)
        self.decoys = []
    }

    /// Advances live decoys by dt, removes expired ones, and handles rising edges of input.
    public mutating func update(dt: Double, ownship: Ownship, input: CountermeasureInput) -> [CountermeasureEvent] {
        let step: Double = (dt.isFinite && dt > 0) ? dt : 0
        var events: [CountermeasureEvent] = []

        // Advance existing decoys.
        if step > 0 {
            let flareDrag: Double = max(0.0, 1.0 - 0.5 * step)
            let chaffDrag: Double = max(0.0, 1.0 - 1.0 * step)
            for i in decoys.indices {
                var d: Decoy = decoys[i]
                switch d.kind {
                case .flare:
                    d.velocity.z += ISA.g0 * step
                    d.velocity = d.velocity * flareDrag
                case .chaff:
                    d.velocity = d.velocity * chaffDrag
                }
                d.position = d.position + d.velocity * step
                d.age += step
                decoys[i] = d
            }
        }
        decoys.removeAll(where: { $0.expired })

        // Rising edges.
        let flareEdge: Bool = input.flare && !flareHeld
        let chaffEdge: Bool = input.chaff && !chaffHeld
        flareHeld = input.flare
        chaffHeld = input.chaff

        if flareEdge {
            if flares > 0 {
                flares -= 1
                decoys.append(Self.release(.flare, ownship: ownship, speedScale: 0.5))
                events.append(.deployed(.flare))
            } else {
                events.append(.exhausted(.flare))
            }
        }
        if chaffEdge {
            if chaff > 0 {
                chaff -= 1
                decoys.append(Self.release(.chaff, ownship: ownship, speedScale: 0.8))
                events.append(.deployed(.chaff))
            } else {
                events.append(.exhausted(.chaff))
            }
        }
        return events
    }

    private static func release(_ kind: Decoy.Kind, ownship: Ownship, speedScale: Double) -> Decoy {
        let fl: Double = length(ownship.forward)
        var offset: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
        if fl.isFinite && fl > 0 {
            offset = (ownship.forward / fl) * -5.0
        }
        return Decoy(kind: kind, position: ownship.position + offset, velocity: ownship.velocity * speedScale)
    }

    /// World positions of live chaff clouds, for passing to the radar.
    public var chaffClouds: [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for d in decoys where d.kind == .chaff && !d.expired { out.append(d.position) }
        return out
    }

    /// Index into `decoys` of the flare that captures a heat seeker, or nil.
    public static func flareCapture(seeker: SIMD3<Double>, seekerForward: SIMD3<Double>, target: SIMD3<Double>,
                                    decoys: [Decoy], roll: Double, seekerHalfAngle: Double) -> Int? {
        guard roll.isFinite, roll < flareCaptureChance else { return nil }
        let fwdLen: Double = length(seekerForward)
        guard fwdLen.isFinite, fwdLen > 0 else { return nil }
        let fwd: SIMD3<Double> = seekerForward / fwdLen
        let targetDist: Double = length(target - seeker)
        let cosLimit: Double = cos(seekerHalfAngle)
        var best: Int? = nil
        var bestDist: Double = Double.infinity
        for (i, d) in decoys.enumerated() {
            guard d.kind == .flare, !d.expired else { continue }
            let rel: SIMD3<Double> = d.position - seeker
            let dist: Double = length(rel)
            guard dist.isFinite, dist > 0 else { continue }
            guard dist <= flareCaptureRange else { continue }
            guard dist < targetDist else { continue }
            let cosAngle: Double = dot(rel / dist, fwd)
            guard cosAngle >= cosLimit else { continue }
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    /// True when a live chaff cloud lies within beamHalfAngle of the line of sight from radar to target
    /// and is nearer the radar than the target.
    public static func chaffBlocks(radar: SIMD3<Double>, target: SIMD3<Double>, decoys: [Decoy], beamHalfAngle: Double) -> Bool {
        let los: SIMD3<Double> = target - radar
        let losLen: Double = length(los)
        guard losLen.isFinite, losLen > 0 else { return false }
        let dir: SIMD3<Double> = los / losLen
        let cosLimit: Double = cos(beamHalfAngle)
        for d in decoys {
            guard d.kind == .chaff, !d.expired else { continue }
            let rel: SIMD3<Double> = d.position - radar
            let dist: Double = length(rel)
            guard dist.isFinite, dist > 0, dist < losLen else { continue }
            if dot(rel / dist, dir) >= cosLimit { return true }
        }
        return false
    }
}
