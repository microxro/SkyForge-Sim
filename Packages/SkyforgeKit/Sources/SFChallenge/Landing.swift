// SKYFORGE — Apache-2.0
// Landing challenge scoring: touchdown zone, descent rate, centreline, bank and stopping. Pure logic.
import Foundation

/// One sample from the approach and rollout. Distances are along and across the runway.
public struct LandingSample: Sendable, Equatable {
    public var time: Double
    public var onGround: Bool
    public var groundSpeed: Double     // m/s
    public var descentRate: Double     // m/s, positive when sinking
    public var along: Double           // m past the threshold
    public var lateral: Double         // m from the centreline, signed
    public var bank: Double            // rad

    public init(time: Double, onGround: Bool, groundSpeed: Double, descentRate: Double,
                along: Double, lateral: Double, bank: Double) {
        self.time = time; self.onGround = onGround; self.groundSpeed = groundSpeed
        self.descentRate = descentRate; self.along = along; self.lateral = lateral; self.bank = bank
    }
}

public struct LandingChallenge: Sendable, Equatable {
    public var runwayLength: Double = 1_500   // m
    public var zoneStart: Double = 150        // m past threshold, start of the target zone
    public var zoneEnd: Double = 400          // m past threshold, end of the target zone
    public var zoneFalloff: Double = 300      // m beyond the zone where zone points reach zero

    public init() {}
}

/// Points out of 100. Stopping past the runway end scores zero.
public struct LandingScore: Sendable, Equatable {
    public var descentPoints: Double      // up to 30
    public var zonePoints: Double         // up to 40
    public var centerlinePoints: Double   // up to 15
    public var bankPoints: Double         // up to 15
    public var touchdownAlong: Double
    public var stopAlong: Double
    public var overran: Bool

    public var total: Double {
        overran ? 0 : (descentPoints + zonePoints + centerlinePoints + bankPoints).rounded()
    }
}

/// Feed samples in time order. The result is ready once the aircraft has slowed to a stop
/// after touchdown, or when `endRollout()` is called.
public struct LandingEvaluator: Sendable {
    public let challenge: LandingChallenge
    private var touchdown: LandingSample?
    private var lastSample: LandingSample?
    public private(set) var result: LandingScore?

    public init(challenge: LandingChallenge = LandingChallenge()) {
        self.challenge = challenge
    }

    public mutating func process(_ s: LandingSample) {
        guard result == nil else { return }
        lastSample = s
        guard let td = touchdown else {
            if s.onGround { touchdown = s }
            return
        }
        if s.groundSpeed < 1.0 || td.time == s.time { finish(stoppedAt: s) }
    }

    /// Ends the evaluation with the last sample, e.g. when the aircraft leaves the runway.
    public mutating func endRollout() {
        guard result == nil, let last = lastSample, touchdown != nil else { return }
        finish(stoppedAt: last)
    }

    private mutating func finish(stoppedAt stop: LandingSample) {
        guard let td = touchdown else { return }
        let c = challenge
        let descent = clamp01((5 - td.descentRate) / 4) * 30
        let outside: Double
        if td.along < c.zoneStart { outside = c.zoneStart - td.along }
        else if td.along > c.zoneEnd { outside = td.along - c.zoneEnd }
        else { outside = 0 }
        let zone = clamp01(1 - outside / c.zoneFalloff) * 40
        let centerline = clamp01((15 - abs(td.lateral)) / 12) * 15
        let bankDegrees = abs(td.bank) * 180 / Double.pi
        let bank = clamp01((15 - bankDegrees) / 12) * 15
        result = LandingScore(descentPoints: descent, zonePoints: zone, centerlinePoints: centerline,
                              bankPoints: bank, touchdownAlong: td.along, stopAlong: stop.along,
                              overran: stop.along > c.runwayLength)
    }
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
