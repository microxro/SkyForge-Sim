// SKYFORGE — Apache-2.0
// Arrested landing (the trap). The hook catches the first wire at or aft of the touchdown point.
// The arresting gear then takes the aircraft to a stop at a constant average deceleration. The LSO
// grades the approach on the trap result, glideslope and lineup, and sink rate.
// The grading scheme is a gameplay simplification of the usual LSO categories, not a copy of any manual.
import Foundation

public enum BolterCause: String, Sendable, Codable, Equatable {
    case hookUp        // hook not lowered, so no engagement is possible
    case missedWires   // touchdown aft of the last wire
}

public enum TrapOutcome: Sendable, Codable, Equatable {
    case wire(Int)          // the hook caught this wire number
    case bolter(BolterCause)
    case waveOff            // the pilot or LSO called it off before touchdown
    case overrun            // too fast for the gear, or stopped past the stern
}

/// Approach state at the moment of touchdown.
public struct TrapApproach: Sendable, Codable, Equatable {
    public var touchdownAft: Double       // m aft of the ramp, where the mainwheels touch
    public var groundSpeed: Double        // m/s relative to the deck, aft-bound (airspeed minus headwind)
    public var sinkRate: Double           // m/s, positive down
    public var glideslopeError: Double    // deg, positive means high
    public var lineupError: Double        // deg, positive means right of centreline
    public var hookDown: Bool
    public var waveOff: Bool

    public init(touchdownAft: Double, groundSpeed: Double, sinkRate: Double, glideslopeError: Double,
                lineupError: Double, hookDown: Bool = true, waveOff: Bool = false) {
        self.touchdownAft = touchdownAft
        self.groundSpeed = groundSpeed
        self.sinkRate = sinkRate
        self.glideslopeError = glideslopeError
        self.lineupError = lineupError
        self.hookDown = hookDown
        self.waveOff = waveOff
    }
}

public struct TrapResult: Sendable, Codable, Equatable {
    public var outcome: TrapOutcome
    public var stopAft: Double?          // m aft of the ramp where the aircraft stops, when it was arrested
    public var averageDecelerationG: Double

    public init(outcome: TrapOutcome, stopAft: Double?, averageDecelerationG: Double) {
        self.outcome = outcome
        self.stopAft = stopAft
        self.averageDecelerationG = averageDecelerationG
    }
}

public enum ArrestedLanding {
    /// Average arresting deceleration in g. The deck gear is designed around this value.
    public static let arrestedDecelerationG: Double = 3.5
    /// Highest groundspeed over the deck the gear will take, m/s.
    public static let maxEngageSpeed: Double = 90

    public static func trap(_ a: TrapApproach, deck: CarrierDeck) -> TrapResult {
        if a.waveOff {
            return TrapResult(outcome: .waveOff, stopAft: nil, averageDecelerationG: 0)
        }
        if !a.hookDown {
            return TrapResult(outcome: .bolter(.hookUp), stopAft: nil, averageDecelerationG: 0)
        }
        guard a.touchdownAft.isFinite, a.groundSpeed.isFinite else {
            return TrapResult(outcome: .bolter(.missedWires), stopAft: nil, averageDecelerationG: 0)
        }
        // Wires are sorted forward to aft, so the first one at or past the touchdown point is the one caught.
        guard let wire = deck.wires.first(where: { $0.aftDistance >= a.touchdownAft }) else {
            return TrapResult(outcome: .bolter(.missedWires), stopAft: nil, averageDecelerationG: 0)
        }
        let v = max(0, a.groundSpeed)
        if v > maxEngageSpeed {
            return TrapResult(outcome: .overrun, stopAft: nil, averageDecelerationG: 0)
        }
        let decel = arrestedDecelerationG * CatapultLaunch.gravity
        let stop = wire.aftDistance + v * v / (2 * decel)
        if stop > deck.length {
            return TrapResult(outcome: .overrun, stopAft: stop, averageDecelerationG: arrestedDecelerationG)
        }
        return TrapResult(outcome: .wire(wire.number), stopAft: stop, averageDecelerationG: arrestedDecelerationG)
    }
}

// MARK: - LSO grading

public enum LSOGrade: String, Sendable, Codable, CaseIterable, Equatable {
    case ok = "OK"
    case okMinor = "(OK)"
    case fair = "Fair"
    case noGrade = "No Grade"
    case unsat = "Unsat"
    case bolter = "Bolter"
    case waveOff = "Wave Off"

    /// Points for one attempt. The values are gameplay tuning, not a standard.
    public var points: Int {
        switch self {
        case .ok: 5
        case .okMinor: 4
        case .fair: 3
        case .noGrade, .bolter: 1
        case .unsat, .waveOff: 0
        }
    }

    /// A graded pass for qualification: OK, (OK) or Fair.
    public var isPass: Bool { self == .ok || self == .okMinor || self == .fair }
}

public enum LSO {
    public static let hardSinkRate: Double = 6.0        // m/s, above this the trap is unsafe
    public static let unsafeGlideslopeError: Double = 1.5   // deg
    public static let unsafeLineupError: Double = 6.0       // deg

    public static func grade(_ a: TrapApproach, _ r: TrapResult) -> LSOGrade {
        switch r.outcome {
        case .waveOff: return .waveOff
        case .bolter: return .bolter
        case .overrun: return .unsat
        case .wire(let n):
            let gs = abs(a.glideslopeError)
            let lu = abs(a.lineupError)
            if a.sinkRate > hardSinkRate || gs > unsafeGlideslopeError || lu > unsafeLineupError {
                return .unsat
            }
            if n == CarrierDeck.targetWireNumber {
                if gs <= 0.3 && lu <= 1.0 && a.sinkRate <= 3.0 { return .ok }
                if gs <= 0.6 && lu <= 2.0 && a.sinkRate <= 4.5 { return .okMinor }
                return .fair
            }
            if n == 2 || n == 4 {
                return (gs <= 0.6 && lu <= 2.0) ? .fair : .noGrade
            }
            return .noGrade   // wire 1, the aft-most: landed long
        }
    }
}
