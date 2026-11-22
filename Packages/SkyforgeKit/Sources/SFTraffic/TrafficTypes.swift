// SKYFORGE — Apache-2.0
// Types for AI traffic and the clearances that drive it. Positions are NED (x north, y east, z down), as
// everywhere in the flight code. Runway coordinates are (along, right, up): metres along the runway from
// the threshold, metres to the right of the runway direction, and metres above the runway surface.
import Foundation
import SFFlightModel

/// One runway in the frame `FlightWorld` uses: world x east, y north (m).
public struct TrafficRunway: Sendable, Equatable {
    public var threshold: SIMD2<Double>
    /// True heading from the threshold toward the far end (rad, clockwise from north).
    public var heading: Double
    /// Length (m).
    public var length: Double
    /// Surface elevation (m AMSL).
    public var elevation: Double

    public init(threshold: SIMD2<Double>, heading: Double, length: Double, elevation: Double) {
        self.threshold = threshold
        self.heading = heading.isFinite ? heading : 0
        self.length = length.isFinite ? max(length, 100) : 100
        self.elevation = elevation.isFinite ? elevation : 0
    }

    /// Unit vector along the runway as (east, north).
    var direction: SIMD2<Double> { SIMD2(sin(heading), cos(heading)) }

    /// Unit vector to the right of the runway direction as (east, north).
    var rightVector: SIMD2<Double> { SIMD2(direction.y, -direction.x) }

    /// Two-digit designator from the heading, e.g. "28" for 280 degrees. The bundled data has no L/R suffix.
    public var designator: String {
        var degrees = (heading * 180 / Double.pi).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        var number = Int((degrees / 10).rounded()) % 36
        if number == 0 { number = 36 }
        return String(format: "%02ld", number)
    }

    /// NED position for runway coordinates.
    public func ned(along: Double, right: Double, up: Double) -> SIMD3<Double> {
        let p = threshold + direction * along + rightVector * right
        return SIMD3(p.y, p.x, -(elevation + up))
    }

    /// Runway coordinates of an NED position, as (x: along, y: right, z: up).
    public func local(_ ned: SIMD3<Double>) -> SIMD3<Double> {
        let q = SIMD2(ned.y, ned.x) - threshold
        let along = q.x * direction.x + q.y * direction.y
        let right = q.x * rightVector.x + q.y * rightVector.y
        return SIMD3(along, right, -ned.z - elevation)
    }
}

/// Arrival or departure.
public enum TrafficKind: String, Sendable, Codable, Equatable {
    case arrival, departure
}

/// Where an AI aircraft is in its procedure. Arrival phases name the leg being flown.
public enum TrafficPhase: String, Sendable, Codable, Equatable {
    /// Arrival flying to the pattern entry.
    case inbound
    /// Arrival on the downwind leg.
    case downwind
    /// Arrival on the base leg, flying to the final fix.
    case base
    /// Arrival not cleared at the final fix: flying back to the pattern entry.
    case extended
    /// Arrival on final approach, committed to land.
    case final
    /// Arrival rolling out on the runway.
    case landing
    /// Departure waiting at the runway for takeoff clearance.
    case holdShort
    /// Departure accelerating on the runway.
    case takeoffRoll
    /// Departure climbing out on the departure route.
    case departing
    /// Finished; removed from the system on the same step.
    case complete
}

/// A clearance the controller issues to one AI aircraft.
public enum TrafficClearance: String, Sendable, Codable, Equatable {
    case land, takeoff
}

/// One AI aircraft. Point-mass state; `config` supplies its real mass, span, speeds and climb limits.
public struct TrafficAircraft: Sendable, Equatable, Identifiable {
    public let id: String
    public let callsign: String
    public let config: AircraftConfig
    public let kind: TrafficKind
    public internal(set) var phase: TrafficPhase
    /// NED position (m). `position.z` is minus the altitude above sea level.
    public internal(set) var position: SIMD3<Double>
    /// Heading from true north (rad), clockwise.
    public internal(set) var heading: Double
    /// Speed through the air mass (m/s).
    public internal(set) var speed: Double
    public internal(set) var clearedToLand = false
    public internal(set) var clearedToTakeoff = false
    /// Next waypoint on the departure route.
    public internal(set) var routeIndex = 0
    /// Seconds since spawn.
    public internal(set) var age = 0.0
    /// Seconds since this aircraft last shed a wake pair.
    public internal(set) var sinceWake = 0.0

    public init(id: String, callsign: String, config: AircraftConfig, kind: TrafficKind, phase: TrafficPhase,
                position: SIMD3<Double>, heading: Double, speed: Double) {
        self.id = id
        self.callsign = callsign
        self.config = config
        self.kind = kind
        self.phase = phase
        self.position = position
        self.heading = heading
        self.speed = speed
    }
}

/// What the controller and the UI need to know about one aircraft this tick.
public struct TrafficSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var callsign: String
    public var typeName: String
    public var kind: TrafficKind
    public var phase: TrafficPhase
    public var positionNED: SIMD3<Double>
    public var heading: Double
    public var speed: Double
    /// Metres above the runway surface.
    public var heightAboveRunway: Double
    /// Metres along the runway from the threshold.
    public var alongRunway: Double
    /// Straight-line distance to the touchdown point (m). Orders the landing sequence.
    public var distanceToTouchdown: Double
    public var isHeavy: Bool
    public var clearedToLand: Bool
    public var clearedToTakeoff: Bool
}

/// Things that happened in the last step, for logs and effects.
public enum TrafficEvent: Sendable, Equatable {
    case spawned(id: String, kind: TrafficKind)
    case extended(id: String)
    case touchedDown(id: String)
    case tookOff(id: String)
    case completed(id: String, kind: TrafficKind)
}

/// How busy the field is. Arrival and departure times are drawn between half and one-and-a-half times the mean.
public struct TrafficSchedule: Sendable, Equatable {
    /// Mean seconds between arrivals.
    public var meanArrivalInterval: Double
    /// Mean seconds between departures.
    public var meanDepartureInterval: Double
    /// Most aircraft in the system at once.
    public var maxAircraft: Int
    /// Along-runway distance at which arrivals appear (m).
    public var arrivalSpawnDistance: Double

    public init(meanArrivalInterval: Double = 150, meanDepartureInterval: Double = 210,
                maxAircraft: Int = 6, arrivalSpawnDistance: Double = 7_000) {
        self.meanArrivalInterval = meanArrivalInterval.isFinite ? max(meanArrivalInterval, 20) : 150
        self.meanDepartureInterval = meanDepartureInterval.isFinite ? max(meanDepartureInterval, 20) : 210
        self.maxAircraft = max(1, maxAircraft)
        self.arrivalSpawnDistance = arrivalSpawnDistance.isFinite ? max(arrivalSpawnDistance, 2_000) : 7_000
    }
}
