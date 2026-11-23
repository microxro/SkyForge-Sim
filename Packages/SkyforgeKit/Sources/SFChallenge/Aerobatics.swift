// SKYFORGE — Apache-2.0
// Aileron-roll detection and chain scoring from body rates. Pure logic: no rendering, UI or I/O.
// Loops are not detected here: MissionRuntime already flies them as the `.loop` objective.
import Foundation

/// One aircraft sample, in the units the flight model already reports.
public struct AerobaticSample: Sendable, Equatable {
    public var time: Double          // s
    public var pitchRate: Double     // q, rad/s, nose up positive
    public var rollRate: Double      // p, rad/s, right wing down positive
    public var altitude: Double      // m
    public var airspeed: Double      // m/s, calibrated

    public init(time: Double, pitchRate: Double, rollRate: Double, altitude: Double, airspeed: Double) {
        self.time = time; self.pitchRate = pitchRate; self.rollRate = rollRate
        self.altitude = altitude; self.airspeed = airspeed
    }
}

public enum FigureKind: String, Sendable, CaseIterable, Codable {
    case aileronRoll
}

/// A completed figure, before scoring.
public struct FigureResult: Sendable, Equatable {
    public var kind: FigureKind
    public var startTime: Double
    public var endTime: Double
    public var direction: Int          // +1 or -1
    public var minAirspeed: Double     // m/s
    public var altitudeLoss: Double    // m, entry minus completion altitude (negative means gained)

    public init(kind: FigureKind, startTime: Double, endTime: Double, direction: Int,
                minAirspeed: Double, altitudeLoss: Double) {
        self.kind = kind; self.startTime = startTime; self.endTime = endTime
        self.direction = direction; self.minAirspeed = minAirspeed; self.altitudeLoss = altitudeLoss
    }
}

/// Finds aileron rolls by integrating roll rate. A roll needs a full turn (324 degrees, 90 % of 360)
/// with the pitch integral kept under 30 degrees. It is abandoned when the rate goes quiet for over a
/// second, reverses direction, or lasts longer than 25 s.
public struct FigureDetector: Sendable {
    public static let fullTurn = 0.9 * 2 * Double.pi
    public static let crossAxisLimit = Double.pi / 6
    public static let activationRate = 0.3       // rad/s, about 17 deg/s
    public static let quietRate = 0.05          // rad/s
    public static let quietReset = 1.0          // s
    public static let maxDuration = 25.0         // s

    struct Tracker: Sendable {
        var active = false
        var start = 0.0
        var sign = 0.0
        var angle = 0.0            // integral of roll rate, rad
        var cross = 0.0            // integral of pitch rate, rad
        var entryAltitude = 0.0
        var minSpeed = Double.infinity
        var quietSince: Double?
    }

    private var tracker = Tracker()
    private var lastTime: Double?

    public init() {}

    /// Feeds one sample and returns any figures it completes.
    public mutating func process(_ s: AerobaticSample) -> [FigureResult] {
        defer { lastTime = s.time }
        guard let previous = lastTime else { return [] }
        let dt = min(max(s.time - previous, 0), 0.25)
        guard dt > 0, let roll = Self.step(&tracker, rate: s.rollRate, cross: s.pitchRate, sample: s, dt: dt) else {
            return []
        }
        return [roll]
    }

    private static func step(_ t: inout Tracker, rate: Double, cross: Double,
                             sample s: AerobaticSample, dt: Double) -> FigureResult? {
        if !t.active {
            guard abs(rate) >= activationRate else { return nil }
            t = Tracker(active: true, start: s.time, sign: rate > 0 ? 1 : -1, entryAltitude: s.altitude)
        }
        if abs(rate) < quietRate {
            let since = t.quietSince ?? s.time
            t.quietSince = since
            if s.time - since > quietReset { t = Tracker(); return nil }
        } else {
            t.quietSince = nil
            if rate * t.sign < 0 { t = Tracker(); return nil }
        }
        if s.time - t.start > maxDuration { t = Tracker(); return nil }

        t.angle += rate * dt
        t.cross += cross * dt
        t.minSpeed = min(t.minSpeed, s.airspeed)

        guard abs(t.angle) >= fullTurn else { return nil }
        guard abs(t.cross) < crossAxisLimit else { t = Tracker(); return nil }
        let result = FigureResult(kind: .aileronRoll, startTime: t.start, endTime: s.time, direction: Int(t.sign),
                                  minAirspeed: t.minSpeed, altitudeLoss: t.entryAltitude - s.altitude)
        t = Tracker()
        return result
    }
}

extension FigureDetector.Tracker {
    init(active: Bool, start: Double, sign: Double, entryAltitude: Double) {
        self.active = active
        self.start = start
        self.sign = sign
        self.entryAltitude = entryAltitude
    }
}

/// Points for one figure, and the multiplier its position in a chain earns.
public struct ScoredFigure: Sendable, Equatable {
    public var figure: FigureResult
    public var basePoints: Double
    public var multiplier: Double
    public var points: Double { basePoints * multiplier }
}

public enum FigureScoring {
    /// Base points: 60 at 60 m/s entry speed, falling to zero at 40 m/s, and reduced by up to half
    /// for altitude lost (100 m or more costs half).
    public static func basePoints(kind: FigureKind, minAirspeed: Double, altitudeLoss: Double) -> Double {
        let value: Double = 60
        let floor: Double = 40
        let target: Double = 60
        let speed = clamp01((minAirspeed - floor) / (target - floor))
        let altitude = 1 - min(0.5, max(0, altitudeLoss) / 100)
        return (value * speed * altitude).rounded()
    }
}

/// Keeps a running total. A figure that starts within 15 s of the last one ends the chain
/// and adds 0.1 to the multiplier per linked figure, up to 2.0.
public struct AerobaticScorer: Sendable {
    public static let chainWindow = 15.0
    public static let maxMultiplier = 2.0

    public private(set) var total = 0.0
    public private(set) var chain = 0
    public private(set) var figures: [ScoredFigure] = []
    private var lastEnd: Double?

    public init() {}

    @discardableResult
    public mutating func record(_ f: FigureResult) -> ScoredFigure {
        if let last = lastEnd, f.startTime - last <= Self.chainWindow {
            chain += 1
        } else {
            chain = 0
        }
        let scored = ScoredFigure(
            figure: f,
            basePoints: FigureScoring.basePoints(kind: f.kind, minAirspeed: f.minAirspeed, altitudeLoss: f.altitudeLoss),
            multiplier: min(Self.maxMultiplier, 1 + 0.1 * Double(chain)))
        total += scored.points
        figures.append(scored)
        lastEnd = f.endTime
        return scored
    }
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
