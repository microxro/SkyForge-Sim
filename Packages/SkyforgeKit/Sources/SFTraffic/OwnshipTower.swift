// SKYFORGE — Apache-2.0
// Ownship as a tower entry. The tower sees the player's aircraft as one more snapshot, with the id
// `TrafficOwnship.id`, so the same rules sequence it: landings by spacing and the runway, takeoffs when the runway
// is clear, and pattern calls from its phase. The phase comes from where the aircraft is relative to the runway and
// the pattern, and from whether it has flown yet. Nothing here steers the aircraft.
import Foundation
import SFFlightModel

/// What the simulation reports about ownship each tick, in the terms the tower needs.
public struct OwnshipReport: Sendable, Equatable {
    public var config: AircraftConfig
    /// NED position (m).
    public var positionNED: SIMD3<Double>
    /// NED ground velocity (m/s).
    public var velocityNED: SIMD3<Double>
    /// True while the wheels carry the aircraft.
    public var onGround: Bool

    public init(config: AircraftConfig, positionNED: SIMD3<Double>, velocityNED: SIMD3<Double>, onGround: Bool) {
        self.config = config
        self.positionNED = positionNED
        self.velocityNED = velocityNED
        self.onGround = onGround
    }

    /// Horizontal speed over the ground (m/s).
    public var groundSpeed: Double {
        (velocityNED.x * velocityNED.x + velocityNED.y * velocityNED.y).squareRoot()
    }
}

/// How the tower refers to ownship.
public enum TrafficOwnship {
    /// The id ownship has in the tower's picture and in its instructions.
    public static let id = "OWN"
    /// The callsign the tower uses for ownship, spoken as "N one zero zero".
    public static let callsign = "N100"
}

/// Follows ownship through its procedure and builds its snapshot for the tower.
///
/// A flight that starts on the runway holds short until it rolls, then climbs out on the departure route. Once it is
/// `climbOutLength` metres along the runway it is inbound again, and flies the pattern when it comes back. A flight
/// that starts in the air is inbound from the start. Each tick is read as the aircraft is at that moment.
public struct OwnshipTracker: Sendable, Equatable {
    /// True until ownship first leaves the ground, for a flight that started on the runway.
    public private(set) var awaitingTakeoff: Bool
    /// True from the first lift-off until ownship is `climbOutLength` metres along the runway.
    public private(set) var climbingOut = false

    /// Along-runway distance (m) at which the climb out ends.
    public static let climbOutLength = 3_000.0
    /// Distance (m) from every pattern leg beyond which ownship counts as inbound.
    public static let patternReach = 1_500.0

    /// The controller that has ownship now: the tower for a flight that starts on the runway, approach otherwise.
    public private(set) var facility: TrafficFacility

    public init(startsOnRunway: Bool) {
        awaitingTakeoff = startsOnRunway
        facility = startsOnRunway ? .tower : .approach
    }

    /// The tower's phase for ownship in this report. Updates the takeoff, climb-out and facility state.
    public mutating func phase(for report: OwnshipReport, runway: TrafficRunway, pattern: TrafficPatternGeometry) -> TrafficPhase {
        let current = flightPhase(for: report, runway: runway, pattern: pattern)
        facility = TrafficSystem.facility(current: facility, phase: current, alongRunway: runway.local(report.positionNED).x)
        return current
    }

    private mutating func flightPhase(for report: OwnshipReport, runway: TrafficRunway,
                                      pattern: TrafficPatternGeometry) -> TrafficPhase {
        if report.onGround {
            if awaitingTakeoff {
                return report.groundSpeed < 2 ? .holdShort : .takeoffRoll
            }
            return .landing
        }
        if awaitingTakeoff {
            awaitingTakeoff = false
            climbingOut = true
        }
        let local = runway.local(report.positionNED)
        if climbingOut, local.x > Self.climbOutLength {
            climbingOut = false
        }
        if climbingOut {
            return .departing
        }
        return Self.patternPhase(at: local, pattern: pattern)
    }

    /// The pattern leg nearest a runway-frame position (along, right, up). Inbound when the position is past the
    /// pattern entry, or farther than `patternReach` from every leg.
    public static func patternPhase(at p: SIMD3<Double>, pattern: TrafficPatternGeometry) -> TrafficPhase {
        if p.x > pattern.downwindStart { return .inbound }
        let side = pattern.side
        let entry = SIMD3(pattern.downwindStart, side * pattern.downwindOffset, pattern.patternAltitude)
        let downwindEnd = SIMD3(pattern.baseCorner, side * pattern.downwindOffset, pattern.downwindEndAltitude)
        let finalFix = SIMD3(pattern.baseCorner, 0, pattern.finalFixAltitude)
        let touchdown = SIMD3(pattern.touchdownAlong, 0, 0)
        let legs: [(phase: TrafficPhase, distance: Double)] = [
            (.downwind, segmentDistance(p, entry, downwindEnd)),
            (.base, segmentDistance(p, downwindEnd, finalFix)),
            (.final, segmentDistance(p, finalFix, touchdown)),
        ]
        guard let nearest = legs.min(by: { $0.distance < $1.distance }), nearest.distance <= patternReach else {
            return .inbound
        }
        return nearest.phase
    }

    /// Distance (m) from `p` to the segment from `a` to `b`.
    static func segmentDistance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
        let ap = p - a
        let along = lengthSquared > 0 ? (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / lengthSquared : 0
        let t = max(0, min(1, along))
        let d = ap - ab * t
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    /// The tower's snapshot of ownship for this tick. `clearedToLand` and `clearedToTakeoff` are the tower's own
    /// record of what it has issued to ownship.
    public mutating func snapshot(of report: OwnshipReport, system: TrafficSystem,
                                  clearedToLand: Bool, clearedToTakeoff: Bool) -> TrafficSnapshot {
        let current = phase(for: report, runway: system.runway, pattern: system.pattern)
        let local = system.runway.local(report.positionNED)
        let touchdown = system.runway.ned(along: system.pattern.touchdownAlong, right: 0, up: 0)
        let d = touchdown - report.positionNED
        return TrafficSnapshot(id: TrafficOwnship.id, callsign: TrafficOwnship.callsign,
                               typeName: report.config.name, kind: awaitingTakeoff ? .departure : .arrival,
                               phase: current, positionNED: report.positionNED,
                               heading: atan2(report.velocityNED.y, report.velocityNED.x),
                               speed: report.groundSpeed,
                               heightAboveRunway: local.z, alongRunway: local.x,
                               distanceToTouchdown: (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot(),
                               isHeavy: TrafficPerformance.isHeavy(report.config),
                               clearedToLand: clearedToLand, clearedToTakeoff: clearedToTakeoff,
                               takeoffFits: system.departureFits(report.config), facility: facility,
                               distanceToApproachFix: system.distanceToApproachFix(report.positionNED),
                               bearingToApproachFix: system.bearingToApproachFix(report.positionNED))
    }
}
