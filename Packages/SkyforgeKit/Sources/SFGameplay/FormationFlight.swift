// SKYFORGE — Apache-2.0
// AI wingmen. A follower holds a slot on a leader: it steers toward the slot point and matches the leader's
// velocity, with a proportional correction. Each frame, independent aircraft step first, then followers, so a
// follower always sees its leader's state for this frame. Deterministic: no wall clock, no randomness.
// NED axes throughout: x north, y east, z down.
import Foundation
import SFMath

public enum FormationFlight {
    /// Correction gain toward the slot point, 1/s. Matches the leader's velocity once the slot is reached.
    public static let gain = 0.4
    /// A follower never flies faster than this multiple of its leader's speed, plus `speedMargin`.
    public static let maxSpeedFactor = 1.5
    public static let speedMargin = 20.0       // m/s

    public static func isFollower(_ t: AITarget) -> Bool {
        if case .follow = t.behavior { return true }
        return false
    }

    /// Steps every AI aircraft once. Non-followers run their own behaviour, threat-aware. Followers then steer on
    /// their leader's updated state. A follower whose leader is missing or destroyed keeps flying straight.
    public static func step(_ targets: inout [AITarget], dt: Double, threat: SIMD3<Double>?, threatVelocity: SIMD3<Double>) {
        for i in targets.indices where !isFollower(targets[i]) {
            targets[i].step(dt: dt, threat: threat, threatVelocity: threatVelocity)
        }
        for i in targets.indices where isFollower(targets[i]) {
            guard case .follow(let leaderID, let slot, let spacing) = targets[i].behavior else { continue }
            let ownID = targets[i].id
            let leader: AITarget? = targets.first(where: { $0.id == leaderID && $0.id != ownID })
            targets[i].follow(leader: leader, slot: slot, spacing: spacing, dt: dt)
        }
    }
}

extension AITarget {
    /// Advances one follower toward its slot on `leader`. With no live leader, the aircraft coasts straight.
    public mutating func follow(leader: AITarget?, slot: FormationSlot, spacing: Double, dt: Double) {
        guard !destroyed else { return }
        guard let leader, !leader.destroyed else {
            position += velocity * dt
            return
        }
        let slotPoint = FormationGeometry.slotPosition(leaderPosition: leader.position, heading: leader.heading,
                                                       slot: slot, spacing: spacing)
        // Desired velocity: the leader's velocity plus a correction toward the slot.
        var wanted = leader.velocity + (slotPoint - position) * FormationFlight.gain
        let cap = max(0, leader.speed) * FormationFlight.maxSpeedFactor + FormationFlight.speedMargin
        let magnitude = (wanted.x * wanted.x + wanted.y * wanted.y + wanted.z * wanted.z).squareRoot()
        if !magnitude.isFinite {
            wanted = leader.velocity
        } else if magnitude > cap, magnitude > 0 {
            wanted *= cap / magnitude
        }
        let speedWanted = (wanted.x * wanted.x + wanted.y * wanted.y + wanted.z * wanted.z).squareRoot()
        if speedWanted > 1e-6 {
            let horizontal = (wanted.x * wanted.x + wanted.y * wanted.y).squareRoot()
            heading = atan2(wanted.y, wanted.x)
            flightPath = atan2(-wanted.z, horizontal)
            speed = speedWanted
        }
        position += velocity * dt
    }
}
