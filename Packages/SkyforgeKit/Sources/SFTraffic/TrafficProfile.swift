// SKYFORGE — Apache-2.0
// How busy a field is, worked out from its runway. A long runway takes the heavier types and sees more movements;
// a short strip sees light aircraft and only a few. Every field gets traffic, and each has its own seed, so two
// fields do not repeat the same movements. The same runway always gives the same profile.
import Foundation
import SFFlightModel

/// The traffic setup for one field: how often aircraft come and go, which types fly, and the seed for its draws.
public struct TrafficProfile: Sendable, Equatable {
    /// The kind of field, from its runway.
    public enum FieldClass: String, Sendable, Codable, Equatable {
        case busy, medium, quiet
    }

    public var fieldClass: FieldClass
    public var schedule: TrafficSchedule
    /// The types that fly here, before the runway-length check in `TrafficSystem.departureFits`.
    public var fleet: [AircraftConfig]
    /// Seed for the field's random draws. Never zero.
    public var seed: UInt64

    /// Runway length (m) from which a field counts as busy.
    public static let busyLength = 2_400.0
    /// Runway length (m) below which a field counts as quiet.
    public static let quietLength = 1_200.0

    public init(runway: TrafficRunway) {
        let length = runway.length
        if length >= Self.busyLength {
            fieldClass = .busy
            schedule = TrafficSchedule(meanArrivalInterval: 110, meanDepartureInterval: 160, maxAircraft: 8)
            fleet = TrafficSystem.defaultFleet
        } else if length >= Self.quietLength {
            fieldClass = .medium
            schedule = TrafficSchedule()
            fleet = TrafficSystem.defaultFleet
        } else {
            fieldClass = .quiet
            schedule = TrafficSchedule(meanArrivalInterval: 240, meanDepartureInterval: 320, maxAircraft: 3)
            fleet = [.sf1Trainer, .sf2Cruiser]
        }
        seed = Self.makeSeed(for: runway)
    }

    /// A seed from the threshold position. Positions are rounded to the metre and clamped, so the seed is always
    /// finite and the same for the same field.
    static func makeSeed(for runway: TrafficRunway) -> UInt64 {
        func key(_ value: Double) -> UInt64 {
            guard value.isFinite else { return 0 }
            return UInt64(bitPattern: Int64(max(-1e9, min(1e9, value.rounded()))))
        }
        let mixed = (key(runway.threshold.x) &* 0x9E37_79B9_7F4A_7C15) ^ (key(runway.threshold.y) &* 0xBF58_476D_1CE4_E5B9)
        return mixed == 0 ? 1 : mixed
    }
}
